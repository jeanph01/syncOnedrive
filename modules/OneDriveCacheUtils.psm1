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


# =====================================================================
# REPRISE AUTOMATIQUE
# =====================================================================

# Load existing plan if cache hash matches
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
            Write-Log "Plan existant valide - reprise sans analyse." "SUCCESS"
            return (Get-Content $planFile -Raw | ConvertFrom-Json)
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

        Write-Log "Loading OneDrive cache $IndexFile ..."
        if (!(Test-Path $IndexFile)) {
            Write-Log "Cache not found: $IndexFile" "ERROR"
            exit 1
        }

        $Global:State.Cache = Get-Content $IndexFile -Raw | ConvertFrom-Json -AsHashtable

        if (-not $Global:State.Cache.Files) {
            Write-Log "No files in cache." "ERROR"
            exit 1
        }

        Write-Log "Loading already processed IDs ($ProcessedLog) ..."
        $Global:State.ProcessedIds = @{}
        $Global:State.FilesToProcess = @{}

        if (Test-Path $ProcessedLog) {
            Get-Content $ProcessedLog | ForEach-Object {
                $id = $_.Trim()
                if ($id) { $Global:State.ProcessedIds[$id] = $true }
            }
            Write-Log "Already processed files : $($Global:State.ProcessedIds.Count)"
        }
        else {
            Write-Log "No previously processed files (file $ProcessedLog missing)."
        }

        Write-Log "Discovering already processed files containing marker '$($Config.RenameMarker)' ..."
        $index = 0
        $total = $Global:State.Cache.Files.Count
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
                Write-Log "Ignored (already processed): $id" "DEBUG"
                continue
            }
            # b) Si le nom contient le marqueur => l'ajouter a ProcessedIds
            if ($fileMeta.n -like "*$($Config.RenameMarker)*") {
                Write-Log "Added to ProcessedIds (already renamed): $($fileMeta.p)/$($fileMeta.n)" "DEBUG"
                $Global:State.ProcessedIds[$id] = $true
                continue
            }

            # c) Otherwise → file to process
            $Global:State.FilesToProcess[$id] = $fileMeta
        }

        Write-Progress -Activity "Analysis completed" -Completed
        Write-Log "Indexing complete. Files to process: $($Global:State.FilesToProcess.Count)"
        "Timestamp,ID,Status,OldPath,NewPath,Error" | Set-Content $ExecutionReport
    }
    catch {
        Write-Log "Import-Set-Cache error : $($_.Exception.Message)" "ERROR"
        throw
    }
} # Import-Set-Cache

# =====================================================================
# MERGED PIPELINE: ANALYSIS + PROGRESS BAR + PLAN
# =====================================================================

