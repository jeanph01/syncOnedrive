# ============================================================
# VERSION: 15.0 (Runspace Edition + optimized delta scan)
# ============================================================

param (
    [ValidateSet("Online", "Offline")]
    [string]$Mode = "Online",                     # OneDrive scan mode
    [switch]$ForceNewScan,   # Force only the OneDrive scan (cloud index)
    [switch]$ResetCache,     # Total reset (cloud + local hashes + logs)
    [string]$ConfigFile = ".\config.ini"         # Application configuration
)

$ProgressPreference = 'SilentlyContinue'
Clear-Host

Import-Module "$PSScriptRoot\modules\AppConfig.psm1" -Force
$app = Get-AppConfiguration -ConfigFile $ConfigFile
$Global:Rules = $app.Rules

$LocalFolder = $app.LocalFolder
$TokenFile = $app.TokenFile
$ClientId = $app.ClientId
#$VerboseMode = $app.VerboseMode

# --- LOG FILE ---
$global:LogFile = $app.SyncLogFile

# ---------------- HEADER & CONFIG ----------------
function Initialize-Configuration {

    # todo move extensions to an external configuration file
    $script:TimeStart = Get-Date

    $cache = $app.CacheDir
    if (!(Test-Path $cache)) { New-Item -ItemType Directory -Path $cache | Out-Null }
    $global:IndexFile          = $app.IndexFile
    $global:ReportFile         = $app.SyncReportFile
    $global:LocalHashCacheFile = $app.LocalHashCacheFile
    $global:LogFile            = $app.SyncLogFile
    $global:DupFolder = Join-Path $LocalFolder "_Duplicates"

    # Allowed extensions
    $global:AllowedExt = if ($app.AllowedExt -and $app.AllowedExt.Count -gt 0) {
        $app.AllowedExt
    }
    else {
        @()
    }

    $global:AllowedExtSet = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($ext in $global:AllowedExt) { $null = $global:AllowedExtSet.Add($ext) }

    Write-Log "Configuration loaded"
    Write-Log "Mode: $Mode | ForceNewScan: $ForceNewScan | Folder: $LocalFolder"

    if (Test-Path $global:LogFile) {
        Remove-Item $global:LogFile -Force
    }
} # Initialize-Configuration
# =====================================================================
# EXTERNAL MODULES
# =====================================================================
Import-Module ".\modules\OneDriveTools.psm1" -ArgumentList $ClientId, $TokenFile, $global:LogFile -Force
Import-Module ".\modules\OneDriveOrganize.psm1" 

# =====================================================================
# 1. LOAD / SCAN
# =====================================================================

function Invoke-GraphWithRetry {
    param(
        [Parameter(Mandatory)] [string]$Uri,      # URL Graph
        [Parameter(Mandatory)] $Headers,          # Graph headers
        [int]$MaxRetry = 5                        # Maximum number of attempts
    )

    $retry = 0

    while ($retry -lt $MaxRetry) {

        try {
            # Tentative principale
            return Invoke-RestMethod -Headers $Headers -Uri $Uri -Method GET -ErrorAction Stop
        }
        catch {
            $retry++

            Write-Log "Graph ERROR (tentative $retry/$MaxRetry) : $($_.Exception.Message)" "WARN"

            Start-Sleep -Seconds ([math]::Min(10, [math]::Pow(2, $retry)))
        }
    }

    # If we reach this point -> fatal failure
    Write-Log "FATAL ERROR: Failed to retrieve the Graph page after $MaxRetry attempts." "ERROR"
    return $null
} # Invoke-GraphWithRetry

