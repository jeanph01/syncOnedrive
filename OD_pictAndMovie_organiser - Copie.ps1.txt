<# 
    =====================================================================
    V14.0 - Organisateur avec Feedback détaillé, Chronométrage et Cache GPS Persistant.
    
.DESCRIPTION
    NOMENCLATURE ET ARCHITECTURE CIBLE :
    
    1. PHOTOS (.jpg, .png, .heic) -> /Images/Pellicule/Année/Mois/
       Format : yyyyMMdd_HHmmss_[Ville]_[Dossiers_Tags]_[Nom_Original]_[Appareil].ext
       
    2. VIDÉOS (.mp4, .mov) -> /Vidéos/Pellicule/Année/Mois/
       Format : yyyyMMdd_HHmmss_[Ville]_[Dossiers_Tags]_[Durée]_[Résolution].ext
       
    3. AUDIO (.mp3, .m4a, .flac) -> /Musique/Artiste/Album/
       Format : [Artiste] - [Album] - [Titre].ext

    FONCTIONNEMENT :
    - WhatIf par défaut : Analyse et génère un log sans déplacer de fichiers.
    - Cache GPS Persistant : Sauvegarde automatique à chaque découverte de lieu.
    - Tags de Chemin : Préserve le contexte hiérarchique original.

    FONCTIONNEMENT DU CACHE :
    Si une entrée GPS existe mais ne contient pas la hiérarchie complète (ex: juste "Palma"),
    le script force un rafraîchissement via l'API pour obtenir Province et Pays.
.PARAMETER Execute
    $false (DÉFAUT) : Mode simulation. Génère le fichier de log.
    $true : Applique les changements sur OneDrive.
===================================================================== 
#>

param (
    [bool]$Execute = $false,
    [string]$IndexFile = ".\onedrive_cache.json",   # fichier d'entree
    [string]$LogFile = ".\organisation_log.txt",    # liste des taches a effectuer
    [string]$ProcessedLog = ".\processed_ids.log",
    [string]$ExecutionReport = ".\azure_sync_report.csv",
    [string]$GpsCacheFile = ".\gps_cache.json",     # cache des noms de localisations selon leur coordonnées GPS
    [bool]$VerboseMode = $true                      # equivalent de debug
)

# =====================================================================
# 1. CONFIGURATION GLOBALE
# =====================================================================

# Mapping des extensions vers leur catégorie
$ExtensionMap = @{}
@(".jpg",".jpeg",".png",".heic",".bmp",".gif",".pcx") | ForEach-Object { $ExtensionMap[$_] = "Images" }
@(".mp4",".mov",".avi",".mpg",".mpeg",".wmv")          | ForEach-Object { $ExtensionMap[$_] = "Videos" }
@(".mp3",".m4a")                                       | ForEach-Object { $ExtensionMap[$_] = "Audio" }

# Configuration centrale
$Config = [PSCustomObject]@{
    RenameMarker = "--odr--"  # indique un fichier deja traité -- OneDriveRenamed --
    MaxNameLen   = 100
    # pour les connexions Azure
    ClientId     = "176fc7bc-42c9-4a25-82b5-0ad584d3c061"
    ExtensionMap = $ExtensionMap
}

# État global du script
$Global:State = @{
    Headers        = $null
    Cache          = $null
    ProcessedIds   = @{}
    PlannedActions = New-Object System.Collections.Generic.List[PSCustomObject]
}

# =====================================================================
# 2. LOGGING
# =====================================================================

function Write-Log {
    [CmdletBinding()]
    param([string]$Message, [string]$Level = "INFO")

    # TODO - voir si Get-Date ralenti ou c'est plutot le Add-Content
    $timestamp = Get-Date -Format "HH:mm:ss"

    $color = switch ($Level) {
        "ERROR"   { "Red" }
        "WARN"    { "Yellow" }
        "SUCCESS" { "Green" }
        "DEBUG"   { "DarkGray" }
        default   { "Gray" }
    }

    if ($Level -ne "DEBUG" -or $VerboseMode) {
        Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
    }

    "[$timestamp] [$Level] $Message" | Add-Content $LogFile -ErrorAction SilentlyContinue
}

