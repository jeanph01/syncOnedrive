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
    [bool]$ResetCache = $false,                      # Resets internal files except GPS and OneDrive cache
    [string]$ConfigFile = ".\config.ini",          # Application configuration
    # === NEW PARAMETERS ===
    [bool]$Analyze = $false,          # Analyze plan.json
    [bool]$DryRun = $false,           # Detailed dry-run mode
    [bool]$Validate = $false,         # Validate OneDrive cache
    [string]$DebugId = "",            # Debug a specific file
    [bool]$ReportIgnored = $false,    # Generate ignored files report
    [string]$ProcessRange = "1+",       # Process only a subset of files (e.g., "1", "1..10", "10+")
    [bool]$StepByStep = $false         # Interactive step-by-step mode with confirmation
)

# --- Force Write-Progress display in case another script disabled it
$ProgressPreference = 'Continue'

Clear-Host

# =====================================================================
# GLOBAL CONFIGURATION (PLACED BEFORE MODULES)
# =====================================================================

Import-Module "$PSScriptRoot\modules\AppConfig.psm1" -Force
$app = Get-AppConfiguration -ConfigFile $ConfigFile

$global:IndexFile = $app.IndexFile
$global:TokenFile = $app.TokenFile
$global:LogFile = $app.OrganizerLogFile
$global:OrganizerLogFile = $app.OrganizerLogFile # Explicitly define for this script
$global:ProcessedLog = $app.ProcessedLog
$global:ExecutionReport = $app.ExecutionReport
$GpsCacheFile = $app.GpsCacheFile


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
Import-Module "$PSScriptRoot\modules\OneDriveOrganize.psm1" -ArgumentList $Config.ClientId, $TokenFile, $LogFile -Force -DisableNameChecking
Import-Module "$PSScriptRoot\modules\OneDriveCacheUtils.psm1" -Force -DisableNameChecking
Import-Module "$PSScriptRoot\modules\GpsTools.psm1" -ArgumentList $GpsCacheFile -Force

# =====================================================================
# GLOBAL STATE
# =====================================================================

# Global script state
$Global:State = @{
    Headers         = $null
    Cache           = $null
    ProcessedIds    = @{}
    PlannedActions  = New-Object System.Collections.Generic.List[PSCustomObject]
    FilesToProcess  = @{}
    VerifiedFolders = @{}
}


# =====================================================================
# RESET CACHE (minimum)
# =====================================================================

