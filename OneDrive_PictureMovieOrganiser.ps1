# =====================================================================
# Organisateur OneDrive — Pipeline moderne fusionné
# - Analyse, classification, renommage intelligent, planification
# - Barre de progression intégrée
# - Logging harmonisé
# - GPS, tags, caméra, source, destination
# - Version optimisée et cohérente
# =====================================================================

param (
    [bool]$Execute = $false,                          # Exécute réellement les déplacements
    [bool]$ResetCache = $false,                          # Réinitialise les fichiers internes sauf GPS et cache OneDrive
    [string]$IndexFile = ".\_cache\onedrive_cache.json",  # Cache OneDrive (fichier source)
    [string]$LogFile = ".\_cache\organisation_log.txt", # Log des opérations
    [string]$ProcessedLog = ".\_cache\processed_ids.log", # IDs déjà traités
    [string]$ExecutionReport = ".\_cache\azure_sync_report.csv", # Rapport CSV des opérations
    [string]$GpsCacheFile = ".\_cache\gps_cache.json",   # Cache GPS
    [bool]$VerboseMode = $false,                            # Active les logs DEBUG
        # === NOUVEAUX PARAMÈTRES ===
    [bool]$Analyze = $false,          # Analyse du plan.json
    [bool]$DryRun = $false,           # Mode dry-run détaillé
    [bool]$Validate = $false,         # Validation du cache OneDrive
    [string]$DebugId = "",            # Debug d’un fichier précis
    [bool]$ReportIgnored = $false     # Générer rapport fichiers ignorés
)

# --- Forcer l'affichage de Write-Progress (au cas où un autre script l'a désactivé)
$ProgressPreference = 'Continue'


# =====================================================================
# CONFIGURATION GLOBALE (PLACÉE AVANT LES MODULES)
# =====================================================================

$Config = [PSCustomObject]@{
    RenameMarker = "--odr--"      # Marqueur de renommage
    MaxNameLen   = 80             # Longueur max des noms de fichiers
    ClientId     = "176fc7bc-42c9-4a25-82b5-0ad584d3c061" # ClientId Graph
    ExtensionMap = $ExtensionMap  # Table de mapping des extensions
}

# =====================================================================
# MODULES EXTERNES
# =====================================================================

Import-Module "$PSScriptRoot\modules\OneDriveTools.psm1" -ArgumentList $Config.ClientId, $TokenFile, $LogFile, $VerboseMode -Force
Import-Module "$PSScriptRoot\modules\OneDriveOrganize.psm1" -Force
Import-Module "$PSScriptRoot\modules\GpsTools.psm1" -ArgumentList $GpsCacheFile -Force
# =====================================================================
# CRÉATION DU DOSSIER _cache SI NÉCESSAIRE
# =====================================================================
try {
    $cacheFolder = Split-Path $IndexFile -Parent
    if ($cacheFolder -and -not (Test-Path $cacheFolder)) {
        New-Item -ItemType Directory -Path $cacheFolder -Force | Out-Null
    }
}
catch {
    Write-Log "Erreur lors de la création du dossier cache : $($_.Exception.Message)" "ERROR"
}

# =====================================================================
# ÉTAT GLOBAL
# =====================================================================

# État global du script
$Global:State = @{
    Headers        = $null
    Cache          = $null
    ProcessedIds   = @{}
    PlannedActions = New-Object System.Collections.Generic.List[PSCustomObject]
    FilesToProcess = @{}
}


# =====================================================================
# RESET CACHE (strict minimum)
# =====================================================================

if ($ResetCache) {
    try {
        Write-Log "Reset du cache interne..." "WARN"

        $cacheFolder = Split-Path $IndexFile -Parent
        $planFile = Join-Path $cacheFolder "plan.json"
        $hashFile = Join-Path $cacheFolder "cache_hash.txt"
        $filesToDelete = @(
            $ProcessedLog,
            $ExecutionReport,
            $LogFile,
            $planFile,
            $hashFile
        )

        foreach ($f in $filesToDelete) {
            if ($f -and (Test-Path $f)) {
                Remove-Item $f -Force
            }
        }

        Write-Log "Reset terminé (GPS + onedrive_cache.json conservés)." "SUCCESS"
    }
    catch {
        Write-Log "Erreur lors du reset du cache : $($_.Exception.Message)" "ERROR"
    }
}