# =====================================================================
# 3. UTILITAIRES
# =====================================================================

function Get-ErrorDetails {
    [CmdletBinding()]
    param($Exception)

    try {
        if ($Exception.Response) {
            $reader = New-Object System.IO.StreamReader($Exception.Response.GetResponseStream())
            return $reader.ReadToEnd()
        }
    } catch {}

    return $Exception.Message
}

function Convert-ToAscii {
    [CmdletBinding()]
    param([string]$Text, [bool]$IsPath = $false)

    if ([string]::IsNullOrWhiteSpace($Text)) { return "" }

    # Normalisation Unicode → ASCII
    $clean = $Text.Normalize([System.Text.NormalizationForm]::FormD) -replace '\p{M}', ''

    # Suppression GUIDs et longues séquences hex/base64
    $clean = $clean -replace "[a-fA-F0-9]{8}-([a-fA-F0-9]{4}-){3}[a-fA-F0-9]{12}", ""
    $clean = $clean -replace "[a-zA-Z0-9]{16,}", ""

    # Filtrage caractères invalides
    $pattern = if ($IsPath) { "[^a-zA-Z0-9\.\-/]" } else { "[^a-zA-Z0-9\.\-]" }

    return ($clean -replace $pattern, "_" -replace "_+", "_").Trim("_")
}

# =====================================================================
# 4. LOGIQUE MÉTIER
# =====================================================================
function Get-LocationName($gps) {
    if (!$gps -or $gps -eq "," -or $gps -match "^0,0$") { return $null }
    
    $cachedValue = $script:GpsCache[$gps]
    
    # CRITÈRES DE RAFRAÎCHISSEMENT
    $isIncomplete = $cachedValue -and ($cachedValue -split "-").Count -lt 3
    $hasSpecialChars = $cachedValue -and ($cachedValue -match "[^\x00-\x7F]") # Détecte tout ce qui n'est pas ASCII standard

    if ($cachedValue -and !$isIncomplete -and !$hasSpecialChars) { 
        return $cachedValue 
    }
    
    $reason = if ($hasSpecialChars) { "Caractères Spéciaux" } elseif ($isIncomplete) { "Incomplet" } else { "Nouveau" }
    Write-Host " [API GPS] $reason ($gps)..." -ForegroundColor DarkYellow -NoNewline
    
    try {
        $lat, $lon = $gps -split ","
        $Uri = "https://nominatim.openstreetmap.org/reverse?format=json&lat=$($lat.Trim())&lon=$($lon.Trim())&zoom=10&addressdetails=1"
        $res = Invoke-RestMethod -Uri $Uri -UserAgent "OneDriveOrganizer_JPM" -ErrorAction SilentlyContinue
        
        $addr = $res.address
        $city = if ($addr.city) { $addr.city } elseif ($addr.town) { $addr.town } else { $addr.village }
        $state = if ($addr.state) { $addr.state } else { $addr.county }
        $country = $addr.country

        if ($city -and $country) { 
            # 1. Concaténation
            $fullLoc = "$city-$state-$country" -replace " ", "-"
            
            # 2. Nettoyage strict (ASCII uniquement + tirets)
            # On normalise pour transformer les accents (é -> e) si possible, sinon on supprime le non-latin
            $normalized = $fullLoc.Normalize([System.Text.NormalizationForm]::FormD)
            $cleanBuilder = New-Object System.Text.StringBuilder
            foreach ($char in $normalized.ToCharArray()) {
                if ([System.Globalization.CharUnicodeInfo]::GetUnicodeCategory($char) -ne [System.Globalization.UnicodeCategory]::NonSpacingMark) {
                    [void]$cleanBuilder.Append($char)
                }
            }
            $fullLoc = $cleanBuilder.ToString()
            $fullLoc = [Regex]::Replace($fullLoc, "[^a-zA-Z0-9\-]", "")
            $fullLoc = ($fullLoc -replace "-+", "-").Trim("-")
            
            $script:GpsCache[$gps] = $fullLoc
            $script:GpsCache | ConvertTo-Json | Set-Content $GpsCacheFile
            Write-Host " OK: $fullLoc" -ForegroundColor Green
            Start-Sleep -Milliseconds 1100 
            return $fullLoc
        }
    } catch { Write-Host " Échec." -ForegroundColor Red }
    return $null
} # Get-LocationName

