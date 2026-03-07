<#
.SYNOPSIS
    V14.8 - Organisateur Ultra-Rapide (Arrondi 1km / 2 decimales).
    
.DESCRIPTION
    Refactorisation de l'Organisateur OneDrive (V19.1) :
    - Noms de variables explicites
    - Fonctions documentées
    - Mode verbose/debug
    - Logs structurés
.PARAMETER Execute
    Si $true, exécute les PATCH sur OneDrive. Sinon, affiche l'aperçu.
.PARAMETER KeepLogs
    Si $true, archive les logs existants au lieu de les supprimer.
#>

param (
    [bool]$Execute = $false,        # Par défaut, le script affiche un aperçu sans effectuer de modifications. Passer à $true pour exécuter les changements.
    #[bool]$KeepLogs = $true,
    [string]$IndexFile = ".\onedrive_cache.json", # Fichier de cache local (JSON) contenant les métadonnées des fichiers OneDrive.
    [string]$LogFile = ".\organisation_log.txt", # Fichier de log détaillé des actions planifiées et exécutées.
    [string]$ProcessedLog = ".\processed_ids.log", # Fichier contenant les IDs des fichiers déjà traités pour éviter les doublons.
    [string]$ExecutionReport = ".\azure_sync_report.csv", # Fichier CSV structuré avec les résultats de l'exécution (succès/erreur).
    [bool]$VerboseMode = $false # Affiche des informations détaillées sur le processus pour le débogage et la validation.
)

Clear-Host
Write-Host "--- ONEDRIVE ORGANIZER (refactor v1.0) ---" -ForegroundColor Cyan

# Init-Logs : Prépare l'environnement en supprimant les anciens fichiers de logs et en créant
# les nouveaux fichiers de rapport (.txt et .csv) pour garantir un suivi propre.
function Init-Logs {
    # supprime l'ancien log 
    if (Test-Path $LogFile) { Remove-Item $LogFile -Force }

    # entete csv
    "Timestamp,ID,Status,OldPath,NewPath,Error" | Set-Content $ExecutionReport

    $RenameMarker = "_v_"
    $FolderInventory = @{}    # clé = "/cleanDest/newName" -> valeur = $true
}


function Get-ErrorDetails {
    <#
    .SYNOPSIS
        Extrait un message d'erreur lisible depuis une exception HTTP ou WebResponse.
    .PARAMETER Ex
        L'exception capturée ($_).
    .OUTPUTS
        Chaîne de texte décrivant l'erreur.
    #>
    param($Ex)
    $details = ""
    try {
        if ($Ex.Response -and $Ex.Response.Content) {
            $details = $Ex.Response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        } elseif ($Ex.Response) {
            $reader = New-Object System.IO.StreamReader($Ex.Response.GetResponseStream())
            $details = $reader.ReadToEnd()
        }
    } catch {
        $details = "Flux d'erreur illisible."
    }
    if ([string]::IsNullOrWhiteSpace($details)) { $details = $Ex.Message }
    return $details
}

function Normalize-ToAscii {
    <#
    .SYNOPSIS
        Normalise une chaîne en ASCII, supprime GUID/hex/base64 longs et remplace caractères invalides.
    .PARAMETER text
        Chaîne d'entrée.
    .PARAMETER isPath
        Si $true, autorise "/" dans le pattern (pour chemins).
    .OUTPUTS
        Chaîne nettoyée.
    #>
    param([string]$text, [bool]$isPath = $false)
    if ([string]::IsNullOrWhiteSpace($text)) { return "" }
    $normalized = $text.Normalize([System.Text.NormalizationForm]::FormD)
    $sb = New-Object System.Collections.Generic.List[char]
    foreach ($c in $normalized.ToCharArray()) {
        if ([System.Globalization.CharUnicodeInfo]::GetUnicodeCategory($c) -ne [System.Globalization.UnicodeCategory]::NonSpacingMark) {
            $sb.Add($c)
        }
    }
    $clean = (-join $sb)
    # Supprime GUIDs
    $clean = $clean -replace "[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}", ""
    # Supprime séquences alphanumériques très longues (probablement base64/hex)
    $clean = $clean -replace "[a-zA-Z0-9]{16,}", ""
    $pattern = if ($isPath) { "[^a-zA-Z0-9\.\-/]" } else { "[^a-zA-Z0-9\.\-]" }
    $result = ($clean -replace $pattern, "_" -replace "_+", "_").Trim("_")
    return $result
}

