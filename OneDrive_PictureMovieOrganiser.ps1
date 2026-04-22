# =====================================================================
# OneDrive Organizer — Unified media pipeline
# - Analysis, classification, smart renaming, planning
# - Integrated progress bar
# - Unified logging
# - GPS, tags, camera, source, destination
# - Optimized and consistent version
# =====================================================================

param (
    [bool]$Execute = $false,                          # Actually performs the moves
    [bool]$ResetCache = $true,                      # Resets internal files except GPS and OneDrive cache
    [string]$ConfigFile = ".\config.ini",          # Application configuration
    # === NEW PARAMETERS ===
    [bool]$Analyze = $false,          # Analyze plan.json
    [bool]$DryRun = $false,           # Detailed dry-run mode
    [bool]$Validate = $false,         # Validate OneDrive cache
    [string]$DebugId = "",            # Debug a specific file
    [bool]$ReportIgnored = $false,    # Generate ignored files report
    [string]$ProcessRange = "1+"        # Process only a subset of files (e.g., "1", "1..10", "10+")
)

# --- Force Write-Progress display in case another script disabled it
$ProgressPreference = 'Continue'


# =====================================================================
# GLOBAL CONFIGURATION (PLACED BEFORE MODULES)
# =====================================================================

Import-Module "$PSScriptRoot\modules\AppConfig.psm1" -Force
$app = Get-AppConfiguration -ConfigFile $ConfigFile

$global:IndexFile = $app.IndexFile
$global:TokenFile = $app.TokenFile
$global:LogFile = $app.OrganizerLogFile
$global:ProcessedLog = $app.ProcessedLog
$global:ExecutionReport = $app.ExecutionReport
$GpsCacheFile = $app.GpsCacheFile
$VerboseMode = $app.VerboseMode

$global:ProcessRange = $ProcessRange

$Global:Rules = $app.Rules

$Config = [PSCustomObject]@{
    RenameMarker = $app.RenameMarker
    MaxNameLen   = $app.MaxNameLen
    ClientId     = $app.ClientId
    ExtensionMap = $app.ExtensionMap
}

$global:Config = $Config

# =====================================================================
# EXTERNAL MODULES
# =====================================================================

Import-Module "$PSScriptRoot\modules\OneDriveTools.psm1" -ArgumentList $Config.ClientId, $TokenFile, $LogFile -Force
Import-Module "$PSScriptRoot\modules\OneDriveOrganize.psm1" -Force
Import-Module "$PSScriptRoot\modules\OneDriveCacheUtils.psm1" -Force -DisableNameChecking
Import-Module "$PSScriptRoot\modules\GpsTools.psm1" -ArgumentList $GpsCacheFile -Force

# =====================================================================
# GLOBAL STATE
# =====================================================================

# Global script state
$Global:State = @{
    Headers        = $null
    Cache          = $null
    ProcessedIds   = @{}
    PlannedActions = New-Object System.Collections.Generic.List[PSCustomObject]
    FilesToProcess = @{}
}


# =====================================================================
# RESET CACHE (minimum)
# =====================================================================

if ($ResetCache) {
    try {
        Write-Log "Resetting internal OneDrive_PictureMovieOrganiser cache..." "WARN"

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

        Write-Log "Reset completed (GPS + onedrive_cache.json preserved)." "SUCCESS"
    }
    catch {
        Write-Log "Error resetting cache: $($_.Exception.Message)" "ERROR"
    }
}


