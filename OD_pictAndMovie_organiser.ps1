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
    [string]$LogFile = ".\organisation_log.txt",    # log des infos envoyées a la console
    [string]$ProcessedLog = ".\processed_ids.log",  # liste des id traités (pour accelerer les traitement subsequents)
    [string]$ExecutionReport = ".\azure_sync_report.csv",
    [string]$GpsCacheFile = ".\gps_cache.json",     # cache des noms de localisations selon leur coordonnées GPS
    [bool]$VerboseMode = $true                      # equivalent de debug
)

# =====================================================================
# MODULE EXTERNE
# =====================================================================

# --- CHARGER MODULE APRÈS CONFIG ---
Import-Module ".\OneDriveTools\OneDriveTools.psm1" -ArgumentList $ClientId, $TokenFile, $global:LogFile -Force
Import-Module ".\OneDriveTools\OneDriveOrganize.psm1" -Force

# =====================================================================
# 1. CONFIGURATION GLOBALE
# =====================================================================

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
    FilesToProcess = @{}
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
        "ERROR" { "Red" }
        "WARN" { "Yellow" }
        "SUCCESS" { "Green" }
        "DEBUG" { "DarkGray" }
        default { "Gray" }
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
    }
    catch {}

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
# 5. AUTHENTIFICATION
# =====================================================================

function Connect-AzureGraph {
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

# =====================================================================
# 7. CHARGEMENT DU CACHE
# =====================================================================

function Import-Set-Cache {
    [CmdletBinding()]
    param()

    Write-Log "Nettoyage du vieux log d'exécution $LogFile si present "
    if (Test-Path $LogFile) {
        Remove-Item $LogFile -Force
    }

    Write-Log "Chargement du cache OneDrive $IndexFile ... "
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
    Write-Log "Chargement de la liste des ids/fichiers déjà traités ($ProcessedLog) ... "
    $Global:State.ProcessedIds = @{}
    $Global:State.FilesToProcess = @{}

    if (Test-Path $ProcessedLog) {
        Get-Content $ProcessedLog | ForEach-Object {
            $id = $_.Trim()
            if ($id) {
                $Global:State.ProcessedIds[$id] = $true
            }
        }
        Write-Log "Fichiers déjà traités chargés : $($Global:State.ProcessedIds.Count)"
    }
    else {
        Write-Log "Aucun fichier traité précédemment (fichier $ProcessedLog absent)."
    }

    Write-Log "Découverte des fichiers déjà traités ayant le marqueur '$($Config.RenameMarker)' ..."
    $index = 0
    $total = $Global:State.Cache.Files.Count
    foreach ($id in $Global:State.Cache.Files.Keys) {

        $index++
        Write-Progress -Activity "Analyse des fichiers" `
            -Status "$index / $total" `
            -PercentComplete (($index / $total) * 100)

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
} # Import-Set-Cache

# =====================================================================
# 8. PLANIFICATION
# =====================================================================

function New-Plan {
    [CmdletBinding()]
    param()

    Write-Log "Analyse des fichiers..."
    Write-Log "Début de New-Plan" "DEBUG"

    foreach ($fileId in $Global:State.FilesToProcess.Keys) {

        $fileMeta = $Global:State.Cache.Files[$fileId]
        $extension = [System.IO.Path]::GetExtension($fileMeta.n).ToLower()

        Write-Log "Analyse du fichier" "DEBUG"
        Write-Log "ID             : $fileId" "DEBUG"
        Write-Log "Nom original   : $($fileMeta.n)" "DEBUG"
        Write-Log "Chemin source  : $($fileMeta.p)" "DEBUG"
        Write-Log "Extension      : $extension" "DEBUG"
        Write-Log "Date fichier   : $($fileMeta.d)" "DEBUG"

        # 1. Classification intelligente
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

        $newName = New-SmartFileName `
            -DateRef      $fileDate `
            -OriginalName $originalNameNoExt `
            -Extension    $extension `
            -GpsLocation  $gpsLocation `
            -PathTags     $pathTags `
            -Camera       $camera `
            -SourceHint   $sourceHint

        Write-Log "Nouveau nom généré : $newName" "DEBUG"

        # 3. Destination
        $dest = Get-DestinationPath `
            -Category     $category `
            -FileMeta     $fileMeta `
            -Extension    $extension `
            -ExtensionMap $Config.ExtensionMap `
            -NewName      $newName `
            -FileDate     $fileDate

        Write-Log "Chemin destination = ($($dest.CleanDestination))" "DEBUG"

        $cleanDestination = $dest.CleanDestination
        $fullDestination  = $dest.FullDestination

        # 4. Vérification si déjà à la bonne place
        $srcDirClean = $fileMeta.p -replace "^/drive/root:", ""
        $currentPath = "$($srcDirClean.Trim('/'))/$($fileMeta.n)"

        if ($currentPath -eq $fullDestination.Trim('/')) {
            Write-Log "Déjà à la bonne place : $($fileMeta.n)" "DEBUG"
            continue
        }

        # 5. Ajout au plan
        $Global:State.PlannedActions.Add([PSCustomObject]@{
            Id      = $fileId
            SrcPath = $fileMeta.p
            SrcName = $fileMeta.n
            DstDir  = "/$($cleanDestination.Trim('/'))"
            DstName = $newName
            FullDst = $fullDestination
        })

        Write-Log "----------------------------------------------" "DEBUG"
    }

    Write-Log "Plan généré : $($Global:State.PlannedActions.Count) fichiers." "SUCCESS"
    Write-Log "Fin de New-Plan" "DEBUG"
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
                if ($fileMeta.dur) { $parts.Add($fileMeta.dur) }; if ($fileMeta.res) { $parts.Add($fileMeta.res) }
                $targetDir = "/Vidéos/Pellicule/$($dateRef.Year)/$($dateRef.ToString('MM'))"
            }
            else {
                if ($name -and $tags -notlike "*$name*" -and $name -notmatch "^\d+$") { $parts.Add($name) }
                if ($fileMeta.cam) { $parts.Add($fileMeta.cam) }
                $targetDir = "/Images/Pellicule/$($dateRef.Year)/$($dateRef.ToString('MM'))"
            }
            $newName = ($parts -join "_") + $ext
        }
        # NOMENCLATURE AUDIO
        elseif ($ext -match ".mp3|.m4a|.flac") {
            $artiste = if ($fileMeta.art) { $fileMeta.art }else { "Inconnu" }
            $album = if ($fileMeta.alb) { $fileMeta.alb }else { "Inconnu" }
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



# =====================================================================
# 10. MAIN
# =====================================================================

function Start-OneDriveOrganizer {
    [CmdletBinding()]
    param()

    Clear-Host
    Write-Log "Démarrage de l'organisateur..."

    Import-Set-Cache

    #traitement

    New-Plan

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