function Build-SmartFileName {
    <#
    .SYNOPSIS
        Construit un nom de fichier respectant la limite de 100 caractères.
    .PARAMETERS
        timestampStr : string "yyyyMMdd_HHmmss"
        contextStr   : string (contexte dossier, up to 3 parents)
        originalName : string (sans extension)
        marker       : string (ex: "_v_")
        extension    : string (ex: ".jpg")
        videoTags    : string (ex: "00:12_1920x1080")
    .OUTPUTS
        Nom de fichier final (string)
    #>
    param(
        [string]$timestampStr,
        [string]$contextStr,
        [string]$originalName,
        [string]$marker,
        [string]$extension,
        [string]$videoTags
    )

    $cleanOriginal = Normalize-ToAscii -text $originalName -isPath:$false
    $cleanContext = Normalize-ToAscii -text $contextStr -isPath:$false

    # Filtrer les mots du nom original qui sont identiques au timestamp ou trop courts
    $filteredWords = ($cleanOriginal -split "_" | Where-Object { $_.Length -gt 1 -and ($timestampStr -notmatch $_) }) -join "_"

    # Calcul de l'espace disponible (100 chars max)
    $fixedLen = $timestampStr.Length + $filteredWords.Length + $marker.Length + $videoTags.Length + $extension.Length + 4
    $availableForContext = 100 - $fixedLen
    $finalContext = ""
    if ($availableForContext -gt 5 -and $cleanContext) {
        if ($cleanContext.Length -gt $availableForContext) {
            $finalContext = $cleanContext.Substring($cleanContext.Length - $availableForContext).Trim("_")
        } else {
            $finalContext = $cleanContext
        }
    }

    $parts = New-Object System.Collections.Generic.List[string]
    $parts.Add($timestampStr)
    if ($filteredWords) { $parts.Add($filteredWords) }
    if ($finalContext) { $parts.Add($finalContext) }
    if ($videoTags) { $parts.Add($videoTags) }

    $baseName = ($parts -join "_").Trim("_")
    return "$baseName$marker$extension"
}

