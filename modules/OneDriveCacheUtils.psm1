﻿﻿﻿if ($script:ModuleLoaded) {
    return
}
$script:ModuleLoaded = $true

# Validate OneDriveTools dependency
if (-not (Get-Command Write-Log -ErrorAction SilentlyContinue)) {
    Write-Warning "OneDriveTools (Write-Log) is not loaded. Ensure modules are imported in the correct order."
}

function Test-SyncPrerequisites {
    param(
        [string]$IndexFile,
        [string]$ProcessedLog,
        [string]$ConfigFile,
        [string]$SourceRoot
    )

    $requiredFiles = @(
        $IndexFile
        #,$ProcessedLog
    )

    $missingFiles = @()
    foreach ($file in $requiredFiles) {
        if ($file -and -not (Test-Path $file)) {
            $missingFiles += $file
        }
    }

    if ($missingFiles.Count -gt 0) {
        Write-Log "WARNING: Required cache files from OneDrive_Sync.ps1 are missing:" "WARN"
        foreach ($f in $missingFiles) {
            Write-Log "  - $f" "WARN"
        }

        Write-Log "Launching OneDrive_Sync.ps1 first..." "INFO"
        $syncScript = Join-Path $SourceRoot "OneDrive_Sync.ps1"
        if (Test-Path $syncScript) {
            & $syncScript -ConfigFile $ConfigFile
            Write-Log "Sync completed. Continuing with organization..." "SUCCESS"
        }
        else {
            Write-Log "ERROR: OneDrive_Sync.ps1 not found at $syncScript" "ERROR"
            exit 1
        }
    }
    else {
        Write-Log "All required cache files from OneDrive_Sync.ps1 are present." "SUCCESS"
    }
}


function Test-Cache {
    try {
        Write-Log "=== CACHE VALIDATION ===" "INFO"

        $cache = $Global:State.Cache.Files
        $total = $cache.Count

        $missingPath = $cache.GetEnumerator() | Where-Object { -not $_.Value.p }
        $missingName = $cache.GetEnumerator() | Where-Object { -not $_.Value.n }
        $badPrefix = $cache.GetEnumerator() | Where-Object { $_.Value.p -notmatch "^/drive/root:" }
        $badExt = $cache.GetEnumerator() | Where-Object {
            $ext = [IO.Path]::GetExtension($_.Value.n).ToLower()
            -not $Config.ExtensionMap.ContainsKey($ext)
        }

        Write-Log "Total entries: $total" "INFO"
        Write-Log "Missing path: $($missingPath.Count)" "WARN"
        Write-Log "Missing name: $($missingName.Count)" "WARN"
        Write-Log "Invalid path: $($badPrefix.Count)" "WARN"
        Write-Log "Unknown extension: $($badExt.Count)" "WARN"

        Write-Log "Validation terminee." "SUCCESS"
    }
    catch {
        Write-Log "Invoke-Moves error: $($_.Exception.Message)" "ERROR"
        throw
    }

} # Test-Cache

# Load existing plan if cache hash matches
function Get-ExistingPlan {
    param(
        [string]$CurrentHash  # Hash actuel du cache OneDrive
    )

    try {
        $cacheFolder = Split-Path $Global:IndexFile -Parent
        $planFile = Join-Path $cacheFolder "plan.json"
        $hashFile = Join-Path $cacheFolder "cache_hash.txt"

        if (-not (Test-Path $planFile) -or -not (Test-Path $hashFile)) {
            return $null
        }

        $oldHash = Get-Content $hashFile -ErrorAction Stop

        if ($oldHash -eq $CurrentHash) {
            Write-Log "Plan existant valide - reprise sans analyse." "SUCCESS"
            $content = Get-Content $planFile -Raw
            if ([string]::IsNullOrWhiteSpace($content)) { return $null }
            try {
                return ($content | ConvertFrom-Json)
            }
            catch {
                Write-Log "Existing plan.json is corrupted or truncated. Ignoring." "WARN"
                return $null
            }
        }

        Write-Log "Existing plan invalid (hash mismatch)." "WARN"
        return $null
    }
    catch {
        Write-Log "Error loading existing plan : $($_.Exception.Message)" "ERROR"
        return $null
    }
} # Get-ExistingPlan


