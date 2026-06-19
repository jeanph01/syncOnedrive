# =====================================================================
# Evaluate-OrganizerSuccess.ps1 (Optimized Version)
# Generates a detailed CSV report of files in the watched folders on OneDrive.
# High performance: filters out non-media/unwatched files early and caches folder actions.
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
Import-Module "$PSScriptRoot\modules\OneDriveTools.psm1" -ArgumentList $Config.ClientId, $TokenFile, $LogFile -Force
Import-Module "$PSScriptRoot\modules\OneDriveOrganize.psm1" -ArgumentList $Config.ClientId, $TokenFile, $LogFile -Force -DisableNameChecking
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

# Load Adult Keywords
$adultKeywords = @()
$adultKeywordsFile = Join-Path $PSScriptRoot "adult_keywords.json"
if (Test-Path $adultKeywordsFile) {
    try {
        $adultData = Get-Content $adultKeywordsFile -Raw | ConvertFrom-Json
        if ($adultData.adultKeywords) {
            $adultKeywords = $adultData.adultKeywords
            Write-Host "Loaded $($adultKeywords.Count) adult keywords for filtering." -ForegroundColor Yellow
        }
    } catch {
        Write-Warning "Failed to load adult_keywords.json"
    }
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

# 3. Analyze files in watched folders
$files = $Global:State.Cache.Files
$total = $files.Count
Write-Host "Pre-filtering and analyzing $total files in cache..." -ForegroundColor Cyan

$report = New-Object System.Collections.Generic.List[PSCustomObject]
$adultReport = New-Object System.Collections.Generic.List[PSCustomObject]
$count = 0
$matchedCount = 0
$StartTime = Get-Date

# Cache for folder actions: parentPath_isAnimated -> Action
$folderActionCache = @{}

foreach ($id in $files.Keys) {
    $count++
    if ($count % 1000 -eq 0 -or $count -eq $total) {
        $elapsed = (Get-Date) - $StartTime
        $elapsedSec = $elapsed.TotalSeconds
        if ($elapsedSec -lt 0.1) { $elapsedSec = 0.1 }
        $fps = [math]::Round($count / $elapsedSec, 1)
        $remainingSeconds = ($total - $count) / $fps
        $remainingStr = "{0:hh\:mm\:ss}" -f [TimeSpan]::FromSeconds($remainingSeconds)

        Write-Progress -Activity "Evaluating files" `
            -Status "$count / $total ($matchedCount matched) | Throughput: $fps files/sec | Est: $remainingStr" `
            -PercentComplete (($count / $total) * 100)
    }

    $fileMeta = $files[$id]
    
    # Optimization 1: Skip if name or parent path is empty
    if (-not $fileMeta.n -or -not $fileMeta.p) {
        continue
    }

    # Optimization 2: Fast extension filter (Skip unsupported files immediately)
    $extension = [System.IO.Path]::GetExtension($fileMeta.n).ToLower()
    if (-not $Config.ExtensionMap.ContainsKey($extension)) {
        continue
    }

    $isAnimated = [bool]$fileMeta.ani

    # Optimization 3: Cache folder actions to avoid running rules for every single file
    $cacheKey = "$($fileMeta.p)_$isAnimated"
    $action = $folderActionCache[$cacheKey]
    if ($null -eq $action) {
        $action = Get-SmartCategory -Path $fileMeta.p -Extension $extension -IsAnimated $isAnimated
        $folderActionCache[$cacheKey] = $action
    }

    # Optimization 4: Skip if folder action is no_action (unwatched folders)
    if ($action -eq "no_action") {
        continue
    }

    $matchedCount++

    # Adult Content Filter (Pre-analysis)
    $isAdult = $false
    $matchedKeyword = ""
    if ($adultKeywords) {
        $textToCheck = "$($fileMeta.p)/$($fileMeta.n)".ToLower()
        foreach ($kw in $adultKeywords) {
            if ($textToCheck -match "\b$([regex]::Escape($kw))\b" -or $textToCheck -match "$([regex]::Escape($kw))") {
                $isAdult = $true
                $matchedKeyword = $kw
                break
            }
        }
    }

    if ($isAdult) {
        $action = "no_action"
        $status = "Adult Content (No Action)"
    } else {
        # Determine if already processed
        $isProcessed = $false
        if ($Global:State.ProcessedIds.ContainsKey($id) -or $fileMeta.n -like "*$($Config.RenameMarker)*") {
            $isProcessed = $true
        }
        $status = if ($isProcessed) { "Already Organized" } else { "Pending Organization" }
    }

    # Resolve GPS Location offline
    $gpsLocation = Get-LocationNameEvaluation -gps $fileMeta.GPS

    # Path Tags
    $pathTags = Get-PathTags $fileMeta.p

    # Calculate proposed names and destinations if not processed and not adult
    $proposedName = ""
    $proposedDest = ""
    $fullProposedDest = ""

    if (-not $isProcessed -and -not $isAdult) {
        try {
            # Compute dynamic destination folder stop words first
            $fileDate = if ($fileMeta.d) { [DateTime]$fileMeta.d } else { Get-Date }
            
            $tempDest = Get-DestinationPath `
                -FileMeta  $fileMeta `
                -Extension $extension `
                -NewName   "" `
                -FileDate  $fileDate
                
            $dynamicStopWords = @()
            if ($tempDest -and $tempDest.CleanDestination) {
                $dynamicStopWords = $tempDest.CleanDestination -split "/"
            }

            $proposedName = Resolve-FinalName `
                -FileMeta    $fileMeta `
                -Extension   $extension `
                -GPSLocation $gpsLocation `
                -PathTags    $pathTags `
                -Camera      $fileMeta.cam `
                -DynamicStopWords $dynamicStopWords
            
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

    $reportItem = [PSCustomObject]@{
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
        IsAlreadyProcessed    = if ($isProcessed) { "Yes" } else { "No" }
        Status                = $status
        ProposedName          = $proposedName
        ProposedDestination   = $proposedDest
        FullProposedDest      = $fullProposedDest
    }
    
    $report.Add($reportItem)
    
    if ($isAdult) {
        $adultItem = $reportItem.PSObject.Copy()
        $adultItem | Add-Member -MemberType NoteProperty -Name "MatchedKeyword" -Value $matchedKeyword
        $adultReport.Add($adultItem)
    }
}

Write-Progress -Activity "Evaluating files" -Completed
Write-Host "Filtering complete. Found $matchedCount media files in watched folders." -ForegroundColor Green

# Save report to CSV
Write-Host "Saving report to $OutputFile..." -ForegroundColor Cyan
$report | Export-Csv -Path $OutputFile -NoTypeInformation -Encoding utf8 -Delimiter ";"

# Print summary
Write-Host "`n=== EVALUATION REPORT SUMMARY ===" -ForegroundColor Green
$summary = $report | Group-Object Status | Select-Object Name, Count
$summary | Format-Table -AutoSize

# Filter by watched action
$watchedSummary = $report | Group-Object RoutingAction | Select-Object Name, Count
$watchedSummary | Format-Table -AutoSize

Write-Host "Evaluation report saved to $OutputFile" -ForegroundColor Green

if ($adultReport.Count -gt 0) {
    $adultOutputFile = Join-Path (Split-Path $OutputFile) "adult_content_report.csv"
    $adultReport | Export-Csv -Path $adultOutputFile -NoTypeInformation -Encoding utf8 -Delimiter ";"
    Write-Host "Adult content report ($($adultReport.Count) files) saved to $adultOutputFile" -ForegroundColor Red
}

Write-Host "You can open this CSV file in Microsoft Excel or another CSV viewer to examine original paths, resolved categories, and new paths." -ForegroundColor Yellow