# =====================================================================
# HASH DU CACHE
# =====================================================================

# Calcule le hash du fichier de cache OneDrive
function Get-CacheHash {
    try {
        if (-not (Test-Path $IndexFile)) {
            Write-Log "Impossible de calculer le hash, fichier absent : $IndexFile" "WARN"
            return $null
        }
        return (Get-FileHash $IndexFile -Algorithm SHA256).Hash
    }
    catch {
        Write-Log "Erreur calcul hash : $($_.Exception.Message)" "ERROR"
        return $null
    }
} # Get-CacheHash

# =====================================================================
# REPRISE AUTOMATIQUE
# =====================================================================

# Charge un plan existant si le hash du cache est identique
function Get-ExistingPlan {
    param(
        [string]$CurrentHash  # Hash actuel du cache OneDrive
    )

    try {
        $cacheFolder = Split-Path $IndexFile -Parent
        $planFile = Join-Path $cacheFolder "plan.json"
        $hashFile = Join-Path $cacheFolder "cache_hash.txt"

        if (-not (Test-Path $planFile) -or -not (Test-Path $hashFile)) {
            return $null
        }

        $oldHash = Get-Content $hashFile -ErrorAction Stop

        if ($oldHash -eq $CurrentHash) {
            Write-Log "Plan existant valide — reprise sans analyse." "SUCCESS"
            return (Get-Content $planFile -Raw | ConvertFrom-Json)
        }

        Write-Log "Plan existant invalide (hash différent)." "WARN"
        return $null
    }
    catch {
        Write-Log "Erreur lors du chargement du plan existant : $($_.Exception.Message)" "ERROR"
        return $null
    }
} # Get-ExistingPlan


# =====================================================================
# UTILITAIRES
# =====================================================================

# Retourne les détails d'une erreur HTTP
function Get-ErrorDetails {
    param(
        $Exception  # Exception à analyser
    )
    try {
        if ($Exception.Response) {
            $reader = New-Object System.IO.StreamReader($Exception.Response.GetResponseStream())
            return $reader.ReadToEnd()
        }
    }
    catch {
        Write-Log "Erreur lors de la lecture des détails d'erreur : $($_.Exception.Message)" "ERROR"
    }
    return $Exception.Message
} # Get-ErrorDetails