# =====================================================================
# FUNCTION : Test-OneDrivePath
# ROLE      : Verify and create a folder tree on OneDrive recursively
# =====================================================================
function Test-OneDrivePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RelativePath
    )

    # 1. Safety initialization to avoid missing variable errors
    $uriGet = "Not generated"
    $uriPost = "Not generated"
    $currentPathRaw = ""
    $currentPathEncoded = ""
    $part = "Root"

    try {
        # Clean the path (remove leading/trailing slashes)
        $cleanPath = $RelativePath.Trim('/')
        if ([string]::IsNullOrWhiteSpace($cleanPath)) { return }

        # Split path and trim invisible whitespace
        $pathParts = $cleanPath -split '/' | ForEach-Object { $_.Trim() }

        foreach ($part in $pathParts) {
            if ([string]::IsNullOrWhiteSpace($part)) { continue }

            $parentPathEncoded = $currentPathEncoded
            $encodedPart = [Uri]::EscapeDataString($part)

            # Build the paths
            if ($currentPathRaw -eq "") {
                $currentPathRaw = $part
                $currentPathEncoded = $encodedPart
            }
            else {
                $currentPathRaw += "/$part"
                $currentPathEncoded += "/$encodedPart"
            }

            # --- CHECK (GET) ---
            # Graph syntax: root:/path/to/folder
            $uriGet = "https://graph.microsoft.com/v1.0/me/drive/root:/$currentPathEncoded"

            try {
                Invoke-RestMethod -Headers $Global:State.Headers -Uri $uriGet -Method Get -ErrorAction Stop > $null
            }
            catch {
                # --- CREATE (POST) ---
                # If GET fails, attempt to create the folder
                if ($parentPathEncoded -eq "") {
                    # Folder at root
                    $uriPost = "https://graph.microsoft.com/v1.0/me/drive/root/children"
                }
                else {
                    # Folder under a parent (note the ':' around the parent path)
                    $uriPost = "https://graph.microsoft.com/v1.0/me/drive/root:/$($parentPathEncoded):/children"
                }

                $body = @{
                    name                                = $part
                    folder                              = @{}
                    "@microsoft.graph.conflictBehavior" = "ignore"
                } | ConvertTo-Json -Compress

                Invoke-RestMethod -Headers $Global:State.Headers -Uri $uriPost -Method POST -Body $body -ContentType "application/json" -ErrorAction Stop > $null

                Write-Log "Folder created: /$currentPathRaw" "DEBUG"
                $uriPost = "Not generated" # Reset after success
            }
        }
    }
    catch {
        # --- SIMPLIFIED ERROR BLOCK ---
        $errorMsg = $_.Exception.Message
        $graphError = "No details"

        # Safe attempt to read the server response
        if ($_.Exception.InnerException -and $_.Exception.InnerException.Response) {
            try {
                $stream = $_.Exception.InnerException.Response.GetResponseStream()
                $reader = New-Object System.IO.StreamReader($stream)
                $graphError = $reader.ReadToEnd()
            }
            catch { $graphError = "Unable to read response" }
        }

        Write-Log "!!! FATAL ERROR IN TEST-ONEDRIVEPATH !!!" "ERROR"
        Write-Log "Failed segment : [$part]" "ERROR"
        Write-Log "Raw path      : /$currentPathRaw" "ERROR"
        Write-Log "Used URI      : $(if ($uriPost -ne 'Not generated') { $uriPost } else { $uriGet })" "ERROR"
        Write-Log "PS message    : $errorMsg" "ERROR"
        Write-Log "Graph response: $graphError" "ERROR"

        throw $_ # Stop the script cleanly
    }
}
# =====================================================================
# MOVES
# =====================================================================

# Apply planned moves via Graph
function Invoke-Moves {
    Write-Log "Starting move execution..." "WARN"

    try {
        $total = $Global:State.PlannedActions.Count
        $index = 0

        foreach ($action in $Global:State.PlannedActions) {

            $index++
            if ($index % 200 -eq 0) {
                Write-Progress -Activity "OneDrive move" `
                    -Status "File $index / $total" `
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
                Write-Log "Error on $($action.Id): $errorDetails" "ERROR"

                "$(Get-Date -Format 'HH:mm'),$($action.Id),ERROR,$($action.SrcPath),$($action.FullDst),$errorDetails" |
                Add-Content $ExecutionReport
            }
        }

        $Global:State.Cache | ConvertTo-Json -Depth 10 | Set-Content $IndexFile
        Write-Log "Move execution completed." "SUCCESS"
    }
    catch {
        Write-Log "Invoke-Moves error: $($_.Exception.Message)" "ERROR"
        throw
    }
} # Invoke-Moves



# =====================================================================
# HTML REPORT (ready structure)
# =====================================================================

