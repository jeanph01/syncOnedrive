# =====================================================================
# Evaluate-OrganizerSuccess.ps1
# Generates a detailed CSV report of all files in the OneDrive cache,
# showing their original paths, resolved actions, proposed new names/paths,
# and organization status. This helps evaluate the success and check
# for miscategorized files.
# =====================================================================

param (
    [string]$ConfigFile = ".\config.ini",
    [string]$OutputFile = ".\_cache\evaluation_report.csv"
)

# Force Write-Progress display
$ProgressPreference = 'Continue'
Clear-Host

Write-Host "=== INITIALIZING EVALUATION SCRIPT ===" -ForegroundColor Cyan

# Load configurations
$ConfigFile = Resolve-Path $ConfigFile
if (-not (Test-Path $ConfigFile)) {
    Write-Error "Config file not found: $ConfigFile"
    return
}

$PSScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition
Import-Module "$PSScriptRoot\modules\AppConfig.psm1" -Force
$app = Get-AppConfiguration -ConfigFile $ConfigFile

$global:IndexFile = $app.IndexFile
$global:TokenFile = $app.TokenFile
$global:LogFile = Join-Path $app.CacheDir "evaluation.log"
$global:ProcessedLog = $app.ProcessedLog
$GpsCacheFile = $app.GpsCacheFile
$Global:Rules = $app.Rules

$Config = [PSCustomObject]@{
    RenameMarker = $app.RenameMarker
    MaxNameLen   = $app.MaxNameLen
    ClientId     = $app.ClientId
    ExtensionMap = $app.ExtensionMap
}
$global:Config = $Config

# Import core tools
Import-Module "$PSScriptRoot\modules\OneDriveTools.psm1" -ArgumentList $Config.ClientId, $global:TokenFile, $global:LogFile -Force
Import-Module "$PSScriptRoot\modules\OneDriveOrganize.psm1" -ArgumentList $Config.ClientId, $global:TokenFile, $global:LogFile -Force -DisableNameChecking
Import-Module "$PSScriptRoot\modules\OneDriveCacheUtils.psm1" -Force -DisableNameChecking
Import-Module "$PSScriptRoot\modules\GpsTools.psm1" -ArgumentList $GpsCacheFile -Force

# Global state needed by modules
$Global:State = @{
    Headers         = @{}
    Cache           = $null
    ProcessedIds    = @{}
    PlannedActions  = New-Object System.Collections.Generic.List[PSCustomObject]
    FilesToProcess  = @{}
    VerifiedFolders = @{}
}

# 1. Load the cache
Write-Host "Loading OneDrive cache ($global:IndexFile)..." -ForegroundColor Cyan
if (-not (Test-Path $global:IndexFile)) {
    Write-Error "OneDrive cache file not found at $global:IndexFile. Please run OneDrive_Sync.ps1 -Mode Online first."
    return
}

$Global:State.Cache = ConvertFrom-JsonOptimized -JsonString (Get-Content $global:IndexFile -Raw) -AsHashtable

if (-not $Global:State.Cache.Files) {
    Write-Error "Cache contains no files."
    return
}

# 2. Load processed log
Write-Host "Loading processed log..." -ForegroundColor Cyan
if (Test-Path $global:ProcessedLog) {
    Get-Content $global:ProcessedLog -Encoding utf8 | ForEach-Object {
        $id = $_.Trim(' "''{},')
        if ($id -and $id -ne "true" -and $id -ne "false") {
            $Global:State.ProcessedIds[$id] = $true
        }
    }
}

# Offline-safe GPS resolver to avoid sending Nominatim API queries over the network
function Get-LocationNameEvaluation {
    param([string]$gps)
    if (-not $gps -or $gps -eq "," -or $gps -match "^0,0$") { return $null }

    try {
        Initialize-GpsCache

        $lat, $lon = $gps -split ","
        $lat = [double]$lat
        $lon = [double]$lon

        # Grid key for cache (~100m)
        $gridKey = Get-GpsGridKey -Lat $lat -Lon $lon

        # 1. Exact cache match
        if ($script:GpsCache.ContainsKey($gridKey)) {
            return $script:GpsCache[$gridKey]
        }

        # 2. Nearby cache match (Clustering)
        $near = Find-NearbyGpsKey -Lat $lat -Lon $lon -Cache $script:GpsCache
        if ($near) {
            return $script:GpsCache[$near]
        }
    }
    catch {
        # Safe fallback
    }

    return $null
}