if ($ResetCache) {
    $createdCount = 0
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

    $cleanPath = $RelativePath.Trim('/')
    if ([string]::IsNullOrWhiteSpace($cleanPath)) { return 0 }

    # Check session cache to skip redundant network calls for shared parent folders
    if ($Global:State.VerifiedFolders.ContainsKey($cleanPath)) {
        return 0
    }

    # 1. Safety initialization to avoid missing variable errors
    $uriGet = "Not generated"
    $uriPost = "Not generated"
    $currentPathRaw = ""
    $currentPathEncoded = ""
    $part = "Root"
    $createdCount = 0

    try {
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

            # Skip segment if verified in previous call during this execution
            if ($Global:State.VerifiedFolders.ContainsKey($currentPathRaw)) { continue }

            # --- CHECK (GET) ---
            # Graph syntax: root:/path/to/folder
            $encoded = $currentPathEncoded
            $uriGet = "https://graph.microsoft.com/v1.0/me/drive/root:/$encoded"

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
                    $uriPost = "https://graph.microsoft.com/v1.0/me/drive/root:/$parentPathEncoded" + ":/children"
                }

                try {
                    $body = @{
                        name                                = $part
                        folder                              = @{ }
                        "@microsoft.graph.conflictBehavior" = "fail"
                    } | ConvertTo-Json -Compress

                    Invoke-RestMethod -Headers $Global:State.Headers -Uri $uriPost -Method POST -Body $body -ContentType "application/json" -ErrorAction Stop > $null
                    Write-Log "Folder created: /$currentPathRaw" "DEBUG"
                    $createdCount++
                }
                catch {
                    # Robust status code check for both PS 5.1 and 7
                    $isConflict = $false
                    if ($_.Exception.Response) {
                        $status = [int]$_.Exception.Response.StatusCode
                        if ($status -eq 409) { $isConflict = $true }
                    }

                    if ($isConflict -or (Get-ErrorDetails $_) -match "alreadyExists") {
                        Write-Log "Folder already exists (detected via 409 conflict): /$currentPathRaw" "DEBUG"
                    }
                    else {
                        throw $_
                    }
                }
            }

            # Folder verified or created: mark in session cache
            $Global:State.VerifiedFolders[$currentPathRaw] = $true
        }

        return $createdCount
    }
    catch {
        # --- ENHANCED ERROR BLOCK FOR DEBUG ---
        $errorMsg = $_.Exception.Message
        $graphError = Get-ErrorDetails $_
        $httpStatusCode = "Unknown"

        # Try to extract HTTP status code
        if ($_.Exception.Response) {
            try {
                $httpStatusCode = [int]$_.Exception.Response.StatusCode
            }
            catch {
                try {
                    $httpStatusCode = $_.Exception.Response.StatusCode
                }
                catch {}
            }
        }

        Write-Log "!!! FATAL ERROR IN TEST-ONEDRIVEPATH !!!" "ERROR"
        Write-Log "Failed segment : [$part]" "ERROR"
        Write-Log "Raw path      : /$currentPathRaw" "ERROR"
        Write-Log "Used URI      : $(if ($uriPost -ne 'Not generated') { $uriPost } else { $uriGet })" "ERROR"
        Write-Log "HTTP Status   : $httpStatusCode" "ERROR"
        Write-Log "PS message    : $errorMsg" "ERROR"
        Write-Log "Graph response: $graphError" "ERROR"

        # ===== DEBUG COPY-PASTE SECTION =====
        Write-Log "-" "ERROR"
        Write-Log "=== DEBUG INFO FOR POSTMAN / MANUAL TESTING ===" "ERROR"
        Write-Log "Method: POST" "ERROR"
        Write-Log "URL: $(if ($uriPost -ne 'Not generated') { $uriPost } else { $uriGet })" "ERROR"
        Write-Log "Headers:" "ERROR"
        Write-Log "  Authorization: Bearer <YOUR_TOKEN>" "ERROR"
        Write-Log "  Content-Type: application/json" "ERROR"
        Write-Log "Body (JSON):" "ERROR"
        if ($uriPost -ne 'Not generated') {
            $debugBody = @{
                name                                = $part
                folder                              = @{ }
                "@microsoft.graph.conflictBehavior" = "fail"
            } | ConvertTo-Json -Depth 10
            foreach ($line in ($debugBody -split "`n")) {
                Write-Log "  $line" "ERROR"
            }
        }
        Write-Log "-" "ERROR"
        Write-Log "Response received:" "ERROR"
        foreach ($line in ($graphError -split "`n")) {
            Write-Log "  $line" "ERROR"
        }
        Write-Log "=== END DEBUG INFO ===" "ERROR"

        throw $_ # Stop the script cleanly
    }
}
# =====================================================================
# INTERACTIVE STEP-BY-STEP MODE
# =====================================================================