function Load-Scan {
    
    Write-Log "[1/4] Loading / scanning OneDrive (V15.1)"

    try {
    $script:Cache = @{ Files = @{} }

    # Reset cache if requested
    if ($ForceNewScan -and (Test-Path $global:IndexFile)) {
        Write-Log "Removing old cache"
        Remove-Item $global:IndexFile -Force
    }

    # Offline mode
    if ($Mode -ne "Online") {
        Write-Log "Offline mode -> loading existing cache"
        if (Test-Path $global:IndexFile) {
            $script:Cache = Get-Content $global:IndexFile -Raw | ConvertFrom-Json -AsHashtable
            if (-not $script:Cache.Files) { $script:Cache.Files = @{} }
            Write-Log "Cache loaded ($($script:Cache.Files.Count) files)"
        }
        return
    }

    # Auth via module
    $Auth = Get-GraphToken
    $Token = $Auth.access_token
    $Headers = @{ Authorization = "Bearer $Token" }

    # Load existing cache if present
    if ((-not $ForceNewScan) -and (Test-Path $global:IndexFile)) {
        try {
            $script:Cache = Get-Content $global:IndexFile -Raw | ConvertFrom-Json -AsHashtable
            if (-not $script:Cache.Files) { $script:Cache.Files = @{} }
            Write-Log "Existing cache loaded ($($script:Cache.Files.Count) files)"
        }
        catch {
            $script:Cache = @{ Files = @{} }
            Write-Log "Existing cache unreadable, recreating"
        }
    }

    # Requested fields
    $select = "name,id,size,file,hashes,fileSystemInfo,parentReference,photo,location,video,audio,image"
    $baseUrl = "https://graph.microsoft.com/v1.0/me/drive/root/delta?`$select=$select"

    # Full or incremental delta
    if ($ForceNewScan -or -not $script:Cache.DeltaToken) {
        $deltaUrl = $baseUrl
        Write-Log "Full delta scan (new base)"
    }
    else {
            $deltaUrl = $script:Cache.DeltaToken
        Write-Log "Incremental delta scan from last deltaToken"
    }

    # Delta loop
    while ($deltaUrl) {

        $res = Invoke-GraphWithRetry -Uri $deltaUrl -Headers $Headers
        if (-not $res) {
            Write-Log "Aborting delta scan (unrecoverable page)." "ERROR"
            break
        }

        $items = $res.value
        $count = if ($items) { $items.Count } else { 0 }

        foreach ($item in $items) {

            $entry = Read-AzureFileInfo $item
            if ($null -eq $entry) {
                continue
            }
            $script:Cache.Files[$item.id] = $entry
        }

        Write-Log "Graph: $count items → total $($script:Cache.Files.Count)"

        # Pagination delta
        if ($res.'@odata.nextLink') {
            $deltaUrl = $res.'@odata.nextLink'
        }
        elseif ($res.'@odata.deltaLink') {
            $script:Cache.DeltaToken = $res.'@odata.deltaLink'
            Write-Log "Final deltaLink received -> end of scan"
            break
        }
        else {
            Write-Log "End of scan"
            break
        }
    }

    # Final save
    $script:Cache | ConvertTo-Json -Depth 10 | Out-File $global:IndexFile -Encoding utf8 -NoNewline
    Write-Log "OneDrive cache saved"
}
    catch {
        Write-Log "Error Load-Scan : $($_.Exception.Message)" "ERROR"
    }
} # Load-Scan

# =====================================================================
# 2. CLOUD DUPLICATES REPORT
# =====================================================================
function Find-CloudDuplicates {
    try {
    Write-Log "[2/4] Analyzing OneDrive duplicates"

    $script:CloudDupCount = 0
    $HashGroups = @{}

    foreach ($item in $script:Cache.Files.Values) {

        if ($null -eq $item) { continue }
        if (-not $item.h)    { continue }

        if (-not $HashGroups.ContainsKey($item.h)) {
            $HashGroups[$item.h] = New-Object System.Collections.Generic.List[Object]
        }

        $HashGroups[$item.h].Add($item)
    }

    foreach ($h in $HashGroups.Keys) {
        if ($HashGroups[$h].Count -gt 1) { $script:CloudDupCount++ }
    }

    Write-Log "Cloud duplicate groups: $($script:CloudDupCount)"
}
    catch {
        Write-Log "Error Find-CloudDuplicates : $($_.Exception.Message)" "ERROR"
    }
} # Find-CloudDuplicates