function Get-TargetRoot {
    <#
        .SYNOPSIS
            Détermine la racine OneDrive de destination selon un moteur de règles.

        .DESCRIPTION
            Cette version utilise un système déclaratif de règles permettant :
                - De détecter les dossiers sensibles (Finance, Impôts…)
                - De préserver les dossiers de travail (Projets, Études…)
                - De gérer les sous-dossiers du coffre-fort
                - De reconnaître les dossiers d’applications (WhatsApp, Messenger…)
                - De distinguer les vidéos des images
                - De décider si un fichier doit être déplacé ou renommé sur place

            Chaque règle définit :
                - Patterns à détecter
                - Action (Move / Stay)
                - Racine cible (si Move)
                - Priorité (plus petit = plus prioritaire)

            Le système est entièrement extensible sans modifier la fonction.
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SourcePath
    )

    # ------------------------------------------------------------------
    # TABLE DES RÈGLES (déclarative, modifiable facilement)
    # ------------------------------------------------------------------
    $Rules = @(
        # 1. Coffre-fort (priorité maximale)
        @{
            Name       = "CoffreFort-Michelle"
            Patterns   = @("Pour coffre fort/Michelle")
            Action     = "Move"
            TargetRoot = "Pour coffre fort/Michelle"
            Priority   = 1
        },
        @{
            Name       = "CoffreFort-Relations"
            Patterns   = @("Pour coffre fort/relations")
            Action     = "Move"
            TargetRoot = "Pour coffre fort/relations"
            Priority   = 1
        },
        @{
            Name       = "CoffreFort-Archives"
            Patterns   = @("Pour coffre fort/archives")
            Action     = "Move"
            TargetRoot = "Pour coffre fort/archives"
            Priority   = 1
        },

        # 2. Dossiers administratifs (renommer sur place)
        @{
            Name       = "Administratif"
            Patterns   = @("Finance","Fiscalité","Impôts","Banque","Assurance","Documents","Contrats","Notaire","Municipalité","Syndicat")
            Action     = "Stay"
            TargetRoot = $null
            Priority   = 2
        },

        # 3. Dossiers de travail / projets (renommer sur place)
        @{
            Name       = "TravailEtudes"
            Patterns   = @("Projets","Travail","Études","Recherche","Cours","Université")
            Action     = "Stay"
            TargetRoot = $null
            Priority   = 3
        },

        # 4. Dossiers techniques (renommer sur place)
        @{
            Name       = "Technique"
            Patterns   = @("Scripts","Dev","GitHub","Backups","Exports")
            Action     = "Stay"
            TargetRoot = $null
            Priority   = 4
        },

        # 5. Dossiers d’applications (déplacer vers Pellicule)
        @{
            Name       = "Applications"
            Patterns   = @("WhatsApp","Messenger","Facebook","Instagram","Screenshots","Camera Roll","DCIM","Android","iOS")
            Action     = "Move"
            TargetRoot = "Images/Pellicule"
            Priority   = 5
        },

        # 6. Vidéos (déplacer vers Videos)
        @{
            Name       = "Videos"
            Patterns   = @("Videos")
            Action     = "Move"
            TargetRoot = "Videos"
            Priority   = 6
        }
    )

    # ------------------------------------------------------------------
    # MOTEUR DE RÈGLES
    # ------------------------------------------------------------------

    # Tri des règles par priorité
    $OrderedRules = $Rules | Sort-Object Priority

    foreach ($rule in $OrderedRules) {
        foreach ($pattern in $rule.Patterns) {
            if ($SourcePath -match [Regex]::Escape($pattern)) {

                # Si l’action est "Stay", on renomme sur place
                if ($rule.Action -eq "Stay") {
                    return @{
                        Action     = "Stay"
                        TargetRoot = $null
                        Rule       = $rule.Name
                    }
                }

                # Sinon on déplace vers la racine définie
                return @{
                    Action     = "Move"
                    TargetRoot = $rule.TargetRoot
                    Rule       = $rule.Name
                }
            }
        }
    }

    # ------------------------------------------------------------------
    # CAS PAR DÉFAUT : IMAGES / PELLICULE
    # ------------------------------------------------------------------
    return @{
        Action     = "Move"
        TargetRoot = "Images/Pellicule"
        Rule       = "Default"
    }
} # Get-TargetRoot