# Interactive confirmation and execution for each file
function Invoke-MovesInteractive {
    Write-Log "Starting interactive move execution (step-by-step)..." "WARN"

    try {
        $total = $Global:State.PlannedActions.Count
        $index = 0
        $processedCount = 0
        $skippedCount = 0

        foreach ($action in $Global:State.PlannedActions) {
            $index++
            Write-Host "`n================ ACTION $index / $total ================" -ForegroundColor Cyan
            Write-Log "Interactive session progress: $index / $total" "DEBUG"

            # --- STEP 1: Element Before ---
            Write-Host "`n[1] ELEMENT BEFORE:" -ForegroundColor Yellow
            Write-Host "  Path: $($action.SrcPath)" -ForegroundColor Gray
            Write-Host "  Name: $($action.SrcName)" -ForegroundColor Gray
            Write-Host "  ID:   $($action.Id)" -ForegroundColor Gray

            # --- STEP 2: Planned destination ---
            $plannedDstDir = if ([string]::IsNullOrWhiteSpace($action.DstDir)) { "<unknown>" } else { $action.DstDir }
            $plannedDstName = if ([string]::IsNullOrWhiteSpace($action.DstName)) { "<unknown>" } else { $action.DstName }
            $plannedFullDst = if ([string]::IsNullOrWhiteSpace($action.FullDst)) { "<unknown>" } else { $action.FullDst }
            Write-Host "`n[2] ELEMENT AFTER (Planned):" -ForegroundColor Yellow
            Write-Host "  Category:     $($action.Category)" -ForegroundColor Green
            Write-Host "  Destination:  $plannedDstDir" -ForegroundColor Green
            Write-Host "  New name:     $plannedDstName" -ForegroundColor Green
            Write-Host "  Full path:    $plannedFullDst" -ForegroundColor Green

            $confirmation = Get-ConfirmationInteractive "Continue?"
            if ($confirmation -eq 'abort') { Write-Log "Interactive move execution aborted by user." "WARN"; return }
            if ($confirmation -eq 'skip') { $skippedCount++; continue }
            if ($confirmation -ne 'y') { $skippedCount++; continue }

            $cleanDst = $action.DstDir.TrimStart('/')
            $confirmation = Get-ConfirmationInteractive "Proceed?"
            if ($confirmation -eq 'abort') { Write-Log "Interactive move execution aborted by user." "WARN"; return }
            if ($confirmation -ne 'y') { $skippedCount++; continue }

            # --- STEP 3: Azure - Create folders ---
            Write-Host "`n[3] AZURE - Create folders if needed:" -ForegroundColor Yellow
            Write-Host "  Folder path: /$cleanDst" -ForegroundColor Cyan
            $skipFolderConfirm = $false
            try {
                $created = Test-OneDrivePath $action.DstDir
                if ($created -eq 0) {
                    Write-Host "  ✓ Aucun dossier à créer (existe déjà) - pas de confirmation requise" -ForegroundColor Green
                    $skipFolderConfirm = $true
                }
                else {
                    Write-Host "  ✓ Dossiers à créer: $created" -ForegroundColor Green
                }
            }
            catch {
                Write-Host "  ✗ Error creating folders: $_" -ForegroundColor Red
                $confirmation = Get-ConfirmationInteractive "Continue anyway?"
                if ($confirmation -eq 'abort') { Write-Log "Interactive move execution aborted by user." "WARN"; return }
                if ($confirmation -ne 'y') { $skippedCount++; continue }
            }

            if (-not $skipFolderConfirm) {
                $confirmation = Get-ConfirmationInteractive "Confirm folder creation?"
                if ($confirmation -eq 'abort') { Write-Log "Interactive move execution aborted by user." "WARN"; return }
                if ($confirmation -ne 'y') { $skippedCount++; continue }
            }

            # --- STEP 4: Azure - Move file ---
            Write-Host "`n[4] AZURE - Move file:" -ForegroundColor Yellow
            Write-Host "  From: $($action.SrcPath)/$($action.SrcName)" -ForegroundColor Cyan
            Write-Host "  To:   $($action.FullDst)" -ForegroundColor Cyan
            $confirmation = Get-ConfirmationInteractive "Execute move?"
            if ($confirmation -eq 'abort') { Write-Log "Interactive move execution aborted by user." "WARN"; return }
            if ($confirmation -ne 'y') { $skippedCount++; continue }

            try {
                $dstPathClean = $action.DstDir.TrimStart('/')
                $body = @{
                    parentReference = @{ path = "/drive/root:/" + $dstPathClean }
                    name            = $action.DstName
                } | ConvertTo-Json

                Invoke-RestMethod -Headers $Global:State.Headers `
                    -Uri "https://graph.microsoft.com/v1.0/me/drive/items/$($action.Id)" `
                    -Method PATCH -Body $body -ErrorAction Stop > $null

                Write-Host "  ✓ Move successful" -ForegroundColor Green
                "$(Get-Date -Format 'HH:mm'),$($action.Id),SUCCESS,$($action.SrcPath),$($action.FullDst)," |
                Add-Content $global:ExecutionReport

                $action.Id | Add-Content $global:ProcessedLog -Encoding utf8

                $dstPathCache = $action.DstDir.TrimStart('/')
                $Global:State.Cache.Files[$action.Id].p = "/drive/root:/" + $dstPathCache
                $Global:State.Cache.Files[$action.Id].n = $action.DstName

                $processedCount++
            }
            catch {
                $errorDetails = Get-ErrorDetails $_
                Write-Host "  ✗ Error: $errorDetails" -ForegroundColor Red
                "$(Get-Date -Format 'HH:mm'),$($action.Id),ERROR,$($action.SrcPath),$($action.FullDst),$errorDetails" |
                Add-Content $global:ExecutionReport
                $skippedCount++
            }
        }


        $Global:State.Cache | ConvertTo-Json -Depth 10 | Set-Content "$($global:IndexFile).tmp"
        Move-Item -Path "$($global:IndexFile).tmp" -Destination $global:IndexFile -Force
        Write-Host "`n" -NoNewline
        Write-Host "========================================" -ForegroundColor Cyan
        Write-Host "Summary: $processedCount processed, $skippedCount skipped" -ForegroundColor Cyan
        Write-Host "========================================" -ForegroundColor Cyan
        Write-Log "Interactive move execution completed. Processed: $processedCount, Skipped: $skippedCount" "SUCCESS"
    }
    catch {
        Write-Log "Invoke-MovesInteractive error: $($_.Exception.Message)" "ERROR"
        throw
    }
} # Invoke-MovesInteractive