# =====================================================================
# CACHE LOADING
# =====================================================================

# Load OneDrive cache and prepare FilesToProcess / ProcessedIds
function Import-Set-Cache {
    try {
        # Write-Log "Cleaning old log $LogFile"
        # if (Test-Path $LogFile) { Remove-Item $LogFile -Force }

        Write-Log "Loading OneDrive cache $Global:IndexFile ..." "INFO"
        if (!(Test-Path $Global:IndexFile)) {
            Write-Log "Cache not found: $Global:IndexFile" "ERROR"
            exit 1
        }

        $Global:State.Cache = ConvertFrom-JsonOptimized -JsonString (Get-Content $Global:IndexFile -Raw) -AsHashtable

        if (-not $Global:State.Cache.Files) {
            Write-Log "No files in cache." "ERROR"
            exit 1
        }

        Write-Log "Loading already processed IDs ($Global:ProcessedLog) ..."
        $Global:State.ProcessedIds = @{}
        $Global:State.FilesToProcess = @{}

        if (Test-Path $Global:ProcessedLog) {
            Get-Content $Global:ProcessedLog -Encoding utf8 | ForEach-Object {
                # Trim whitespace and handle legacy JSON characters (quotes, commas, braces) if they exist
                $id = $_.Trim(' "''{},')
                # Only add if it's a valid ID (not JSON metadata or empty)
                if ($id -and $id -ne "true" -and $id -ne "false") { $Global:State.ProcessedIds[$id] = $true }
            }
            Write-Log "Already processed files : $($Global:State.ProcessedIds.Count)"
        }
        else {
            Write-Log "No previously processed files (file $ProcessedLog missing)."
        }

        Write-Log "Discovering already processed files containing marker '$($Global:Config.RenameMarker)' ..."
        $index = 0
        $total = $Global:State.Cache.Files.Count
        $skippedLog = 0
        $skippedMarker = 0
        foreach ($id in $Global:State.Cache.Files.Keys) {
            $index++
            if ($index % 500 -eq 0) {
                Write-Progress -Activity "Analyzing files" `
                    -Status "$index / $total" `
                    -PercentComplete (($index / $total) * 100)
            }
            $fileMeta = $Global:State.Cache.Files[$id]

            # a) Si deja dans ProcessedIds => ignorer
            if ($Global:State.ProcessedIds.ContainsKey($id)) {
                $skippedLog++
                continue
            }
            # b) Si le nom contient le marqueur => l'ajouter a ProcessedIds
            if ($fileMeta.n -like "*$($Global:Config.RenameMarker)*") {
                $skippedMarker++
                $Global:State.ProcessedIds[$id] = $true
                continue
            }

            # c) Otherwise → file to process
            $Global:State.FilesToProcess[$id] = $fileMeta
        }

        Write-Progress -Activity "Analysis completed" -Completed
        Write-Log "Discovery summary: $skippedLog skipped (via processed log), $skippedMarker skipped (via filename marker)." "INFO"
        Write-Log "Indexing complete. Files to process: $($Global:State.FilesToProcess.Count)"
        "Timestamp,ID,Status,OldPath,NewPath,Error" | Set-Content $Global:ExecutionReport
    }
    catch {
        Write-Log "Import-Set-Cache error : $($_.Exception.Message)" "ERROR"
        throw
    }
} # Import-Set-Cache

# =====================================================================
# MERGED PIPELINE: ANALYSIS + PROGRESS BAR + PLAN
# =====================================================================