function Get-PathTags($fullPath) {
    $parts = $fullPath -replace "^/drive/root:/?", "" -split "/" | 
             Where-Object { $_ -and $_ -notmatch "Documents|Images|Vidéos|Musique|Pellicule|JPM" }
    return ($parts -join "_")
}

function New-SmartFileName {
    [CmdletBinding()]
    param(
        [string]$Timestamp,
        [string]$Context,
        [string]$OriginalName,
        [string]$Extension
    )

    # Nettoyage du nom original et du contexte
    $cleanOriginal = Convert-ToAscii $OriginalName
    $cleanContext  = Convert-ToAscii $Context

    # Suppression des mots redondants
    $filteredWords = ($cleanOriginal -split "_" | Where-Object { $_.Length -gt 1 -and $Timestamp -notmatch $_ }) -join "_"

    # Calcul de l’espace disponible pour le contexte
    $fixedLength = $Timestamp.Length + $filteredWords.Length + $Config.RenameMarker.Length + $Extension.Length + 5
    $availableForContext = $Config.MaxNameLen - $fixedLength

    $finalContext = ""
    if ($availableForContext -gt 5 -and $cleanContext) {
        $finalContext = if ($cleanContext.Length -gt $availableForContext) {
            $cleanContext.Substring($cleanContext.Length - $availableForContext)
        } else {
            $cleanContext
        }
    }

    # Construction finale
    $parts = @($Timestamp, $filteredWords, $finalContext) | Where-Object { $_ }
    return (($parts -join "_").Trim("_") + $Config.RenameMarker + $Extension)
}

# =====================================================================
# 5. AUTHENTIFICATION
# =====================================================================

function Connect-AzureGraph {
    [CmdletBinding()]
    param()

    Write-Log "Obtention du code d’authentification..." "WARN"

    $deviceCodeResponse = Invoke-RestMethod -Method POST `
        -Uri "https://login.microsoftonline.com/common/oauth2/v2.0/devicecode" `
        -Body @{ client_id = $Config.ClientId; scope = "Files.ReadWrite.All" }

    Write-Host "`n--- AUTHENTIFICATION REQUISE ---" -ForegroundColor Cyan
    Write-Host "Ouvrez : https://microsoft.com/devicelogin"
    Write-Host "Code : $($deviceCodeResponse.user_code)" -ForegroundColor Yellow
    Write-Host "-----------------------------------`n"

    while (!$Global:State.Headers) {
        Start-Sleep 5
        try {
            $auth = Invoke-RestMethod -Method POST `
                -Uri "https://login.microsoftonline.com/common/oauth2/v2.0/token" `
                -Body @{
                    grant_type  = "urn:ietf:params:oauth:grant-type:device_code"
                    client_id   = $Config.ClientId
                    device_code = $deviceCodeResponse.device_code
                }

            $Global:State.Headers = @{
                Authorization = "Bearer $($auth.access_token)"
                "Content-Type" = "application/json"
            }
        } catch {}
    }

    Write-Log "Authentification réussie." "SUCCESS"
}