# Helper: read confirmation with defaults (Y default, s=skip, a=abort)
function Get-ConfirmationInteractive {
    param([string]$Prompt)

    $full = "$Prompt (Y=default, s=skip, a=abort)"
    $ans = Read-Host $full
    if ([string]::IsNullOrWhiteSpace($ans)) { $ans = 'y' }
    $ans = $ans.ToLower()

    switch ($ans) {
        's' { return 'skip' }
        'a' { return 'abort' }
        default { return $ans }
    }
}

function Initialize-TargetFolders {
    param([array]$Actions)

    $uniqueFolders = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($action in $Actions) {
        if ($null -eq $action -or [string]::IsNullOrWhiteSpace($action.DstDir)) { continue }
        $cleanFolder = $action.DstDir.Trim('/')
        if ($cleanFolder) {
            $null = $uniqueFolders.Add($cleanFolder)
        }
    }

    if ($uniqueFolders.Count -eq 0) {
        return
    }

    Write-Log "Pre-creating $($uniqueFolders.Count) unique destination folders..." "INFO"
    foreach ($folder in $uniqueFolders) {
        try {
            Test-OneDrivePath $folder | Out-Null
        }
        catch {
            Write-Log "Folder precreation failed for /$folder : $($_.Exception.Message)" "WARN"
        }
    }
}

function Register-MoveSuccess {
    param([psobject]$Action)

    $dstPathCache = $Action.DstDir.TrimStart('/')

    "$(Get-Date -Format 'HH:mm:ss'),$($Action.Id),SUCCESS,$($Action.SrcPath),$($Action.FullDst)," |
    Add-Content $global:ExecutionReport

    $Action.Id | Add-Content $global:ProcessedLog -Encoding utf8

    $Global:State.Cache.Files[$Action.Id].p = "/drive/root:/" + $dstPathCache
    $Global:State.Cache.Files[$Action.Id].n = $Action.DstName
}

function Register-MoveFailure {
    param(
        [psobject]$Action,
        [string]$ErrorDetails
    )

    "$(Get-Date -Format 'HH:mm'),$($Action.Id),ERROR,$($Action.SrcPath),$($Action.FullDst),$ErrorDetails" |
    Add-Content $global:ExecutionReport
}

function Invoke-GraphSingleMove {
    param(
        [psobject]$Action,
        [int]$Index,
        [int]$Total
    )

    Write-Progress -Activity "OneDrive move" `
        -Status "Moving [$Index/$Total] : $($Action.SrcName)" `
        -PercentComplete (($Index / $Total) * 100)

    Write-Log "[$Index/$Total] Moving: $($Action.SrcName) -> $($Action.FullDst)" "INFO"

    try {
        $dstPathCache = $Action.DstDir.TrimStart('/')
        $body = @{
            parentReference = @{ path = "/drive/root:/" + $dstPathCache }
            name            = $Action.DstName
        } | ConvertTo-Json

        Invoke-RestMethod -Headers $Global:State.Headers `
            -Uri "https://graph.microsoft.com/v1.0/me/drive/items/$($Action.Id)" `
            -Method PATCH -Body $body -ErrorAction Stop > $null

        Register-MoveSuccess -Action $Action
        return $true
    }
    catch {
        $errorDetails = Get-ErrorDetails $_
        Write-Log "Error on $($Action.Id): $errorDetails" "ERROR"
        Register-MoveFailure -Action $Action -ErrorDetails $errorDetails
        return $false
    }
}