# Analyze files and build relocation plan
function New-Plan {
    Write-Log "Scanning files (merged pipeline)..."

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
                    Write-Log "Progress save error : $($_.Exception.Message)" "ERROR"
                }
            }

            Write-Log "----------------------------------------------" "DEBUG"
            Write-Log "Analyzing file" "DEBUG"
            Write-Log "ID             : $fileId" "DEBUG"
            Write-Log "Original name   : $($fileMeta.n)" "DEBUG"
            Write-Log "Source path     : $($fileMeta.p)" "DEBUG"
            Write-Log "Extension      : $extension" "DEBUG"
            Write-Log "File date      : $($fileMeta.d)" "DEBUG"
            Write-Log "GPS            : $($fileMeta.GPS)" "DEBUG"

            # Classification
            $category = Get-SmartCategory -Path $fileMeta.p -Extension $extension
            Write-Log "Smart classification = ($category)" "DEBUG"

            if (-not $Config.ExtensionMap.ContainsKey($extension)) {
                Write-Log "Ignored: unsupported extension ($extension)" "DEBUG"
                continue
            }

            $fileDate = [DateTime]$fileMeta.d

            # GPS
            $GPSLocation = $null
            if ($fileMeta.GPS) {
                $GPSLocation = Get-LocationName $fileMeta.GPS
                Write-Log "GPS location : $GPSLocation" "DEBUG"
            }

            # Tags
            $pathTags = Get-PathTags $fileMeta.p
            Write-Log "Tags de Path : $pathTags" "DEBUG"

            # Camera
            $camera = $fileMeta.cam

            # Source hint
            $sourceHint = ""
            foreach ($hint in $Global:Rules.routingRules.sourceHints) {
                if ($fileMeta.p -match [Regex]::Escape($hint)) {
                    $sourceHint = $hint
                    break
                }
            }

            # Nouveau nom
            $originalNameNoExt = [System.IO.Path]::GetFileNameWithoutExtension($fileMeta.n)
            if ([string]::IsNullOrWhiteSpace($originalNameNoExt)) {
                Write-Log "Empty filename, skipping file: $($fileMeta.p)/$($fileMeta.n)" "WARN"
                continue
            }

            $newName = New-SmartFileName `
                -DateRef      $fileDate `
                -OriginalName $originalNameNoExt `
                -Extension    $extension `
                -GPSLocation  $GPSLocation `
                -PathTags     $pathTags `
                -Camera       $camera `
                -SourceHint   $sourceHint

            Write-Log "Generated new name: $newName" "DEBUG"
            # Destination
            $dest = Get-DestinationPath `
                -Category     $category `
                -FileMeta     $fileMeta `
                -Extension    $extension `
                -ExtensionMap $Config.ExtensionMap `
                -NewName      $newName `
                -FileDate     $fileDate

            Write-Log "Destination path = ($($dest.CleanDestination))" "DEBUG"
            $cleanDestination = $dest.CleanDestination
            $fullDestination = $dest.FullDestination

            # Verification si deja a la bonne place
            $srcDirClean = $fileMeta.p -replace "^/drive/root:", ""
            $currentPath = "$($srcDirClean.Trim('/'))/$($fileMeta.n)"

            if ($currentPath -eq $fullDestination.Trim('/')) {
                Write-Log "Already in correct place: $($fileMeta.n)" "DEBUG"
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

        Write-Log "Plan generated: $($Global:State.PlannedActions.Count) files." "SUCCESS"
        # Save JSON plan
        try {
            $cacheFolder = Split-Path $IndexFile -Parent
            $planFile = Join-Path $cacheFolder "plan.json"
            $Global:State.PlannedActions | ConvertTo-Json -Depth 10 | Set-Content $planFile
            Write-Log "Plan saved to $planFile" "SUCCESS"
        }
        catch {
            Write-Log "Error saving plan : $($_.Exception.Message)" "ERROR"
        }
    }
    catch {
        Write-Log "New-Plan error : $($_.Exception.Message)" "ERROR"
        throw
    }
} # New-Plan



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
    try {
        Write-Log "=== FIX CACHE: Automatic OneDrive cache cleanup ===" "WARN"

        $cache = $Global:State.Cache.Files
        $removed = 0
        $fixedExt = 0

        # Extract keys into fixed array to avoid enumeration error
        $keys = @($cache.Keys)

        foreach ($id in $keys) {
            $f = $cache[$id]

            # Supprimer les entrees sans Path ou nom
            if (-not $f.p -or -not $f.n) {
                $cache.Remove($id)
                $removed++
                continue
            }

            # Supprimer les Paths invalides
            if ($f.p -notmatch "^/drive/root:") {
                $cache.Remove($id)
                $removed++
                continue
            }

            # Corriger les extensions polluees (ex: .jpg?width=...)
            $ext = [IO.Path]::GetExtension($f.n).ToLower()
            $cleanExt = $ext -replace '\?.*$','' -replace '\&.*$',''

            if ($ext -ne $cleanExt) {
                $f.n = $f.n.Replace($ext, $cleanExt)
                $fixedExt++
            }

            # Remove unknown extensions
            if (-not $Config.ExtensionMap.ContainsKey($cleanExt)) {
                $cache.Remove($id)
                $removed++
                continue
            }
        }

        Write-Log "Fix complete: $removed entries removed, $fixedExt extensions corrected." "SUCCESS"
        $Global:State.Cache | ConvertTo-Json -Depth 10 | Set-Content $IndexFile
    }
    catch {
        Write-Log "Repair-Cache error : $($_.Exception.Message)" "ERROR"
    }
}

function Repair-Collisions {
    try {
        Write-Log "=== FIX COLLISIONS: Proactive resolution ===" "WARN"
        
        # On travaille directement sur la liste en memoire
        $groups = $Global:State.PlannedActions | Group-Object FullDst | Where-Object { $_.Count -gt 1 }

        if (-not $groups) {
            Write-Log "No collisions detected." "SUCCESS"
            return
        }

        foreach ($g in $groups) {
            # The first file keeps its name, the following ones are indexed
            for ($i = 1; $i -lt $g.Count; $i++) {
                $item = $g.Group[$i]
                $ext = [System.IO.Path]::GetExtension($item.DstName)
                $nameOnly = [System.IO.Path]::GetFileNameWithoutExtension($item.DstName)
                
                # Mise a jour du nom et du Path complet de destination
                $item.DstName = "$nameOnly`_$i$ext"
                $item.FullDst = "$($item.DstDir.TrimEnd('/'))/$($item.DstName)"
            }
        }

        # Save the modified plan to disk immediately
        $planFile = Join-Path (Split-Path $IndexFile -Parent) "plan.json"
        $Global:State.PlannedActions | ConvertTo-Json -Depth 10 | Set-Content $planFile

        Write-Log "Collisions resolved and plan synced to disk." "SUCCESS"
    }
    catch {
        Write-Log "Repair-Collisions error : $($_.Exception.Message)" "ERROR"
    }
}


function Repair-Paths {
    # Normalise les Paths OneDrive (double slash, espaces, caracteres invalides).
    try {
        Write-Log "=== FIX PATHS : Normalize paths ===" "WARN"

        foreach ($entry in $Global:State.Cache.Files.GetEnumerator()) {
            $f = $entry.Value

            if ($f.p) {
                $clean = $f.p -replace "//+", "/" -replace "\s+", "_"
                if ($clean -ne $f.p) {
                    $f.p = $clean
                }
            }
        }

        Write-Log "Path normalization complete." "SUCCESS"
    }
    catch {
        Write-Log "Repair-Paths error : $($_.Exception.Message)" "ERROR"
    }
} # Repair-Paths

function Repair-Names {
    # Corrige les noms invalides (espaces, caracteres interdits, noms trop longs).
    try {
        Write-Log "=== FIX NAMES : Normalize names ===" "WARN"

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

        Write-Log "Name normalization complete." "SUCCESS"
    }
    catch {
        Write-Log "Repair-Names error : $($_.Exception.Message)" "ERROR"
    }
} # Repair-Names


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
function main {
    try {      
        if ($script:ModuleLoaded) {
            Write-Log "OneDriveCacheUtils.psm1 already loaded -> import ignored" "DEBUG"
            return
        }
        $script:ModuleLoaded = $true

        Write-Log "OneDriveCacheUtils.psm1 loaded"

    }
    catch {
        Write-Log "Failure: $_" "ERROR"
    }
} # main


main
# ============================================================
# EXPORT
# ============================================================
Export-ModuleMember -Function *