# =====================================================================
# 6. PRÉ-CRÉATION DES DOSSIERS
# =====================================================================

function Test-OneDrivePath {
    [CmdletBinding()]
    param([string]$RelativePath)

    $RelativePath = $RelativePath.Trim('/')
    $pathParts = $RelativePath -split '/'
    $currentPath = ""

    foreach ($part in $pathParts) {

        $parentPath = $currentPath
        $currentPath += if ($currentPath -eq "") { $part } else { "/$part" }

        $encodedSegments = ($currentPath -split '/' | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/'

        # Vérification de l’existence du dossier
        try {
            Invoke-RestMethod -Headers $Global:State.Headers `
                -Uri "https://graph.microsoft.com/v1.0/me/drive/root:/${encodedSegments}:" `
                -Method Get -ErrorAction Stop > $null
        }
        catch {
            Write-Log "Création du dossier : /$currentPath" "DEBUG"

            $encodedParent = ($parentPath -split '/' | Where-Object {$_} | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/'

            $uriPost = if ($parentPath -eq "") {
                "https://graph.microsoft.com/v1.0/me/drive/root/children"
            } else {
                "https://graph.microsoft.com/v1.0/me/drive/root:/${encodedParent}:/children"
            }

            $body = @{ name = $part; folder = @{}; "@microsoft.graph.conflictBehavior" = "ignore" } | ConvertTo-Json

            Invoke-RestMethod -Headers $Global:State.Headers `
                -Uri $uriPost -Method POST -Body $body -ErrorAction Stop > $null
        }
    }
}

# =====================================================================
# 7. CHARGEMENT DU CACHE
# =====================================================================

function Import-Set-Cache {
    [CmdletBinding()]
    param()

    Write-Log "Nettoyage du vieux log d'exécution ... "
    if (Test-Path $LogFile) {
        Remove-Item $LogFile -Force
    }

    Write-Log "Chargement du cache OneDrive ... "
    if (!(Test-Path $IndexFile)) {
        Write-Log "Cache introuvable : $IndexFile" "ERROR"
        exit 1
    }
    $Global:State.Cache = Get-Content $IndexFile -Raw | ConvertFrom-Json -AsHashtable

    if (-not $Global:State.Cache.Files) {
        Write-Log "Aucun fichier dans le cache (section Files vide)." "ERROR"
        exit 1
    }


    # 3. Chargement des IDs déjà traités
    Write-Log "Chargement de la liste des ids/fichiers déjà traités ... "
    $Global:State.ProcessedIds = @{}

    if (Test-Path $ProcessedLog) {
        Get-Content $ProcessedLog | ForEach-Object {
            $id = $_.Trim()
            if ($id) {
                $Global:State.ProcessedIds[$id] = $true
            }
        }
        Write-Log "Fichiers déjà traités chargés : $($Global:State.ProcessedIds.Count)"
    } else {
        Write-Log "Aucun fichier traité précédemment (fichier $ProcessedLog absent)."
    }

    # 4. Construction d'une vue filtrée des fichiers à traiter
    Write-Log "Découverte des fichiers déjà traité ayant le marqueur '$($Config.RenameMarker)' ..."

    $Global:State.FilesToProcess = @{}

    foreach ($id in $Global:State.Cache.Files.Keys) {
        $fileMeta = $Global:State.Cache.Files[$id]

        # a) Si déjà dans ProcessedIds → ignorer
        if ($Global:State.ProcessedIds.ContainsKey($id)) {
            Write-Log "[DEBUG] Ignoré (déjà traité) : $id" "DEBUG"
            continue
        }

        # b) Si le nom contient le marqueur → l'ajouter à ProcessedIds
        if ($fileMeta.n -like "*$($Config.RenameMarker)*") {
            Write-Log "[DEBUG] Ajouté à ProcessedIds (déjà renommé) : $($fileMeta.p)/$($fileMeta.n)" "DEBUG"
            $Global:State.ProcessedIds[$id] = $true
            continue
        }

        # c) Sinon → fichier à traiter
        #$Global:State.FilesToProcess[$id] = $fileMeta

        # tempo stocke le nom dans un fichier tempo
        #$fileMeta.n | Add-Content "listefich.txt" -ErrorAction SilentlyContinue
    }

    Write-Log "Indexation terminée. Fichiers à traiter : $($Global:State.FilesToProcess.Count)"

    # todo initialiser le cache GPS ?? 
    
    # 5. Initialisation du rapport d'exécution CSV
    "Timestamp,ID,Status,OldPath,NewPath,Error" | Set-Content $ExecutionReport
} # Import-Set-Cache

# =====================================================================
# 8. PLANIFICATION
# =====================================================================


function New-Plan {
    [CmdletBinding()]
    param()

    Write-Log "Analyse des fichiers..."
    Write-Log "[DEBUG] Début de New-Plan" "DEBUG"

    foreach ($fileId in $Global:State.Cache.Files.Keys) {

        # --- Informations de base ---
        $fileMeta = $Global:State.Cache.Files[$fileId]
        $extension = [System.IO.Path]::GetExtension($fileMeta.n).ToLower()

        Write-Log "[DEBUG] ----------------------------------------------" "DEBUG"
        Write-Log "[DEBUG] Analyse du fichier" "DEBUG"
        Write-Log "[DEBUG] ID             : $fileId" "DEBUG"
        Write-Log "[DEBUG] Nom original   : $($fileMeta.n)" "DEBUG"
        Write-Log "[DEBUG] Chemin source  : $($fileMeta.p)" "DEBUG"
        Write-Log "[DEBUG] Extension      : $extension" "DEBUG"
        Write-Log "[DEBUG] Date fichier   : $($fileMeta.d)" "DEBUG"

        # --- Filtres d'exclusion ---
        if ($Global:State.ProcessedIds.ContainsKey($fileId)) {
            Write-Log "[DEBUG] Ignoré : déjà traité" "DEBUG"
            continue
        }

        if ($fileMeta.n -match $Config.RenameMarker) {
            Write-Log "[DEBUG] Ignoré : déjà renommé ($($Config.RenameMarker))" "DEBUG"
            continue
        }

        if (-not $Config.ExtensionMap.ContainsKey($extension)) {
            Write-Log "[DEBUG] Ignoré : extension non supportée ($extension)" "DEBUG"
            continue
        }

        # --- Extraction date + timestamp ---
        $fileDate = [DateTime]$fileMeta.d
        $timestamp = $fileDate.ToString("yyyyMMdd_HHmmss")

        # --- Contexte (3 derniers dossiers utiles) ---
        $pathParts = $fileMeta.p -split "/" | Where-Object { $_ -and $_ -notmatch "drive|root|Images|Videos|Pellicule" }
        $context = if ($pathParts.Count -gt 0) { ($pathParts[-3..-1]) -join "_" } else { "" }

        Write-Log "[DEBUG] Contexte détecté : $context" "DEBUG"

        # --- Nouveau nom intelligent ---
        $newName = New-SmartFileName `
            -Timestamp $timestamp `
            -Context $context `
            -OriginalName ([System.IO.Path]::GetFileNameWithoutExtension($fileMeta.n)) `
            -Extension $extension

        Write-Log "[DEBUG] Nouveau nom généré : $newName" "DEBUG"

        # --- Règle de destination ---
        $rule = Get-TargetRoot $fileMeta.p

        Write-Log "[DEBUG] Règle appliquée   : $($rule.Rule)" "DEBUG"
        Write-Log "[DEBUG] Action           : $($rule.Action)" "DEBUG"
        Write-Log "[DEBUG] Racine cible     : $($rule.TargetRoot)" "DEBUG"

        $root = $rule.TargetRoot

        # --- Construction du chemin final ---
        $rawDestination = if ($root -like "Pour coffre fort*") {
            "$root/$($Config.ExtensionMap[$extension])/$($fileDate.Year)/$($fileDate.ToString('MM'))"
        } else {
            "$root/$($fileDate.Year)/$($fileDate.ToString('MM'))"
        }

        $cleanDestination = Convert-ToAscii $rawDestination -IsPath $true
        $fullDestination = "/$cleanDestination/$newName"

        Write-Log "[DEBUG] Destination finale : $fullDestination" "DEBUG"

        # --- Ajout au plan ---
        $Global:State.PlannedActions.Add([PSCustomObject]@{
            Id        = $fileId
            SrcPath   = $fileMeta.p
            SrcName   = $fileMeta.n
            DstDir    = $cleanDestination
            DstName   = $newName
            FullDst   = $fullDestination
        })

        Write-Log "[DEBUG] Fin analyse fichier" "DEBUG"
        Write-Log "[DEBUG] ----------------------------------------------" "DEBUG"
    }

    Write-Log "Plan généré : $($Global:State.PlannedActions.Count) fichiers." "SUCCESS"
    Write-Log "[DEBUG] Fin de New-Plan" "DEBUG"
}

function traitement {
    $Log = New-Object System.Collections.Generic.List[string]
    $Log.Add("=== RAPPORT V14.5 - $(Get-Date) ===")

    Write-Host "`n--- DÉMARRAGE DE L'ANALYSE ($TotalFiles fichiers) ---" -ForegroundColor Cyan

    $count = 0
    foreach ($id in $FileIds) {
        $count++
        $fileMeta = $Cache.Files[$id]
        
        # Progression
        $elapsed = (Get-Date) - $StartTime
        $avgTime = $elapsed.TotalSeconds / $count
        $remainingStr = "{0:hh\:mm\:ss}" -f [TimeSpan]::FromSeconds($avgTime * ($TotalFiles - $count))

        if ($count % 10 -eq 0) {
            Write-Progress -Activity "Analyse $([Math]::Round(($count/$TotalFiles)*100,1))%" `
                        -Status "Fichiers: $count/$TotalFiles | Restant: $remainingStr" `
                        -PercentComplete (($count / $TotalFiles) * 100)
        }

        if (!$fileMeta.d) { continue }
        $ext = [System.IO.Path]::GetExtension($fileMeta.n).ToLower()
        $dateRef = [DateTime]$fileMeta.d
        
        $villeStr = Get-LocationName $fileMeta.gps
        $tags = Get-PathTags $fileMeta.p
        $name = ([System.IO.Path]::GetFileNameWithoutExtension($fileMeta.n) -replace "\(Copie.*\)|- Copie|\(1\)", "").Trim()
        
        $newName = ""
        $targetDir = ""

        # NOMENCLATURE PHOTOS / VIDÉOS
        if ($ext -match ".jpg|.jpeg|.png|.heic|.mp4|.mov") {
            $parts = New-Object System.Collections.Generic.List[string]
            $parts.Add($dateRef.ToString("yyyyMMdd_HHmmss"))
            if ($villeStr) { $parts.Add($villeStr) }
            if ($tags) { $parts.Add($tags) }
            
            if ($ext -match ".mp4|.mov") {
                if($fileMeta.dur){$parts.Add($fileMeta.dur)}; if($fileMeta.res){$parts.Add($fileMeta.res)}
                $targetDir = "/Vidéos/Pellicule/$($dateRef.Year)/$($dateRef.ToString('MM'))"
            } else {
                if ($name -and $tags -notlike "*$name*" -and $name -notmatch "^\d+$") { $parts.Add($name) }
                if($fileMeta.cam){$parts.Add($fileMeta.cam)}
                $targetDir = "/Images/Pellicule/$($dateRef.Year)/$($dateRef.ToString('MM'))"
            }
            $newName = ($parts -join "_") + $ext
        }
        # NOMENCLATURE AUDIO
        elseif ($ext -match ".mp3|.m4a|.flac") {
            $artiste = if($fileMeta.art){$fileMeta.art}else{"Inconnu"}
            $album = if($fileMeta.alb){$fileMeta.alb}else{"Inconnu"}
            $newName = "$artiste - $album - $name$ext"
            $targetDir = "/Musique/$artiste/$album"
        }

        if ($newName) {
            $newName = ($newName -replace '[\\\/:*?"<>|]', '-') -replace '_+', '_'
            $Log.Add("SRC : $($fileMeta.p)/$($fileMeta.n)")
            $Log.Add("DST : $targetDir/$newName")
        }
    }

    $Log | Set-Content $LogFile
    Write-Host "`nTERMINÉ. Log généré : $LogFile" -ForegroundColor Green

}

# =====================================================================
# 9. EXÉCUTION
# =====================================================================

function Invoke-Moves {
    [CmdletBinding()]
    param()

    Write-Log "Début du déplacement..." "WARN"

    $total = $Global:State.PlannedActions.Count
    $index = 0

    foreach ($action in $Global:State.PlannedActions) {

        $index++
        Write-Progress -Activity "Déplacement OneDrive" `
            -Status "Fichier $index / $total" `
            -PercentComplete (($index / $total) * 100)

        try {
            $body = @{
                parentReference = @{ path = "/drive/root:${($action.DstDir)}" }
                name = $action.DstName
            } | ConvertTo-Json

            Invoke-RestMethod -Headers $Global:State.Headers `
                -Uri "https://graph.microsoft.com/v1.0/me/drive/items/$($action.Id)" `
                -Method PATCH -Body $body -ErrorAction Stop > $null

            "$(Get-Date -Format 'HH:mm'),$($action.Id),SUCCESS,$($action.SrcPath),$($action.FullDst)," |
                Add-Content $ExecutionReport

            $action.Id | Add-Content $ProcessedLog

            $Global:State.Cache.Files[$action.Id].p = "/drive/root:${($action.DstDir)}"
            $Global:State.Cache.Files[$action.Id].n = $action.DstName
        }
        catch {
            $errorDetails = Get-ErrorDetails $_
            Write-Log "Erreur sur $($action.Id) : $errorDetails" "ERROR"

            "$(Get-Date -Format 'HH:mm'),$($action.Id),ERROR,$($action.SrcPath),$($action.FullDst),$errorDetails" |
                Add-Content $ExecutionReport
        }
    }

    $Global:State.Cache | ConvertTo-Json -Depth 10 | Set-Content $IndexFile
    Write-Log "Déplacement terminé." "SUCCESS"
}



# =====================================================================
# 10. MAIN
# =====================================================================

function Start-OneDriveOrganizer {
    [CmdletBinding()]
    param()

    Clear-Host
    Write-Log "Démarrage de l'organisateur..."

    Import-Set-Cache

    traitement

    #New-Plan

    if ($Global:State.PlannedActions.Count -eq 0) {
        Write-Log "Aucun fichier à traiter." "WARN"
        return
    }


    # le temps qu'on stabilise le code
    exit

    if (-not $Execute) {
        Write-Log "MODE APERÇU  Utilisez -Execute `$true pour appliquer les changements." "WARN"
        $Global:State.PlannedActions[0] | Format-List
        return
    }

    Connect-AzureGraph

    # Pré-création des dossiers
    $uniqueDirs = $Global:State.PlannedActions.DstDir | Select-Object -Unique | Sort-Object
    foreach ($dir in $uniqueDirs) { Test-OneDrivePath $dir }

    Invoke-Moves
} # Start-OneDriveOrganizer

Start-OneDriveOrganizer