function Invoke-GraphBatchMoves {
    param(
        [array]$Actions,
        [int]$BatchSize = 20
    )

    $total = $Actions.Count
    $completed = 0

    for ($start = 0; $start -lt $total; $start += $BatchSize) {
        $end = [Math]::Min($start + $BatchSize - 1, $total - 1)
        $chunk = @($Actions[$start..$end])

        $requests = @()
        $requestMap = @{}
        $requestIndex = 0

        foreach ($action in $chunk) {
            $requestIndex++
            $requestId = [string]$requestIndex
            $dstPathCache = $action.DstDir.TrimStart('/')

            $requests += [pscustomobject]@{
                id     = $requestId
                method = 'PATCH'
                url    = "/me/drive/items/$($action.Id)"
                body   = @{
                    parentReference = @{ path = "/drive/root:/" + $dstPathCache }
                    name            = $action.DstName
                }
            }

            $requestMap[$requestId] = $action
        }

        $payload = @{ requests = $requests } | ConvertTo-Json -Depth 10

        try {
            $batchResponse = Invoke-RestMethod -Headers $Global:State.Headers `
                -Uri "https://graph.microsoft.com/v1.0/`$batch" `
                -Method POST -Body $payload -ContentType "application/json" -ErrorAction Stop
        }
        catch {
            Write-Log "Batch request failed for actions $($start + 1)-$($end + 1): $($_.Exception.Message)" "WARN"
            foreach ($action in $chunk) {
                $completed++
                Invoke-GraphSingleMove -Action $action -Index $completed -Total $total | Out-Null
            }
            continue
        }

        foreach ($response in $batchResponse.responses) {
            $action = $requestMap[$response.id]
            if (-not $action) { continue }

            $completed++
            Write-Progress -Activity "OneDrive move" `
                -Status "Moving [$completed/$total] : $($action.SrcName)" `
                -PercentComplete (($completed / $total) * 100)

            if ($response.status -ge 200 -and $response.status -lt 300) {
                Write-Log "[$completed/$total] Moving: $($action.SrcName) -> $($action.FullDst)" "INFO"
                Register-MoveSuccess -Action $action
            }
            else {
                $errorDetails = $null
                if ($response.body -and $response.body.error -and $response.body.error.message) {
                    $errorDetails = $response.body.error.message
                }
                elseif ($response.body) {
                    $errorDetails = ($response.body | ConvertTo-Json -Depth 5)
                }
                else {
                    $errorDetails = "Batch request failed (HTTP $($response.status))"
                }

                Write-Log "Error on $($action.Id): $errorDetails" "ERROR"
                Register-MoveFailure -Action $action -ErrorDetails $errorDetails
            }
        }

        if ($completed % 50 -eq 0) {
            Connect-AzureGraph
            Write-Log "Saving intermediate cache state ($completed/$total)..." "DEBUG"
            $Global:State.Cache | ConvertTo-Json -Depth 10 | Set-Content "$($global:IndexFile).tmp"
            Move-Item -Path "$($global:IndexFile).tmp" -Destination $global:IndexFile -Force
        }
    }
}

# =====================================================================
# MOVES
# =====================================================================

# Apply planned moves via Graph
function Invoke-Moves {
    Write-Log "Starting move execution..." "WARN"

    try {
        $actions = @($Global:State.PlannedActions)

        Initialize-TargetFolders -Actions $actions
        Invoke-GraphBatchMoves -Actions $actions

        $Global:State.Cache | ConvertTo-Json -Depth 10 | Set-Content "$($global:IndexFile).tmp"
        Move-Item -Path "$($global:IndexFile).tmp" -Destination $global:IndexFile -Force
        Write-Log "Move execution completed." "SUCCESS"
        Write-Progress -Activity "OneDrive move" -Completed
    }
    catch {
        Write-Log "Invoke-Moves error: $($_.Exception.Message)" "ERROR"
        throw
    }
} # Invoke-Moves

function Start-Analysis {
    Write-Log "=== MODE: ANALYSIS ===" "INFO"
    try {
        # Load the plan from disk without performing a full analysis
        $cacheFolder = Split-Path $global:IndexFile -Parent
        $planPath = Join-Path $cacheFolder "plan.json"
        if (-not (Test-Path $planPath)) {
            Write-Log "plan.json not found. Run the script without parameters to generate it first." "WARN"
            return
        }

        $planContent = Get-Content $planPath -Raw
        if ([string]::IsNullOrWhiteSpace($planContent)) {
            Write-Log "plan.json is empty. Nothing to analyze." "WARN"
            return
        }

        $Global:State.PlannedActions = $planContent | ConvertFrom-Json
        Test-Plan
    }
    catch {
        Write-Log "Start-Analysis error: $($_.Exception.Message)" "ERROR"
    }
}