# 3. Analyze all files
$files = $Global:State.Cache.Files
$total = $files.Count
Write-Host "Analyzing $total files..." -ForegroundColor Cyan

$report = New-Object System.Collections.Generic.List[PSCustomObject]
$count = 0

foreach ($id in $files.Keys) {
    $count++
    if ($count % 500 -eq 0 -or $count -eq $total) {
        Write-Progress -Activity "Evaluating files" -Status "$count / $total" -PercentComplete (($count / $total) * 100)
    }

    $fileMeta = $files[$id]
    $extension = [System.IO.Path]::GetExtension($fileMeta.n).ToLower()
    
    # Determine basic attributes
    $isSupported = $Config.ExtensionMap.ContainsKey($extension)
    
    $isProcessed = $false
    if ($Global:State.ProcessedIds.ContainsKey($id) -or $fileMeta.n -like "*$($Config.RenameMarker)*") {
        $isProcessed = $true
    }

    # Resolve GPS Location offline
    $gpsLocation = Get-LocationNameEvaluation -gps $fileMeta.GPS

    # Path Tags
    $pathTags = Get-PathTags $fileMeta.p

    # Resolved routing action
    $action = Get-SmartCategory -Path $fileMeta.p -Extension $extension -IsAnimated ([bool]$fileMeta.ani)

    # Status classification
    $status = "Pending Organization"
    if ($isProcessed) {
        $status = "Already Organized"
    } elseif (-not $isSupported) {
        $status = "Unsupported Extension"
    } elseif ($action -eq "no_action") {
        $status = "No Action Folder"
    }

    # Calculate proposed names and destinations if supported and not processed
    $proposedName = ""
    $proposedDest = ""
    $fullProposedDest = ""

    if ($isSupported -and $action -ne "no_action") {
        try {
            $proposedName = Resolve-FinalName `
                -FileMeta    $fileMeta `
                -Extension   $extension `
                -GPSLocation $gpsLocation `
                -PathTags    $pathTags `
                -Camera      $fileMeta.cam

            $fileDate = if ($fileMeta.d) { [DateTime]$fileMeta.d } else { Get-Date }
            
            $destInfo = Get-DestinationPath `
                -FileMeta   $fileMeta `
                -Extension  $extension `
                -NewName    $proposedName `
                -FileDate   $fileDate

            if ($destInfo) {
                $proposedDest = "/$($destInfo.CleanDestination.Trim('/'))"
                $fullProposedDest = $destInfo.FullDestination
            }
        } catch {
            $status = "Error Planning"
        }
    }

    $report.Add([PSCustomObject]@{
        Id                    = $id
        Name                  = $fileMeta.n
        ParentPath            = $fileMeta.p
        Extension             = $extension
        Size                  = $fileMeta.s
        Date                  = $fileMeta.d
        Camera                = $fileMeta.cam
        GPS                   = if ($fileMeta.GPS) { "$($fileMeta.GPS.lat),$($fileMeta.GPS.lon)" } else { "" }
        GPSLocation           = $gpsLocation
        RoutingAction         = $action
        IsSupportedExt        = if ($isSupported) { "Yes" } else { "No" }
        IsAlreadyProcessed    = if ($isProcessed) { "Yes" } else { "No" }
        Status                = $status
        ProposedName          = $proposedName
        ProposedDestination   = $proposedDest
        FullProposedDest      = $fullProposedDest
    })
}

Write-Progress -Activity "Evaluating files" -Completed

# Save report to CSV
Write-Host "Saving report to $OutputFile..." -ForegroundColor Cyan
$report | Export-Csv -Path $OutputFile -NoTypeInformation -Encoding utf8 -Delimiter ";"

# Print summary
Write-Host "`n=== EVALUATION REPORT SUMMARY ===" -ForegroundColor Green
$summary = $report | Group-Object Status | Select-Object Name, Count
$summary | Format-Table -AutoSize

# Filter by watched folders (those with supported extensions and active routing action)
$watchedReport = $report | Where-Object { $_.IsSupportedExt -eq "Yes" -and $_.RoutingAction -ne "no_action" }
Write-Host "Total watched files (supported extensions & active routing): $($watchedReport.Count)" -ForegroundColor Green
$watchedSummary = $watchedReport | Group-Object RoutingAction | Select-Object Name, Count
$watchedSummary | Format-Table -AutoSize

Write-Host "Evaluation report saved to $OutputFile" -ForegroundColor Green
Write-Host "You can open this CSV file in Microsoft Excel or another CSV viewer to examine original paths, resolved categories, and new paths." -ForegroundColor Yellow