function Ensure-OneDrivePath {
    <#
    .SYNOPSIS
        Vérifie l'existence d'un chemin OneDrive et crée les dossiers manquants segment par segment.
    .PARAMETERS
        Headers : Hashtable d'Authorization
        Path    : chemin relatif sans slash initial (ex: "Images/Pellicule/2025/02")
    #>
    param($Headers, $Path)
    $Path = $Path.Trim('/')
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    $parts = $Path -split '/'
    $currentPath = ""
    foreach ($part in $parts) {
        $parentPath = $currentPath
        $currentPath += if ($currentPath -eq "") { $part } else { "/$part" }
        $segments = ($currentPath -split '/' | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/'
        $uriGet = "https://graph.microsoft.com/v1.0/me/drive/root:/$($segments):"
        try {
            write-Host "  Vérification : /$currentPath" -ForegroundColor Gray
            write-Host "    Segments encodés : $segments" -ForegroundColor DarkGray
            write-Host "    URI GET : $uriGet" -ForegroundColor DarkGray
            write-Host "    Headers : $($Headers | Out-String)" -ForegroundColor DarkGray            
            Invoke-RestMethod -Headers $Headers -Uri $uriGet -Method Get -ErrorAction Stop > $null
        } catch {
            Write-Host "    [Dossier] Création : /$currentPath" -ForegroundColor Cyan
            $parentSegments = ($parentPath -split '/' | Where-Object {$_} | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/'
            
            # Pour la création (POST), la syntaxe est root:/chemin:/children
            $uriPost = if ($parentPath -eq "") { 
                "https://graph.microsoft.com/v1.0/me/drive/root/children" 
            } else { 
                "https://graph.microsoft.com/v1.0/me/drive/root:/$($parentSegments):/children" 
            }
            $body = @{ 
                name = $part; 
                folder = @{}; 
                "@microsoft.graph.conflictBehavior" = "ignore" 
            } | ConvertTo-Json -Compress
            try {
                write-host "headers = $Headers"
                write-host "URI POST = $uriPost"
                write-host "Body = $body"
                $resp = Invoke-RestMethod -Headers $Headers -Uri $uriPost -Method POST -Body $body -ErrorAction Stop > $null
            } catch {
                $err = Get-ErrorDetails $_
                Write-Host "      [!] Détail : $err, resp = $resp" -ForegroundColor Yellow
            }
        }
    }
}

function Determine-TargetRoot {
    <#
    .SYNOPSIS
        Détermine la racine cible OneDrive selon le chemin source (règles métier).
    .PARAMETER SourcePath
        Chemin source complet tel que présent dans le cache.
    .OUTPUTS
        Chaîne représentant la racine cible (ex: "Pour coffre fort/Michelle" ou "Images/Pellicule")
    #>
    param([string]$SourcePath)
    if ($SourcePath -like "*Pour coffre fort/Michelle*") { return "Pour coffre fort/Michelle" }
    if ($SourcePath -like "*Pour coffre fort/relations*") { return "Pour coffre fort/relations" }
    if ($SourcePath -like "*Pour coffre fort/archives*") { return "Pour coffre fort/archives" }
    if ($SourcePath -match "Videos") { return "Videos" }
    return "Images/Pellicule"
}

# Load-Cache : Charge les métadonnées de vos fichiers OneDrive depuis le fichier JSON 
# (onedrive_cache.json) et identifie les fichiers déjà traités pour éviter de travailler en double.
function Load-Cache {
    if (!(Test-Path $IndexFile)) { Write-Error "Cache introuvable: $IndexFile"; exit 1 }
    write-host "Chargement du cache local..." -ForegroundColor Gray
    $Cache = Get-Content $IndexFile -Raw | ConvertFrom-Json -AsHashtable
    $ProcessedIds = @{}
    if (Test-Path $ProcessedLog) { Get-Content $ProcessedLog | ForEach-Object { $ProcessedIds[$_] = $true } }

} # Load-Cache

# Create-Plan : Analyse la liste des fichiers, filtre ceux qui sont pris en charge 
# (photos, vidéos, audio), calcule les nouveaux noms « intelligents » (basés sur la 
# date et le contexte), définit les dossiers de destination et génère un plan d'action.
function Create-Plan {
        
    Write-Host "[1/4] Analyse des fichiers..." -ForegroundColor Gray
    $PlannedActions = New-Object System.Collections.Generic.List[string]

    foreach ($fileId in $Cache.Files.Keys) {
        if ($ProcessedIds.ContainsKey($fileId)) { continue }
        $fileEntry = $Cache.Files[$fileId]
        if ($fileEntry.n -match $RenameMarker) { continue }

        $AllowedExtensions = @(
            ".jpg", ".jpeg", ".png", ".heic",        # Photos
            ".mp4", ".mov", ".avi", ".mpg", ".mpeg", ".wmv", # Vidéos
            ".mp3", ".m4a",                          # Audio
            ".bmp", ".gif", ".pcx"                   # Autres images
        )

        $extension = [System.IO.Path]::GetExtension($fileEntry.n).ToLower()

        # Logique inversée : Si l'extension n'est PAS dans la liste autorisée, on passe au suivant
        if ($AllowedExtensions -notcontains $extension) {
            if ($VerboseMode) { 
                Write-Host " [Skip] Extension non supportée : $extension ($($fileEntry.n))" -ForegroundColor DarkGray 
            }
            continue 
        }

        $timestampStr = ([DateTime]$fileEntry.d).ToString("yyyyMMdd_HHmmss")
        $videoTags = if ($fileEntry.dur -or $fileEntry.res) { (($fileEntry.dur, $fileEntry.res | Where-Object {$_}) -join "_") } else { "" }

        $pathParts = $fileEntry.p -split "/" | Where-Object { $_ -and $_ -notmatch "drive|root|Images|Videos|Pellicule" }
        $context = if ($pathParts.Length -gt 0) { ($pathParts[[Math]::Max(0, $pathParts.Length-3)..($pathParts.Length-1)]) -join "_" } else { "" }

        $originalNameNoExt = [System.IO.Path]::GetFileNameWithoutExtension($fileEntry.n)
        $newName = Build-SmartFileName -timestampStr $timestampStr -contextStr $context -originalName $originalNameNoExt -marker $RenameMarker -extension $extension -videoTags $videoTags

        #$subType = if ($extension -match "mp4|mov") { "Videos" } else { "Images" }

        # 1. Définir une configuration centralisée (à mettre idéalement en haut de script)
        $ExtensionMap = @{
            ".jpg"  = "Images"
            ".jpeg" = "Images"
            ".png"  = "Images"
            ".heic" = "Images"
            ".bmp"  = "Images"
            ".gif"  = "Images"
            ".pcx"  = "Images"
            ".mp4"  = "Videos"
            ".mov"  = "Videos"
            ".avi"  = "Videos"
            ".mpg"  = "Videos"
            ".mpeg" = "Videos"
            ".wmv"  = "Videos"
            ".mp3"  = "Audio"
            ".m4a"  = "Audio"
        }

        # 2. Utilisation simplifiée dans votre boucle
        # On récupère directement la valeur via la clé. 
        # Si l'extension n'existe pas dans la table, on peut définir une valeur par défaut "Autres"
        $subType = if ($ExtensionMap.ContainsKey($extension)) { $ExtensionMap[$extension] } else { "Autres" }

        $targetRoot = Determine-TargetRoot -SourcePath $fileEntry.p

        # Utilisation de la racine déterminée pour construire le chemin final
        if ($targetRoot -like "Pour coffre fort*") {
            $rawDestination = "$targetRoot/$subType/$(([DateTime]$fileEntry.d).Year)/$(([DateTime]$fileEntry.d).ToString('MM'))"
        } else {
            $rawDestination = "$targetRoot/$(([DateTime]$fileEntry.d).Year)/$(([DateTime]$fileEntry.d).ToString('MM'))"
        }

        $cleanDestination = Normalize-ToAscii -text $rawDestination -isPath:$true
        $targetKey = "/$cleanDestination/$newName"

        # Anti-collision local (avant envoi)
        $suffix = 1
        while ($FolderInventory.ContainsKey($targetKey)) {
            $newName = $newName -replace "$RenameMarker", "_$suffix$RenameMarker"
            $targetKey = "/$cleanDestination/$newName"
            $suffix++
        }
        $FolderInventory[$targetKey] = $true

        $PlannedActions.Add("ID:$fileId | SRC:$($fileEntry.p)/$($fileEntry.n) | DST:$targetKey")
    }

    # Écriture du plan d'action
    $PlannedActions | Set-Content $LogFile
    Write-Host "[2/4] Plan d'action : $($PlannedActions.Count) fichiers." -ForegroundColor Green

} # Create-Plan


# -------------------------
# 4. AUTHENTIFICATION ET PRE-CREATION DES DOSSIERS
# -------------------------
# AuthenticateAzure : Gère la connexion sécurisée à Microsoft Graph (via le flux Device
#  Code), indispensable pour obtenir les droits d'écriture sur votre OneDrive.
function AuthenticateAzure {
    if ($Execute -and $PlannedActions.Count -gt 0) {
        $ClientId = "176fc7bc-42c9-4a25-82b5-0ad584d3c061"
        $DeviceCodeRequest = Invoke-RestMethod -Method POST -Uri "https://login.microsoftonline.com/common/oauth2/v2.0/devicecode" -Body @{ client_id = $ClientId; scope = "Files.ReadWrite.All" }
        Write-Host "`n[Connexion] Login : https://microsoft.com/devicelogin Code : $($DeviceCodeRequest.user_code)" -ForegroundColor Yellow

        $Auth = $null
        while (!$Auth) {
            Start-Sleep 5
            try {
                $Auth = Invoke-RestMethod -Method POST -Uri "https://login.microsoftonline.com/common/oauth2/v2.0/token" -Body @{ grant_type = "urn:ietf:params:oauth:grant-type:device_code"; client_id = $ClientId; device_code = $DeviceCodeRequest.device_code }
            } catch {
                if ($VerboseMode) { Write-Host "Attente token..." -ForegroundColor DarkGray }
            }
        }
        $oneDriveHeaders = @{ Authorization = "Bearer $($Auth.access_token)"; "Content-Type" = "application/json" }
    }
} # AuthenticateAzure

# Prepare-Folders : Parcourt le plan généré et crée physiquement les dossiers manquants 
# sur OneDrive avant de tenter de déplacer les fichiers.
function Prepare-Folders {
    Write-Host "`n[2.5/4] Pré-création de l'arborescence..." -ForegroundColor Magenta
    $uniqueFolders = $PlannedActions | ForEach-Object { if ($_ -match "DST:(.*)/.*$") { $Matches[1] } } | Select-Object -Unique | Sort-Object
    foreach ($folder in $uniqueFolders) { 
        Ensure-OneDrivePath -Headers $oneDriveHeaders -Path $folder 
    }
} # Prepare-Folders


# Execute-Deplacement : C'est l'étape finale. Elle applique réellement les renommages 
# et les déplacements (via des requêtes API HTTP/PATCH) et met à jour votre fichier 
# de cache local avec les nouvelles informations pour que le prochain lancement soit à jour.
function Execute-Deplacement {
    if ($Execute -and $PlannedActions.Count -gt 0) {
        Write-Host "`n[3/4] Déplacement..." -ForegroundColor Magenta
        $interactive = $true
        $successList = @()

        foreach ($line in $PlannedActions) {
            if ($line -match "ID:(.*) \| SRC:(.*) \| DST:(.*)") {
                $fileId = $Matches[1]; $srcPath = $Matches[2]; $dstFull = $Matches[3]
                $dstDir = [System.IO.Path]::GetDirectoryName($dstFull).Replace("\", "/")
                $dstName = [System.IO.Path]::GetFileName($dstFull)

                Write-Host "`nFichier : $dstName" -ForegroundColor Gray
                if ($interactive) {
                    $c = Read-Host "Confirmer ? [O] Oui / [N] Non / [T] Tout / [Q] Quitter"
                    if ($c -eq "T") { $interactive = $false } elseif ($c -eq "Q") { break } elseif ($c -ne "O") { continue }
                }

                try {
                    $body = @{ parentReference = @{ path = "/drive/root:$dstDir" }; name = $dstName } | ConvertTo-Json
                    Invoke-RestMethod -Headers $oneDriveHeaders -Uri "https://graph.microsoft.com/v1.0/me/drive/items/$fileId" -Method PATCH -Body $body -ErrorAction Stop
                    "$(Get-Date -Format 'HH:mm'),$fileId,SUCCESS,$srcPath,$dstFull," | Add-Content $ExecutionReport
                    $fileId | Add-Content $ProcessedLog
                    $successList += [PSCustomObject]@{ Id = $fileId; NewPath = $dstDir; NewName = $dstName }
                } catch {
                    $err = Get-ErrorDetails $_
                    Write-Host "  [ERREUR] $err" -ForegroundColor Red
                    "$(Get-Date -Format 'HH:mm'),$fileId,ERROR,$srcPath,$dstFull,$err" | Add-Content $ExecutionReport
                }
            }
        }

        # Mise à jour du cache local avec les nouveaux chemins/noms
        foreach ($item in $successList) {
            $Cache.Files[$item.Id].p = "/drive/root:$($item.NewPath)"
            $Cache.Files[$item.Id].n = $item.NewName
        }
        $Cache | ConvertTo-Json -Depth 10 | Set-Content $IndexFile
    } else {
        if ($PlannedActions.Count -gt 0) {
            Write-Host "`n[Aperçu] Première action : $($PlannedActions[0])" -ForegroundColor Yellow
        } else {
            Write-Host "`n[Aperçu] Aucun fichier à traiter." -ForegroundColor Yellow
        }
    }    
} # Execute-Deplacement


# -------------------------
function main {
    try {
        Write-Host "--- Démarrage du processus ---" -ForegroundColor Cyan
        
        Init-Logs
        Load-Cache
        Create-Plan
        
        # On vérifie si un plan a été généré avant de lancer l'authentification
        if ($PlannedActions.Count -eq 0) {
            Write-Warning "Aucun fichier à traiter. Arrêt du processus."
            return
        }

        # On exige une authentification réussie avant de continuer
        AuthenticateAzure
        if (-not $oneDriveHeaders) {
            throw "Échec de l'authentification. Impossible de poursuivre sans accès OneDrive."
        }

        Prepare-Folders
        Execute-Deplacement
        
        Write-Host "--- Processus terminé avec succès ---" -ForegroundColor Green
    }
    catch {
        Write-Error "Une erreur critique a interrompu le script : $_"
        # Ici, vous pourriez ajouter une notification par mail ou log d'erreur spécifique
        exit 1
    }
} # main

main