function Get-FilteredFileIds {
    param([string]$Range, [array]$AllIds)

    if ([string]::IsNullOrWhiteSpace($Range)) {
        return $AllIds
    }

    $total = $AllIds.Count

    # Parse range patterns
    if ($Range -match '^(\d+)$') {
        # Single number: "1" -> first file only
        $index = [int]$Matches[1] - 1
        if ($index -ge 0 -and $index -lt $total) {
            return @($AllIds[$index])
        }
        elseif ($total -eq 0) {
            return @()
        }
    }
    elseif ($Range -match '^(\d+)\.\.(\d+)$') {
        # Range: "1..10" -> files 1 to 10
        $start = [int]$Matches[1] - 1
        $end = [int]$Matches[2] - 1

        # Cap the range to the available files instead of failing
        if ($end -ge $total) { $end = $total - 1 }
        if ($start -lt 0) { $start = 0 }

        if ($start -le $end -and $start -lt $total) {
            Write-Log "Filtering range: $($start+1) to $($end+1) (Total: $total)" "DEBUG"
            return $AllIds[$start..$end]
        }
        elseif ($total -eq 0) {
            return @()
        }
    }
    elseif ($Range -match '^(\d+)\+$') {
        # From index to end: "10+" -> from 10th to last
        $start = [int]$Matches[1] - 1
        if ($start -ge 0 -and $start -lt $total) {
            return $AllIds[$start..($total - 1)]
        }
        elseif ($total -eq 0) {
            return @()
        }
    }

    # Invalid range or no files in range, return all
    if ($total -gt 0) {
        Write-Log "Invalid ProcessRange '$Range', processing all files" "WARN"
    }
    return $AllIds
}

# Helper: Resolve duplicate destination by appending _1, _2, etc.
function Resolve-DuplicateName {
    param(
        [string]$DstName,
        [string]$DstDir,
        [array]$ExistingDsts
    )

    $ext = [System.IO.Path]::GetExtension($DstName)
    $nameOnly = [System.IO.Path]::GetFileNameWithoutExtension($DstName)
    $baseFullDst = "$($DstDir.TrimEnd('/'))/$DstName"

    # If no collisions, return as-is
    if ($ExistingDsts -notcontains $baseFullDst) {
        return @{ DstName = $DstName; FullDst = $baseFullDst }
    }

    # Collision detected: append _1, _2, etc.
    $i = 1
    while ($true) {
        $newName = "$nameOnly`_$i$ext"
        $newFullDst = "$($DstDir.TrimEnd('/'))/$newName"
        if ($ExistingDsts -notcontains $newFullDst) {
            return @{ DstName = $newName; FullDst = $newFullDst }
        }
        $i++
    }
}



function Test-Plan {
    try {
        # Analyze in-memory state instead of reloading JSON file
        $plan = $Global:State.PlannedActions

        if (-not $plan -or $plan.Count -eq 0) {
            Write-Log "No plan loaded for analysis." "WARN"
            return
        }

        Write-Log "=== PLAN ANALYSIS ===" "INFO"
        Write-Log "Total actions : $($plan.Count)" "INFO"

        # 1. Check for name collisions
        $duplicates = $plan.FullDst | Group-Object | Where-Object { $_.Count -gt 1 }
        if ($duplicates) {
            Write-Log "Collisions detected:" "ERROR"
            foreach ($d in $duplicates) {
                Write-Log " - $($d.Name) ($($d.Count) occurrences)" "ERROR"
            }
        }
        else {
            Write-Log "No collisions detected." "SUCCESS"
        }

        # 2. Check for overly long paths
        $tooLong = $plan | Where-Object { $_.FullDst.Length -gt 250 }
        if ($tooLong) { Write-Log "Paths > 250 characters: $($tooLong.Count)" "INFO" }

        Write-Log "Analysis complete." "SUCCESS"
    }
    catch {
        Write-Log "Test-Plan error : $($_.Exception.Message)" "ERROR"
    }
} # Test-Plan


function Debug-File {
    param(
        [string]$Id
    )
    try {
        if (-not $Global:State.Cache) {
            Write-Log "Cache not loaded." "ERROR"
            return
        }

        if (-not $Global:State.Cache.Files.ContainsKey($Id)) {
            Write-Log "ID not found in cache." "ERROR"
            return
        }

        $f = $Global:State.Cache.Files[$Id]

        Write-Log "=== DEBUG FILE $Id ===" "INFO"
        Write-Log "Path : $($f.p)" "INFO"
        Write-Log "Nom    : $($f.n)" "INFO"
        Write-Log "Date   : $($f.d)" "INFO"
        Write-Log "GPS    : $($f.GPS)" "INFO"
        Write-Log "Camera : $($f.cam)" "INFO"
        Write-Log "========================" "INFO"

    }
    catch {
        Write-Log "Invoke-Moves error: $($_.Exception.Message)" "ERROR"
        throw
    }

} # Debug-File