# Convertit une chaîne en ASCII safe pour noms de fichiers/chemins
function Convert-ToAscii {
    param(
        [string]$Text,          # Texte à normaliser
        [bool]$IsPath = $false  # Indique si c'est un chemin
    )

    try {
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
    catch {
        Write-Log "Erreur Convert-ToAscii : $($_.Exception.Message)" "ERROR"
        return ""
    }
} # Convert-ToAscii

# =====================================================================
# AUTHENTIFICATION
# =====================================================================

# Obtient un token Graph et prépare les en-têtes
function Connect-AzureGraph {
    try {
        Write-Log "Obtention du token Graph via module..."
        $auth = Get-GraphToken

        if (-not $auth.access_token) {
            Write-Log "Échec token Graph" "ERROR"
            throw "Impossible d'obtenir un token Graph."
        }

        $Global:State.Headers = @{
            Authorization  = "Bearer $($auth.access_token)"
            "Content-Type" = "application/json"
        }

        Write-Log "Token Graph chargé." "SUCCESS"
    }
    catch {
        Write-Log "Erreur Connect-AzureGraph : $($_.Exception.Message)" "ERROR"
        throw
    }
} # Connect-AzureGraph

# =====================================================================
# PRÉ-CRÉATION DES DOSSIERS
# =====================================================================

# Vérifie/crée récursivement un chemin OneDrive
function Test-OneDrivePath {
    param(
        [string]$RelativePath  # Chemin relatif OneDrive
    )

    try {
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

                $encodedParent = ($parentPath -split '/' | Where-Object { $_ } | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/'
                $uriPost = if ($parentPath -eq "") {
                    "https://graph.microsoft.com/v1.0/me/drive/root/children"
                }
                else {
                    "https://graph.microsoft.com/v1.0/me/drive/root:/${encodedParent}:/children"
                }

                $body = @{ name = $part; folder = @{}; "@microsoft.graph.conflictBehavior" = "ignore" } | ConvertTo-Json

                Invoke-RestMethod -Headers $Global:State.Headers `
                    -Uri $uriPost -Method POST -Body $body -ErrorAction Stop > $null
            }
        }
    }
    catch {
        Write-Log "Erreur Test-OneDrivePath ($RelativePath) : $($_.Exception.Message)" "ERROR"
    }
} # Test-OneDrivePath

# =====================================================================
# CHARGEMENT DU CACHE
# =====================================================================

# Charge le cache OneDrive et prépare FilesToProcess / ProcessedIds
function Import-Set-Cache {
    try {
        # Write-Log "Nettoyage du vieux log $LogFile"
        # if (Test-Path $LogFile) { Remove-Item $LogFile -Force }

        Write-Log "Chargement du cache OneDrive $IndexFile ..."
        if (!(Test-Path $IndexFile)) {
            Write-Log "Cache introuvable : $IndexFile" "ERROR"
            exit 1
        }

        $Global:State.Cache = Get-Content $IndexFile -Raw | ConvertFrom-Json -AsHashtable

        if (-not $Global:State.Cache.Files) {
            Write-Log "Aucun fichier dans le cache." "ERROR"
            exit 1
        }

        Write-Log "Chargement des IDs déjà traités ($ProcessedLog) ..."
        $Global:State.ProcessedIds = @{}
        $Global:State.FilesToProcess = @{}

        if (Test-Path $ProcessedLog) {
            Get-Content $ProcessedLog | ForEach-Object {
                $id = $_.Trim()
                if ($id) { $Global:State.ProcessedIds[$id] = $true }
            }
            Write-Log "Fichiers déjà traités : $($Global:State.ProcessedIds.Count)"
        }
        else {
            Write-Log "Aucun fichier traité précédemment (fichier $ProcessedLog absent)."
        }

        Write-Log "Découverte des fichiers déjà traités ayant le marqueur '$($Config.RenameMarker)' ..."
        $index = 0
        $total = $Global:State.Cache.Files.Count
        foreach ($id in $Global:State.Cache.Files.Keys) {
            $index++
            if ($index % 500 -eq 0) {
                Write-Progress -Activity "Analyse des fichiers" `
                    -Status "$index / $total" `
                    -PercentComplete (($index / $total) * 100)
            }
            $fileMeta = $Global:State.Cache.Files[$id]

            # a) Si déjà dans ProcessedIds → ignorer
            if ($Global:State.ProcessedIds.ContainsKey($id)) {
                Write-Log "Ignoré (déjà traité) : $id" "DEBUG"
                continue
            }
            # b) Si le nom contient le marqueur → l'ajouter à ProcessedIds
            if ($fileMeta.n -like "*$($Config.RenameMarker)*") {
                Write-Log "Ajouté à ProcessedIds (déjà renommé) : $($fileMeta.p)/$($fileMeta.n)" "DEBUG"
                $Global:State.ProcessedIds[$id] = $true
                continue
            }

            # c) Sinon → fichier à traiter
            $Global:State.FilesToProcess[$id] = $fileMeta
        }

        Write-Progress -Activity "Analyse terminée" -Completed
        Write-Log "Indexation terminée. Fichiers à traiter : $($Global:State.FilesToProcess.Count)"
        "Timestamp,ID,Status,OldPath,NewPath,Error" | Set-Content $ExecutionReport
    }
    catch {
        Write-Log "Erreur Import-Set-Cache : $($_.Exception.Message)" "ERROR"
        throw
    }
} # Import-Set-Cache

# =====================================================================
# PIPELINE FUSIONNÉ : ANALYSE + BARRE DE PROGRESSION + PLAN
# =====================================================================

# Analyse les fichiers et construit le plan de déplacement
function New-Plan {
    Write-Log "Analyse des fichiers (pipeline fusionné)..."

    try {
        $FileIds = $Global:State.FilesToProcess.Keys
        $TotalFiles = $FileIds.Count
        $StartTime = Get-Date
        $count = 0

        foreach ($fileId in $FileIds) {

            $count++
            $fileMeta = $Global:State.Cache.Files[$fileId]
            $extension = [System.IO.Path]::GetExtension($fileMeta.n).ToLower()

            if ($count % 2000 -eq 0) {

                $elapsed = (Get-Date) - $StartTime
                $avgTime = $elapsed.TotalSeconds / [math]::Max($count, 1)
                $remainingStr = "{0:hh\:mm\:ss}" -f [TimeSpan]::FromSeconds($avgTime * ($TotalFiles - $count))

                Write-Progress -Activity "Analyse OneDrive" `
                    -Status "$count / $TotalFiles | Restant: $remainingStr" `
                    -PercentComplete (($count / $TotalFiles) * 100)

                try {
                    $cacheFolder = Split-Path $IndexFile -Parent
                    $planFile = Join-Path $cacheFolder "plan.json"
                    $Global:State.PlannedActions |
                    ConvertTo-Json -Depth 10 |
                    Set-Content $planFile
                }
                catch {
                    Write-Log "Erreur sauvegarde progression : $($_.Exception.Message)" "ERROR"
                }
            }

            Write-Log "----------------------------------------------" "DEBUG"
            Write-Log "Analyse du fichier" "DEBUG"
            Write-Log "ID             : $fileId" "DEBUG"
            Write-Log "Nom original   : $($fileMeta.n)" "DEBUG"
            Write-Log "Chemin source  : $($fileMeta.p)" "DEBUG"
            Write-Log "Extension      : $extension" "DEBUG"
            Write-Log "Date fichier   : $($fileMeta.d)" "DEBUG"
            Write-Log "GPS            : $($fileMeta.gps)" "DEBUG"

            # Classification
            $category = Get-SmartCategory -Path $fileMeta.p -Extension $extension
            Write-Log "Classification intelligente = ($category)" "DEBUG"

            if (-not $Config.ExtensionMap.ContainsKey($extension)) {
                Write-Log "Ignoré : extension non supportée ($extension)" "DEBUG"
                continue
            }

            $fileDate = [DateTime]$fileMeta.d

            # GPS
            $gpsLocation = $null
            if ($fileMeta.gps) {
                $gpsLocation = Get-LocationName $fileMeta.gps
                Write-Log "Localisation GPS : $gpsLocation" "DEBUG"
            }

            # Tags
            $pathTags = Get-PathTags $fileMeta.p
            Write-Log "Tags de chemin : $pathTags" "DEBUG"

            # Caméra
            $camera = $fileMeta.cam

            # Source hint
            $sourceHint = ""
            if ($fileMeta.p -match "WhatsApp") { $sourceHint = "WhatsApp" }
            elseif ($fileMeta.p -match "Messenger") { $sourceHint = "Messenger" }
            elseif ($fileMeta.p -match "Instagram") { $sourceHint = "Instagram" }

            # Nouveau nom
            $originalNameNoExt = [System.IO.Path]::GetFileNameWithoutExtension($fileMeta.n)
            if ([string]::IsNullOrWhiteSpace($originalNameNoExt)) {
                Write-Log "Nom de fichier vide, fichier ignoré : $($fileMeta.p)/$($fileMeta.n)" "WARN"
                continue
            }

            $newName = New-SmartFileName `
                -DateRef      $fileDate `
                -OriginalName $originalNameNoExt `
                -Extension    $extension `
                -GpsLocation  $gpsLocation `
                -PathTags     $pathTags `
                -Camera       $camera `
                -SourceHint   $sourceHint

            Write-Log "Nouveau nom généré : $newName" "DEBUG"
            # Destination
            $dest = Get-DestinationPath `
                -Category     $category `
                -FileMeta     $fileMeta `
                -Extension    $extension `
                -ExtensionMap $Config.ExtensionMap `
                -NewName      $newName `
                -FileDate     $fileDate

            Write-Log "Chemin destination = ($($dest.CleanDestination))" "DEBUG"
            $cleanDestination = $dest.CleanDestination
            $fullDestination = $dest.FullDestination

            # Vérification si déjà à la bonne place
            $srcDirClean = $fileMeta.p -replace "^/drive/root:", ""
            $currentPath = "$($srcDirClean.Trim('/'))/$($fileMeta.n)"

            if ($currentPath -eq $fullDestination.Trim('/')) {
                Write-Log "Déjà à la bonne place : $($fileMeta.n)" "DEBUG"
                continue
            }

            # Ajout au plan
            $Global:State.PlannedActions.Add([PSCustomObject]@{
                    Id      = $fileId
                    SrcPath = $fileMeta.p
                    SrcName = $fileMeta.n
                    DstDir  = "/$($cleanDestination.Trim('/'))"
                    DstName = $newName
                    FullDst = $fullDestination
                })
        }

        Write-Log "Plan généré : $($Global:State.PlannedActions.Count) fichiers." "SUCCESS"
        # Sauvegarde du plan JSON
        try {
            $cacheFolder = Split-Path $IndexFile -Parent
            $planFile = Join-Path $cacheFolder "plan.json"
            $Global:State.PlannedActions | ConvertTo-Json -Depth 10 | Set-Content $planFile
            Write-Log "Plan sauvegardé dans $planFile" "SUCCESS"
        }
        catch {
            Write-Log "Erreur lors de la sauvegarde du plan : $($_.Exception.Message)" "ERROR"
        }
    }
    catch {
        Write-Log "Erreur New-Plan : $($_.Exception.Message)" "ERROR"
        throw
    }
} # New-Plan

# =====================================================================
# DÉPLACEMENT
# =====================================================================

# Applique les déplacements planifiés via Graph
function Invoke-Moves {
    Write-Log "Début du déplacement..." "WARN"

    try {
        $total = $Global:State.PlannedActions.Count
        $index = 0

        foreach ($action in $Global:State.PlannedActions) {

            $index++
            if ($index % 200 -eq 0) {
                Write-Progress -Activity "Déplacement OneDrive" `
                    -Status "Fichier $index / $total" `
                    -PercentComplete (($index / $total) * 100)
            }

            try {
                $body = @{
                    parentReference = @{ path = "/drive/root:${($action.DstDir)}" }
                    name            = $action.DstName
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
    catch {
        Write-Log "Erreur Invoke-Moves : $($_.Exception.Message)" "ERROR"
        throw
    }
} # Invoke-Moves


function Test-Plan {
    try {
        # Analyse de l'état en mémoire au lieu de recharger le fichier JSON
        $plan = $Global:State.PlannedActions

        if (-not $plan -or $plan.Count -eq 0) {
            Write-Log "Aucun plan chargé pour analyse." "WARN"
            return
        }

        Write-Log "=== ANALYSE DU PLAN ===" "INFO"
        Write-Log "Total actions : $($plan.Count)" "INFO"

        # 1. Vérifier les collisions de noms
        $duplicates = $plan.FullDst | Group-Object | Where-Object { $_.Count -gt 1 }
        if ($duplicates) {
            Write-Log "Collisions détectées :" "ERROR"
            foreach ($d in $duplicates) {
                Write-Log " - $($d.Name) ($($d.Count) occurrences)" "ERROR"
            }
        }
        else {
            Write-Log "Aucune collision détectée." "SUCCESS"
        }

        # 2. Vérifier les chemins trop longs
        $tooLong = $plan | Where-Object { $_.FullDst.Length -gt 250 }
        if ($tooLong) { Write-Log "Chemins > 250 caractères : $($tooLong.Count)" "INFO" }

        Write-Log "Analyse terminée." "SUCCESS"
    }
    catch {
        Write-Log "Erreur Test-Plan : $($_.Exception.Message)" "ERROR"
    }
}

function Debug-File {
    param(
        [string]$Id
    )
    try {
        if (-not $Global:State.Cache) {
            Write-Log "Cache non chargé." "ERROR"
            return
        }

        if (-not $Global:State.Cache.Files.ContainsKey($Id)) {
            Write-Log "ID introuvable dans le cache." "ERROR"
            return
        }

        $f = $Global:State.Cache.Files[$Id]

        Write-Log "=== DEBUG FILE $Id ===" "INFO"
        Write-Log "Chemin : $($f.p)" "INFO"
        Write-Log "Nom    : $($f.n)" "INFO"
        Write-Log "Date   : $($f.d)" "INFO"
        Write-Log "GPS    : $($f.gps)" "INFO"
        Write-Log "Caméra : $($f.cam)" "INFO"
        Write-Log "========================" "INFO"

    }
    catch {
        Write-Log "Erreur Invoke-Moves : $($_.Exception.Message)" "ERROR"
        throw
    }

} # Debug-File

function Test-Cache {
    try {
        Write-Log "=== VALIDATION DU CACHE ===" "INFO"

        $cache = $Global:State.Cache.Files
        $total = $cache.Count

        $missingPath = $cache.GetEnumerator() | Where-Object { -not $_.Value.p }
        $missingName = $cache.GetEnumerator() | Where-Object { -not $_.Value.n }
        $badPrefix = $cache.GetEnumerator() | Where-Object { $_.Value.p -notmatch "^/drive/root:" }
        $badExt = $cache.GetEnumerator() | Where-Object {
            $ext = [IO.Path]::GetExtension($_.Value.n).ToLower()
            -not $Config.ExtensionMap.ContainsKey($ext)
        }

        Write-Log "Total entrées : $total" "INFO"
        Write-Log "Chemin manquant : $($missingPath.Count)" "WARN"
        Write-Log "Nom manquant : $($missingName.Count)" "WARN"
        Write-Log "Chemin invalide : $($badPrefix.Count)" "WARN"
        Write-Log "Extension inconnue : $($badExt.Count)" "WARN"

        Write-Log "Validation terminée." "SUCCESS"
    }
    catch {
        Write-Log "Erreur Invoke-Moves : $($_.Exception.Message)" "ERROR"
        throw
    }
    
} # Test-Cache

function Start-DryRun {
    try {
        Write-Log "=== MODE DRY-RUN ===" "INFO"

        Test-Plan

        Write-Log "Aucun déplacement ne sera effectué." "WARN"
        Write-Log "Vous pouvez maintenant exécuter : -Execute `$true" "INFO"

    }
    catch {
        Write-Log "Erreur Invoke-Moves : $($_.Exception.Message)" "ERROR"
        throw
    }
} # Start-DryRun

function Repair-Cache {
    try {
        Write-Log "=== FIX CACHE : Nettoyage automatique du cache OneDrive ===" "WARN"

        $cache = $Global:State.Cache.Files
        $removed = 0
        $fixedExt = 0

        # On extrait les clés dans un tableau fixe pour éviter l'erreur d'énumération
        $keys = @($cache.Keys)

        foreach ($id in $keys) {
            $f = $cache[$id]

            # Supprimer les entrées sans chemin ou nom
            if (-not $f.p -or -not $f.n) {
                $cache.Remove($id)
                $removed++
                continue
            }

            # Supprimer les chemins invalides
            if ($f.p -notmatch "^/drive/root:") {
                $cache.Remove($id)
                $removed++
                continue
            }

            # Corriger les extensions polluées (ex: .jpg?width=...)
            $ext = [IO.Path]::GetExtension($f.n).ToLower()
            $cleanExt = $ext -replace "\?.*$","" -replace "\&.*$",""

            if ($ext -ne $cleanExt) {
                $f.n = $f.n.Replace($ext, $cleanExt)
                $fixedExt++
            }

            # Supprimer les extensions inconnues
            if (-not $Config.ExtensionMap.ContainsKey($cleanExt)) {
                $cache.Remove($id)
                $removed++
                continue
            }
        }

        Write-Log "Fix terminé : $removed entrées supprimées, $fixedExt extensions corrigées." "SUCCESS"
        $Global:State.Cache | ConvertTo-Json -Depth 10 | Set-Content $IndexFile
    }
    catch {
        Write-Log "Erreur Repair-Cache : $($_.Exception.Message)" "ERROR"
    }
}

function Repair-Collisions {
    try {
        Write-Log "=== FIX COLLISIONS : Résolution proactive ===" "WARN"
        
        # On travaille directement sur la liste en mémoire
        $groups = $Global:State.PlannedActions | Group-Object FullDst | Where-Object { $_.Count -gt 1 }

        if (-not $groups) {
            Write-Log "Aucune collision détectée." "SUCCESS"
            return
        }

        foreach ($g in $groups) {
            # Le premier fichier garde son nom, les suivants sont indexés
            for ($i = 1; $i -lt $g.Count; $i++) {
                $item = $g.Group[$i]
                $ext = [System.IO.Path]::GetExtension($item.DstName)
                $nameOnly = [System.IO.Path]::GetFileNameWithoutExtension($item.DstName)
                
                # Mise à jour du nom et du chemin complet de destination
                $item.DstName = "$nameOnly`_$i$ext"
                $item.FullDst = "$($item.DstDir.TrimEnd('/'))/$($item.DstName)"
            }
        }

        # On sauvegarde le plan modifié sur le disque immédiatement
        $planFile = Join-Path (Split-Path $IndexFile -Parent) "plan.json"
        $Global:State.PlannedActions | ConvertTo-Json -Depth 10 | Set-Content $planFile

        Write-Log "Collisions résolues et plan synchronisé sur disque." "SUCCESS"
    }
    catch {
        Write-Log "Erreur Repair-Collisions : $($_.Exception.Message)" "ERROR"
    }
}


function Repair-Paths {
    # Normalise les chemins OneDrive (double slash, espaces, caractères invalides).
    try {
        Write-Log "=== FIX PATHS : Normalisation des chemins ===" "WARN"

        foreach ($entry in $Global:State.Cache.Files.GetEnumerator()) {
            $f = $entry.Value

            if ($f.p) {
                $clean = $f.p -replace "//+", "/" -replace "\s+", "_"
                if ($clean -ne $f.p) {
                    $f.p = $clean
                }
            }
        }

        Write-Log "Normalisation des chemins terminée." "SUCCESS"
    }
    catch {
        Write-Log "Erreur Repair-Paths : $($_.Exception.Message)" "ERROR"
    }
} # Repair-Paths

function Repair-Names {
    # Corrige les noms invalides (espaces, caractères interdits, noms trop longs).
    try {
        Write-Log "=== FIX NAMES : Normalisation des noms ===" "WARN"

        foreach ($entry in $Global:State.Cache.Files.GetEnumerator()) {
            $f = $entry.Value

            if ($f.n) {
                $clean = $f.n -replace "[^\w\.\-]", "_" -replace "_+", "_"

                if ($clean.Length -gt $Config.MaxNameLen) {
                    $clean = $clean.Substring(0, $Config.MaxNameLen)
                }

                $f.n = $clean
            }
        }

        Write-Log "Normalisation des noms terminée." "SUCCESS"
    }
    catch {
        Write-Log "Erreur Repair-Names : $($_.Exception.Message)" "ERROR"
    }
} # Repair-Names


function Repair-GPS {
    # Supprime les coordonnées GPS invalides ou corrompues.
    try {
        Write-Log "=== FIX GPS : Nettoyage des GPS invalides ===" "WARN"

        foreach ($entry in $Global:State.Cache.Files.GetEnumerator()) {
            $f = $entry.Value

            if ($f.gps) {
                $lat = $f.gps.lat
                $lon = $f.gps.lon

                if ($lat -lt -90 -or $lat -gt 90 -or $lon -lt -180 -or $lon -gt 180) {
                    $f.gps = $null
                }
            }
        }

        Write-Log "Nettoyage GPS terminé." "SUCCESS"
    }
    catch {
        Write-Log "Erreur Repair-GPS : $($_.Exception.Message)" "ERROR"
    }
} # Repair-GPS


# =====================================================================
# RAPPORT HTML (structure prête)
# =====================================================================

# Génère un rapport HTML simple à partir du plan
function Export-ReportHtml {
    param(
        [string]$OutputFile = ".\onedrive_report.html"  # Fichier HTML de sortie
    )

    try {
        Write-Log "Génération du rapport HTML..." "INFO"

        $html = @"
<html>
<head>
<title>Rapport OneDrive</title>
<style>
body { font-family: Arial; margin: 20px; }
h1 { color: #444; }
table { border-collapse: collapse; width: 100%; margin-top: 20px; }
th, td { border: 1px solid #ccc; padding: 6px; }
th { background: #eee; }
</style>
</head>
<body>
<h1>Rapport OneDrive</h1>
<p>Généré le $(Get-Date)</p>

<h2>Résumé</h2>
<ul>
<li>Total fichiers analysés : $($Global:State.FilesToProcess.Count)</li>
<li>Total actions planifiées : $($Global:State.PlannedActions.Count)</li>
</ul>

<h2>Actions planifiées</h2>
<table>
<tr><th>ID</th><th>Source</th><th>Destination</th></tr>
"@

        foreach ($a in $Global:State.PlannedActions) {
            $html += "<tr><td>$($a.Id)</td><td>$($a.SrcPath)/$($a.SrcName)</td><td>$($a.FullDst)</td></tr>"
        }

        $html += @"
</table>
</body>
</html>
"@

        $html | Set-Content $OutputFile
        Write-Log "Rapport HTML généré : $OutputFile" "SUCCESS"
    }
    catch {
        Write-Log "Erreur Export-ReportHtml : $($_.Exception.Message)" "ERROR"
    }
} # Export-ReportHtml

# =====================================================================
# MAIN
# =====================================================================

# Point d'entrée principal du script
function Start-OneDriveOrganizer {
    <#
    .SYNOPSIS
        Point d'entrée principal de l'organisateur OneDrive.
        Gère le cycle de vie : Nettoyage -> Planification -> Correction -> Exécution.
    #>
    
    # 1. NETTOYAGE DU LOG (Une seule fois au début strict)
    if (Test-Path $LogFile) { 
        try {
            Remove-Item $LogFile -Force -ErrorAction SilentlyContinue
            # On recrée un fichier vide pour que Write-Log puisse écrire immédiatement
            New-Item -Path $LogFile -ItemType File -Force | Out-Null
        } catch {
            Write-Host "Impossible de réinitialiser le log : $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }

    Write-Log "=== DÉMARRAGE DE LA SESSION : $(Get-Date -Format 'dd/MM/yyyy HH:mm:ss') ===" "INFO"

    try {
        # 2. CHARGEMENT ET RÉPARATION DES DONNÉES EN MÉMOIRE
        # Note : On n'appelle Import-Set-Cache qu'UNE SEULE FOIS.
        Import-Set-Cache
        
        # On répare le cache en mémoire (suppression entrées invalides, etc.)
        Repair-Cache       
        
        # On normalise les métadonnées (Chemins, Noms, GPS)
        Repair-Paths
        Repair-Names
        Repair-GPS

        # 3. GESTION DU PLAN (Reprise ou Nouveau)
        # On vérifie si un plan existe déjà pour ce fichier de cache précis (via Hash)
        $hash = Get-CacheHash
        $plan = if ($hash) { Get-ExistingPlan -CurrentHash $hash } else { $null }

        if ($null -eq $plan) {
            Write-Log "Aucun plan valide trouvé. Lancement de l'analyse complète..." "INFO"
            New-Plan
            
            # Après New-Plan, on sauvegarde le hash actuel pour la prochaine fois
            if ($hash) { 
                $hashFile = Join-Path (Split-Path $IndexFile -Parent) "cache_hash.txt"
                $hash | Set-Content $hashFile 
            }
        } 
        else {
            Write-Log "Reprise du plan existant détectée (Hash SHA256 identique)." "SUCCESS"
            $Global:State.PlannedActions = [System.Collections.Generic.List[PSCustomObject]]$plan
        }

        # 4. RÉSOLUTION DES CONFLITS ET VALIDATION
        # On vérifie s'il y a des doublons de noms dans les destinations cibles
        Repair-Collisions
        
        # Analyse finale du plan (doublons restants, chemins trop longs)
        Test-Plan

        # 5. VÉRIFICATION DU MODE D'EXÉCUTION
        if (-not $Execute) {
            Write-Log "----------------------------------------------------------------" "WARN"
            Write-Log "MODE APERÇU (DRY-RUN) : Aucune modification n'a été faite sur le Cloud." "WARN"
            Write-Log "Vérifiez le fichier 'plan.json' dans le dossier _cache." "INFO"
            Write-Log "Relancez le script avec le paramètre -Execute `$true pour appliquer." "INFO"
            Write-Log "----------------------------------------------------------------" "WARN"
            return
        }

        # 6. EXÉCUTION RÉELLE (GRAPH API)
        Write-Log "PASSAGE EN MODE EXÉCUTION RÉELLE..." "WARN"
        Connect-AzureGraph
        
        # Création proactive des dossiers de destination pour éviter les erreurs 404
        Write-Log "Vérification de l'arborescence des dossiers sur OneDrive..." "INFO"
        $uniqueDirs = $Global:State.PlannedActions.DstDir | Select-Object -Unique
        foreach ($dir in $uniqueDirs) { 
            Test-OneDrivePath $dir 
        }

        # Déplacement effectif des fichiers
        Invoke-Moves
        
        Write-Log "Processus d'organisation terminé avec succès." "SUCCESS"
    }
    catch {
        Write-Log "ERREUR FATALE dans Start-OneDriveOrganizer : $($_.Exception.Message)" "ERROR"
        Write-Log "Détails : $($_.ScriptStackTrace)" "DEBUG"
    }
}

Start-OneDriveOrganizer