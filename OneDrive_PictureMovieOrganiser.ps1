# =====================================================================
# OneDrive Organizer — Unified media pipeline
# - Analysis, classification, smart renaming, planning
# - Integrated progress bar
# - Unified logging
# - GPS, tags, camera, source, destination
# - Optimized and consistent version
# =====================================================================

param (
    [bool]$Execute = $true,                          # Actually performs the moves
    [bool]$ResetCache = $false,                      # Resets internal files except GPS and OneDrive cache
    [string]$ConfigFile = ".\config.ini",          # Application configuration
    # === NEW PARAMETERS ===
    [bool]$Analyze = $false,          # Analyze plan.json
    [bool]$DryRun = $false,           # Detailed dry-run mode
    [bool]$Validate = $false,         # Validate OneDrive cache
    [string]$DebugId = "",            # Debug a specific file
    [bool]$ReportIgnored = $false,    # Generate ignored files report
    [string]$ProcessRange = "1..1000",       # Process only a subset of files (e.g., "1", "1..10", "10+")
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
            $confirmation = Get-ConfirmationInteractive "Continue?"
            if ($confirmation -eq 'abort') { throw "User aborted"; }
            if ($confirmation -eq 'skip') { $skippedCount++; continue }
            if ($confirmation -ne 'y') { $skippedCount++; continue }

            # --- STEP 2: Element After ---
            Write-Host "`n[2] ELEMENT AFTER (Classification):" -ForegroundColor Yellow
            Write-Host "  Category:     $($action.Category)" -ForegroundColor Green
            $cleanDst = $action.DstDir.TrimStart('/')
            Write-Host "  Destination:  /$cleanDst" -ForegroundColor Green
            Write-Host "  New name:     $($action.DstName)" -ForegroundColor Green
            Write-Host "  Full path:    $($action.FullDst)" -ForegroundColor Green
            $confirmation = Get-ConfirmationInteractive "Proceed?"
            if ($confirmation -eq 'abort') { throw "User aborted"; }
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
                if ($confirmation -eq 'abort') { throw $_ }
                if ($confirmation -ne 'y') { $skippedCount++; continue }
            }

            if (-not $skipFolderConfirm) {
                $confirmation = Get-ConfirmationInteractive "Confirm folder creation?"
                if ($confirmation -eq 'abort') { throw "User aborted"; }
                if ($confirmation -ne 'y') { $skippedCount++; continue }
            }

            # --- STEP 4: Azure - Move file ---
            Write-Host "`n[4] AZURE - Move file:" -ForegroundColor Yellow
            Write-Host "  From: $($action.SrcPath)/$($action.SrcName)" -ForegroundColor Cyan
            Write-Host "  To:   $($action.FullDst)" -ForegroundColor Cyan
            $confirmation = Get-ConfirmationInteractive "Execute move?"
            if ($confirmation -eq 'abort') { throw "User aborted"; }
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

        $Global:State.Cache | ConvertTo-Json -Depth 10 | Set-Content $global:IndexFile
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
            # Vérifier et rafraîchir le jeton si nécessaire tous les 50 fichiers
            if ($index % 50 -eq 0) { Connect-AzureGraph }

            # Mise à jour fluide de la barre de progression
            Write-Progress -Activity "OneDrive move" `
                -Status "Moving [$index/$total] : $($action.SrcName)" `
                -PercentComplete (($index / $total) * 100)

            # Affichage systématique pour créer le défilement dans la console et le log
            Write-Log "[$index/$total] Moving: $($action.SrcName) -> $($action.FullDst)" "INFO"

            try {
                $dstPathCache = $action.DstDir.TrimStart('/')
                $body = @{
                    parentReference = @{ path = "/drive/root:/" + $dstPathCache }
                    name            = $action.DstName
                } | ConvertTo-Json

                Invoke-RestMethod -Headers $Global:State.Headers `
                    -Uri "https://graph.microsoft.com/v1.0/me/drive/items/$($action.Id)" `
                    -Method PATCH -Body $body -ErrorAction Stop > $null

                "$(Get-Date -Format 'HH:mm:ss'),$($action.Id),SUCCESS,$($action.SrcPath),$($action.FullDst)," |
                Add-Content $global:ExecutionReport

                $action.Id | Add-Content $global:ProcessedLog -Encoding utf8

                $Global:State.Cache.Files[$action.Id].p = "/drive/root:/" + $dstPathCache
                $Global:State.Cache.Files[$action.Id].n = $action.DstName
            }
            catch {
                $errorDetails = Get-ErrorDetails $_
                Write-Log "Error on $($action.Id): $errorDetails" "ERROR"

                "$(Get-Date -Format 'HH:mm'),$($action.Id),ERROR,$($action.SrcPath),$($action.FullDst),$errorDetails" |
                Add-Content $global:ExecutionReport
            }
        }

        $Global:State.Cache | ConvertTo-Json -Depth 10 | Set-Content $global:IndexFile
        Write-Log "Move execution completed." "SUCCESS"
        Write-Progress -Activity "OneDrive move" -Completed
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
        Test-SyncPrerequisites -IndexFile $IndexFile -ProcessedLog $ProcessedLog -ConfigFile $ConfigFile -SourceRoot $PSScriptRoot

        # 2. LOAD AND REPAIR IN-MEMORY DATA
        # Note: Import-Set-Cache is called ONLY ONCE.
        Import-Set-Cache

        # --- OPTIMISATION : Amorçage du cache des dossiers ---
        # On utilise l'index existant pour marquer tous les dossiers connus comme "vérifiés".
        # Cela évite des centaines d'appels API "GET" inutiles.
        Write-Log "Priming folder cache from OneDrive index..." "INFO"
        foreach ($file in $Global:State.Cache.Files.Values) {
            if ($null -eq $file.p) { continue }

            $clean = $file.p -replace '^/drive/root:/?', ''
            $clean = $clean.Trim('/')
            if ([string]::IsNullOrWhiteSpace($clean)) { continue }

            $segments = $clean -split '/'
            $current = ""
            foreach ($seg in $segments) {
                if ($current -eq "") { $current = $seg } else { $current += "/$seg" }
                $Global:State.VerifiedFolders[$current] = $true
            }
        }
        Write-Log "Folder cache primed ($($Global:State.VerifiedFolders.Count) folders known)." "SUCCESS"

        # Repair in-memory cache (remove invalid entries, etc.)
        Repair-Cache

        # Normalize metadata (paths, names, GPS)
        #Repair-Paths
        #Repair-Names
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

        # 3b. SORT AND FILTER PLAN
        if ($Global:State.PlannedActions.Count -gt 0) {
            Write-Log "Ordering plan by Category and Destination Name..." "INFO"
            # Sort naturally by Category then by the generated DstName
            $sortedPlan = $Global:State.PlannedActions | Sort-Object Category, DstName
            $Global:State.PlannedActions = [System.Collections.Generic.List[PSCustomObject]]@($sortedPlan)

            if ($global:ProcessRange) {
                Write-Log "Applying ProcessRange filter: $($global:ProcessRange)" "INFO"
                $filteredPlan = Get-FilteredFileIds -Range $global:ProcessRange -AllIds $Global:State.PlannedActions
                $Global:State.PlannedActions = [System.Collections.Generic.List[PSCustomObject]]@($filteredPlan)
                Write-Log "Plan filtered: $($Global:State.PlannedActions.Count) items remaining" "INFO"
            }
        }

        # 4. CONFLICT RESOLUTION AND VALIDATION
        # Check for name collisions in target destinations
        #Repair-Collisions

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
        $dirTotal = $uniqueDirs.Count
        $dirIdx = 0
        foreach ($dir in $uniqueDirs) {
            $dirIdx++
            # Vérifier la validité du jeton avant chaque vérification de chemin
            Connect-AzureGraph

            Write-Progress -Activity "Checking OneDrive folder hierarchy" `
                -Status "Folder $dirIdx / $dirTotal" `
                -PercentComplete (($dirIdx / $dirTotal) * 100)

            $newFolders = Test-OneDrivePath $dir
            if ($newFolders -gt 0) {
                Write-Log "[$dirIdx/$dirTotal] Verified folder path '$dir' ($newFolders new folders created)" "SUCCESS"
            }
        }
        Write-Progress -Activity "Checking OneDrive folder hierarchy" -Completed

        # Actual file move execution
        if ($StepByStep) {
            Invoke-MovesInteractive
        }
        else {
            Invoke-Moves
        }

        Write-Log "Organization process completed successfully." "SUCCESS"
    }
    catch {
        Write-Log "FATAL ERROR in Start-OneDriveOrganizer: $($_.Exception.Message)" "ERROR"
        Write-Log "Details: $($_.ScriptStackTrace)" "DEBUG"
    }
}

Start-OneDriveOrganizer