function Start-Validation {
    Write-Log "=== MODE: VALIDATION ===" "INFO"
    try {
        # Load cache and then run validation checks
        Import-Set-Cache
        Test-Cache
    }
    catch {
        Write-Log "Start-Validation error: $($_.Exception.Message)" "ERROR"
    }
}

function Start-Debug {
    param([string]$Id)
    Write-Log "=== MODE: DEBUG ===" "INFO"
    try {
        if ([string]::IsNullOrWhiteSpace($Id)) {
            Write-Log "Debug mode requires a file ID. Use -DebugId <ID>." "WARN"
            return
        }
        # Load cache and then debug the specific file
        Import-Set-Cache
        Debug-File -Id $Id
    }
    catch {
        Write-Log "Start-Debug error: $($_.Exception.Message)" "ERROR"
    }
}

function Start-DryRunMode {
    Write-Log "=== MODE: DRY-RUN ===" "INFO"
    try {
        # This function is a placeholder for a more detailed dry-run if needed.
        # Currently, the main pipeline handles this by checking -Execute.
        Write-Log "Detailed dry-run simulation. No changes will be made." "INFO"
        Start-OneDriveOrganizer
    }
    catch {
        Write-Log "Start-DryRunMode error: $($_.Exception.Message)" "ERROR"
    }
}


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
# MAIN PIPELINE ORCHESTRATOR
# =====================================================================

function Start-OneDriveOrganizer {
    Write-Log "=== STARTING ONEDRIVE ORGANIZER PIPELINE ===" "WARN"

    try {
        # --- STEP 1: INITIALIZE AZURE CONNECTION ---
        Write-Log "Step 1: Connecting to Azure Graph..." "INFO"
        Connect-AzureGraph

        # --- STEP 2: LOAD OR CREATE CACHE ---
        Write-Log "Step 2: Loading OneDrive cache..." "INFO"
        Import-Set-Cache

        # --- STEP 3: REFRESH PREREQUISITES ---
        Write-Log "Step 3: Testing prerequisites..." "INFO"
        Test-SyncPrerequisites

        # --- STEP 4: ENUMERATE FILES WITH PROGRESS ---
        Write-Log "Step 4: Enumerating files from OneDrive..." "INFO"
        $fileIds = Get-FilteredFileIds -Range $global:ProcessRange -AllIds $Global:State.FilesToProcess.Keys
        $total = $fileIds.Count

        if ($total -eq 0) {
            Write-Log "No files to process." "WARN"
            return
        }

        Write-Log "Found $total files to process." "INFO"

        # --- STEP 5: PROCESS FILES AND BUILD PLAN ---
        Write-Log "Step 5: Analyzing and building action plan..." "INFO"
        $Global:State.PlannedActions.Clear()
        New-Plan

        # --- STEP 7: DISPLAY SUMMARY ---
        $actionCount = $Global:State.PlannedActions.Count
        Write-Log "Analysis complete: $actionCount actions planned" "SUCCESS"

        # --- STEP 8: EXECUTE OR DEFER MOVES ---
        if ($actionCount -gt 0) {
            if ($StepByStep) {
                Write-Log "Step 8: Running in interactive step-by-step mode..." "INFO"
                Invoke-MovesInteractive
            }
            elseif ($Execute) {
                Write-Log "Step 8: Executing planned moves..." "INFO"
                Invoke-Moves
            }
            else {
                Write-Log "Step 8: Dry-run complete. Use -Execute to perform moves." "WARN"
                Write-Log "Run with -Analyze to review the plan in detail." "INFO"
            }
        }

        Write-Log "=== ONEDRIVE ORGANIZER PIPELINE COMPLETE ===" "SUCCESS"
    }
    catch {
        Write-Log "Start-OneDriveOrganizer error: $($_.Exception.Message)" "ERROR"
        throw
    }
}

# =====================================================================
# MAIN
# =====================================================================
# =====================================================================
# MAIN ENTRY POINT
# =====================================================================

if ($Analyze) {
    Start-Analysis
}
elseif ($Validate) {
    Start-Validation
}
elseif (-not [string]::IsNullOrWhiteSpace($DebugId)) {
    Start-Debug -Id $DebugId
}
elseif ($DryRun) {
    # Force l'exécution en mode lecture seule
    $Execute = $false
    $StepByStep = $false
    Start-DryRunMode
}
else {
    # Pipeline par défaut
    Start-OneDriveOrganizer
}