function Start-DryRun {
    try {
        Write-Log "=== MODE DRY-RUN ===" "INFO"

        Test-Plan

        Write-Log "No move will be performed." "WARN"
        Write-Log "You can now run with: -Execute `$true" "INFO"

    }
    catch {
        Write-Log "Invoke-Moves error: $($_.Exception.Message)" "ERROR"
        throw
    }
} # Start-DryRun

function Repair-Cache {
    Write-Log "=== FIX CACHE: Automatic OneDrive cache cleanup ===" "WARN"

    try {
        $removed = 0
        $fixedExt = 0

        foreach ($id in $Global:State.Cache.Files.Keys) {
            $f = $Global:State.Cache.Files[$id]

            # Remove invalid entries
            if (-not $f.n -or -not $f.p) {
                $Global:State.Cache.Files.Remove($id)
                $removed++
                continue
            }

            # Fix extension mismatch (case-insensitive)
            $ext = [System.IO.Path]::GetExtension($f.n).ToLower()

            # Only fix if extension is KNOWN and different
            if ($Config.ExtensionMap.ContainsKey($ext) -and $ext -ne $f.ext) {
                $f.ext = $ext
                $fixedExt++
            }

            # Ensure boolean flags are properly typed to avoid binding errors during analysis
            $f.ani = [bool]$f.ani
            $f.isCameraVideo = [bool]$f.isCameraVideo
        }

        Write-Log "Fix complete: $removed entries removed, $fixedExt extensions corrected." "SUCCESS"

        # SAFE WRITE
        try {
            $tmp = "$Global:IndexFile.tmp"

            $Global:State.Cache |
            ConvertTo-Json -Depth 10 |
            Set-Content $tmp -ErrorAction Stop

            Move-Item -Force $tmp $Global:IndexFile
        }
        catch {
            Write-Log "Repair-Cache write error: $($_.Exception.Message)" "ERROR"
        }
    }
    catch {
        Write-Log "Repair-Cache error : $($_.Exception.Message)" "ERROR"
    }
}

function Repair-Paths {
    Write-Log "Repair-Paths: skip (logic handled by Repair-Cache)" "DEBUG"
}

function Repair-Names {
    Write-Log "Repair-Names: skip (logic handled by Repair-Cache)" "DEBUG"
}

function Repair-Collisions {
    Write-Log "=== FIX COLLISIONS: Resolving name conflicts in plan ===" "INFO"

    $plan = $Global:State.PlannedActions
    if (-not $plan -or $plan.Count -eq 0) { return }

    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($action in $plan) {
        if ($seen.Contains($action.FullDst)) {
            $resolved = Resolve-DuplicateName -DstName $action.DstName -DstDir $action.DstDir -ExistingDsts @($seen)
            $action.DstName = $resolved.DstName
            $action.FullDst = $resolved.FullDst
        }
        $null = $seen.Add($action.FullDst)
    }
}


function Repair-GPS {
    # Supprime les coordonnees GPS invalides ou corrompues.
    try {
        Write-Log "=== FIX GPS: Clean invalid GPS entries ===" "WARN"

        foreach ($entry in $Global:State.Cache.Files.GetEnumerator()) {
            $f = $entry.Value

            if ($f.GPS) {
                $lat = $f.GPS.lat
                $lon = $f.GPS.lon

                if ($lat -lt -90 -or $lat -gt 90 -or $lon -lt -180 -or $lon -gt 180) {
                    $f.GPS = $null
                }
            }
        }

        Write-Log "GPS cleanup complete." "SUCCESS"
    }
    catch {
        Write-Log "Repair-GPS error : $($_.Exception.Message)" "ERROR"
    }
} # Repair-GPS

# ============================================================
# INITIALISATION
# ============================================================
try {
    Write-Log "OneDriveCacheUtils.psm1 loaded" "DEBUG"
}
catch {
    # Safe fallback during module load if Write-Log isn't ready
    Write-Host "[DEBUG] OneDriveCacheUtils.psm1 initialized"
}

# ============================================================
# EXPORT
# ============================================================
Export-ModuleMember -Function *