# Generates a simple HTML report from the plan
function Export-ReportHtml {
    param(
        [string]$OutputFile = ".\onedrive_report.html"  # Output HTML file
    )

    try {
        Write-Log "Generating HTML report..." "INFO"

        $html = @"
<html>
<head>
<title>OneDrive Report</title>
<style>
body { font-family: Arial; margin: 20px; }
h1 { color: #444; }
table { border-collapse: collapse; width: 100%; margin-top: 20px; }
th, td { border: 1px solid #ccc; padding: 6px; }
th { background: #eee; }
</style>
</head>
<body>
<h1>OneDrive Report</h1>
<p>Generated on $(Get-Date)</p>

<h2>Summary</h2>
<ul>
<li>Total files analyzed: $($Global:State.FilesToProcess.Count)</li>
<li>Total planned actions: $($Global:State.PlannedActions.Count)</li>
</ul>

<h2>Planned actions</h2>
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
        Write-Log "HTML report generated: $OutputFile" "SUCCESS"
    }
    catch {
        Write-Log "Error Export-ReportHtml : $($_.Exception.Message)" "ERROR"
    }
} # Export-ReportHtml

# =====================================================================
# MAIN
# =====================================================================

# Main entry point of the script
function Start-OneDriveOrganizer {
    <#
    .SYNOPSIS
        Main entry point of the OneDrive organizer.
        Manages lifecycle: cleanup -> planning -> correction -> execution.
    #>

    # 1. LOG CLEANUP (single run at startup)
    if (Test-Path $LogFile) {
        try {
            Remove-Item $LogFile -Force -ErrorAction SilentlyContinue
            # Recreate an empty log file so Write-Log can write immediately
            New-Item -Path $LogFile -ItemType File -Force | Out-Null
        }
        catch {
            Write-Log "Unable to reset the log: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }

    Write-Log "=== SESSION START: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ===" "INFO"

    try {
        # 1b. PRE-REQUISITE CHECK: Validate Sync cache before proceeding
        Test-SyncPrerequisites -IndexFile $IndexFile -ProcessedLog $ProcessedLog -ConfigFile $ConfigFile -PSScriptRoot $PSScriptRoot

        # 2. LOAD AND REPAIR IN-MEMORY DATA
        # Note: Import-Set-Cache is called ONLY ONCE.
        Import-Set-Cache

        # Repair in-memory cache (remove invalid entries, etc.)
        Repair-Cache

        # Normalize metadata (paths, names, GPS)
        Repair-Paths
        Repair-Names
        Repair-GPS

        # 3. PLAN MANAGEMENT (Resume or New)
        # Check whether a plan already exists for this exact cache file (via hash)
        $hash = Get-CacheHash
        $plan = if ($hash) { Get-ExistingPlan -CurrentHash $hash } else { $null }

        if ($null -eq $plan) {
            Write-Log "No valid plan found. Starting full analysis..." "INFO"
            New-Plan

            # After New-Plan, save the current hash for next time
            if ($hash) {
                $hashFile = Join-Path (Split-Path $IndexFile -Parent) "cache_hash.txt"
                $hash | Set-Content $hashFile
            }
        }
        else {
            Write-Log "Existing plan resume detected (identical SHA256 hash)." "SUCCESS"
            $Global:State.PlannedActions = [System.Collections.Generic.List[PSCustomObject]]$plan
        }

        # 4. CONFLICT RESOLUTION AND VALIDATION
        # Check for name collisions in target destinations
        Repair-Collisions

        # Final plan analysis (remaining duplicates, too-long paths)
        Test-Plan

        # 5. EXECUTION MODE CHECK
        if (-not $Execute) {
            Write-Log "DRY-RUN MODE: Rerun the script with -Execute `$true to apply changes." "INFO"
            return
        }

        # 6. REAL EXECUTION (GRAPH API)
        Write-Log "SWITCHING TO REAL EXECUTION MODE..." "WARN"
        Connect-AzureGraph

        # Proactively create destination folders to avoid 404 errors
        Write-Log "Checking OneDrive folder hierarchy..." "INFO"
        $uniqueDirs = $Global:State.PlannedActions.DstDir | Select-Object -Unique
        foreach ($dir in $uniqueDirs) {
            Test-OneDrivePath $dir
        }

        # Actual file move execution
        Invoke-Moves

        Write-Log "Organization process completed successfully." "SUCCESS"
    }
    catch {
        Write-Log "FATAL ERROR in Start-OneDriveOrganizer: $($_.Exception.Message)" "ERROR"
        Write-Log "Details: $($_.ScriptStackTrace)" "DEBUG"
    }
}

Start-OneDriveOrganizer
