# =====================================================================
# Organisateur OneDrive — Pipeline moderne fusionné
# - Analyse, classification, renommage intelligent, planification
# - Barre de progression intégrée
# - Logging harmonisé
# - GPS, tags, caméra, source, destination
# - Version optimisée et cohérente
# =====================================================================

param (
    [bool]$Execute = $false,
    [string]$IndexFile = ".\onedrive_cache.json",
    [string]$LogFile = ".\organisation_log.txt",
    [string]$ProcessedLog = ".\processed_ids.log",
    [string]$ExecutionReport = ".\azure_sync_report.csv",
    [string]$GpsCacheFile = ".\gps_cache.json",
    [bool]$VerboseMode = $true
)

# =====================================================================
# CONFIGURATION GLOBALE (PLACÉE AVANT LES MODULES)
# =====================================================================

$Config = [PSCustomObject]@{
    RenameMarker = "--odr--"
    MaxNameLen   = 100
    ClientId     = "176fc7bc-42c9-4a25-82b5-0ad584d3c061"
    ExtensionMap = $ExtensionMap
}

# =====================================================================
# MODULES EXTERNES
# =====================================================================

Import-Module "$PSScriptRoot\modules\OneDriveTools.psm1" -ArgumentList $Config.ClientId, $TokenFile, $LogFile -Force
Import-Module "$PSScriptRoot\modules\OneDriveOrganize.psm1" -Force
Import-Module "$PSScriptRoot\modules\GpsTools.psm1" -ArgumentList $GpsCacheFile -Force

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
# UTILITAIRES
# =====================================================================

function Get-ErrorDetails {
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
# AUTHENTIFICATION
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
# PRÉ-CRÉATION DES DOSSIERS
# =====================================================================

function Test-OneDrivePath {
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
# CHARGEMENT DU CACHE
# =====================================================================

function Import-Set-Cache {
    Write-Log "Nettoyage du vieux log $LogFile"
    if (Test-Path $LogFile) { Remove-Item $LogFile -Force }

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
# PIPELINE FUSIONNÉ : ANALYSE + BARRE DE PROGRESSION + PLAN
# =====================================================================

function New-Plan {
    Write-Log "Analyse des fichiers (pipeline fusionné)..."

    $FileIds = $Global:State.FilesToProcess.Keys
    $TotalFiles = $FileIds.Count
    $StartTime = Get-Date
    $count = 0

    foreach ($fileId in $FileIds) {

        $count++
        $fileMeta = $Global:State.Cache.Files[$fileId]
        $extension = [System.IO.Path]::GetExtension($fileMeta.n).ToLower()

        # Progression
        Write-Log "----------------------------------------------" "DEBUG"

        $elapsed = (Get-Date) - $StartTime
        $avgTime = $elapsed.TotalSeconds / [math]::Max($count,1)
        $remainingStr = "{0:hh\:mm\:ss}" -f [TimeSpan]::FromSeconds($avgTime * ($TotalFiles - $count))

        Write-Progress -Activity "Analyse OneDrive" `
            -Status "$count / $TotalFiles | Restant: $remainingStr" `
            -PercentComplete (($count / $TotalFiles) * 100)

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
        $fullDestination  = $dest.FullDestination

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
}

# =====================================================================
# DÉPLACEMENT
# =====================================================================

function Invoke-Moves {
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
# RAPPORT HTML (structure prête)
# =====================================================================

function Export-ReportHtml {
    param([string]$OutputFile = ".\onedrive_report.html")

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

# =====================================================================
# MAIN
# =====================================================================

function Start-OneDriveOrganizer {
   # Clear-Host
    Write-Log "Démarrage de l'organisateur..."

    Import-Set-Cache
    New-Plan

    if ($Global:State.PlannedActions.Count -eq 0) {
        Write-Log "Aucun fichier à traiter." "WARN"
        return
    }

    # Mode preview forcé pour stabilisation
    exit

    if (-not $Execute) {
        Write-Log "MODE APERÇU — utilisez -Execute `$true pour appliquer." "WARN"
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