# =====================================================================
# 3. LOCAL CLEANUP
# =====================================================================
function Analyze-LocalFiles {
    try {
    Write-Log "[3/4] Local analysis"

    # Duplicate folder
    if (!(Test-Path $global:DupFolder)) {
        New-Item -ItemType Directory -Path $global:DupFolder -Force | Out-Null
    }

    # Build CloudSizes dictionary: size -> list of hashes
    $CloudSizes = @{}

    foreach ($f in $script:Cache.Files.Values) {

        # --- SAFETY FILTERS ---
        if ($null -eq $f) { continue }
        if ($null -eq $f.s) { continue }   # missing size
        if ($null -eq $f.h) { continue }   # missing hash

        # --- ADD TO CloudSizes ---
        if (-not $CloudSizes.ContainsKey($f.s)) {
            $CloudSizes[$f.s] = New-Object System.Collections.Generic.List[string]
        }

        $CloudSizes[$f.s].Add($f.h)
    }

    # Load local hash cache
    $script:LocalHashCache = @{}
    if (Test-Path $global:LocalHashCacheFile) {
        try {
            $script:LocalHashCache = Get-Content $global:LocalHashCacheFile -Raw | ConvertFrom-Json -AsHashtable
        }
        catch { $script:LocalHashCache = @{} }
    }

    # Local files
    $LocalFiles = Get-ChildItem -Path $LocalFolder -File -Recurse |
                  Where-Object { $_.FullName -notlike "*_Duplicates*" }

    $script:cDel = 0
    $script:cMove = 0
    $script:cSkipped = 0
    $script:total = $LocalFiles.Count

    $i = 0

    foreach ($file in $LocalFiles) {
        $i++

        if ($i % 300 -eq 0) {
            Write-Log "Progression: $i / $($script:total)"
        }

        # Disallowed extension -> remove
        if (-not $global:AllowedExtSet.Contains($file.Extension.ToLower())) {
            Remove-Item -LiteralPath $file.FullName -Force
            $script:cDel++
            continue
        }

        # Size not present in cloud -> skip
        if (-not $CloudSizes.ContainsKey($file.Length)) {
            $script:cSkipped++
            continue
        }

        $possibleHashes = $CloudSizes[$file.Length]

        # Simple case: one possible hash
        if ($possibleHashes.Count -eq 1) {
            $expected = $possibleHashes[0]

            if ($script:LocalHashCache.ContainsKey($file.FullName)) {
                if ($script:LocalHashCache[$file.FullName] -eq $expected) {

                    # Move to _Duplicates
                    $dest = Join-Path $global:DupFolder $file.Name
                    $idx = 1
                    while (Test-Path -LiteralPath $dest) {
                        $dest = Join-Path $global:DupFolder "$($file.BaseName)_$idx$($file.Extension)"
                        $idx++
                    }

                    [System.IO.File]::Move($file.FullName, $dest)
                    $script:cMove++
                    continue
                }
            }
        }

        # Calculate local hash if needed
        $sha1 = $null
        if ($script:LocalHashCache.ContainsKey($file.FullName)) {
            $sha1 = $script:LocalHashCache[$file.FullName]
        }
        else {
            $sha1 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA1).Hash.ToLower()
            $script:LocalHashCache[$file.FullName] = $sha1
        }

        # Si le hash correspond → doublon
        if ($possibleHashes -contains $sha1) {

            $dest = Join-Path $global:DupFolder $file.Name
            $idx = 1
            while (Test-Path -LiteralPath $dest) {
                $dest = Join-Path $global:DupFolder "$($file.BaseName)_$idx$($file.Extension)"
                $idx++
            }

            [System.IO.File]::Move($file.FullName, $dest)
            $script:cMove++
        }
    }

    # Save local hash cache
    $script:LocalHashCache | ConvertTo-Json -Depth 5 |
        Out-File $global:LocalHashCacheFile -Encoding utf8 -NoNewline

    Write-Log "Local cleanup completed"
}
    catch {
        Write-Log "Error Analyze-LocalFiles : $($_.Exception.Message)" "ERROR"
    }
} # Analyze-LocalFiles

# =====================================================================
# 4. EMPTY FOLDERS
# =====================================================================
function Remove-EmptyFolders {
    try {
    Write-Log "[4/4] Cleaning empty folders"

    Get-ChildItem -Path $LocalFolder -Directory -Recurse |
    Sort-Object { $_.FullName.Length } -Descending |
    ForEach-Object {
        if ((Get-ChildItem -LiteralPath $_.FullName -ErrorAction SilentlyContinue).Count -eq 0) {
            if ($_.FullName -notlike "*_Duplicates*") {
                Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
            }
        }
    }
}
    catch {
        Write-Log "Error Remove-EmptyFolders : $($_.Exception.Message)" "ERROR"
    }
} # Remove-EmptyFolders

# =====================================================================
# SUMMARY
# =====================================================================
function Write-Summary {
    try {
    $Duration = (Get-Date) - $script:TimeStart

    Write-Log "=== FINAL SUMMARY ==="
    Write-Log "Elapsed time: $($Duration.Minutes)m $($Duration.Seconds)s"
    Write-Log "Local files: $($script:total)"
    Write-Log "Ignored (size mismatch): $($script:cSkipped)"
    Write-Log "Cloud duplicate groups: $($script:CloudDupCount)"
    Write-Log "Local duplicates moved: $($script:cMove)"
    Write-Log "Files deleted (disallowed extensions): $($script:cDel)"
}
    catch {
        Write-Log "Error Write-Summary : $($_.Exception.Message)" "ERROR"
    }
} # Write-Summary

# =====================================================================
# MAIN
# =====================================================================
function main {
    try {
        Write-Log "=== STARTING SCRIPT V15.1 ==="

        Initialize-Configuration

        if ($ResetCache) {
            Write-Log "Resetting internal cache..." "WARN"
            $files = @(
                $global:IndexFile,
                $global:ReportFile,
                $global:LocalHashCacheFile,
                $global:LogFile
            )
            foreach ($f in $files) {
                if (Test-Path $f) { Remove-Item $f -Force }
            }
            Write-Log "Reset completed." "SUCCESS"
        }

        Load-Scan
        Find-CloudDuplicates
        Analyze-LocalFiles
        Remove-EmptyFolders
        Write-Summary
}
    catch {
        Write-Log "Error main : $($_.Exception.Message)" "ERROR"
    }
} # main

main
