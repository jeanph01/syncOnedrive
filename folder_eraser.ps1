# =====================================================================
# OneDrive Folder Eraser — Empty folder cleanup utility
# - Uses Delta API for high-performance structure mapping
# - Bottom-up deletion strategy (handles nested empty folders)
# - Integrated with existing config and authentication
# - Safety-first: Defaults to Dry-Run mode
# =====================================================================

param (
    [bool]$Execute = $false,                          # Actually performs the deletions
    [string]$ConfigFile = ".\config.ini"            # Application configuration
)

# --- Force Write-Progress display
$ProgressPreference = 'Continue'
Clear-Host

# =====================================================================
# GLOBAL CONFIGURATION & MODULES
# =====================================================================

Import-Module "$PSScriptRoot\modules\AppConfig.psm1" -Force
$app = Get-AppConfiguration -ConfigFile $ConfigFile

# Setup globals required by modules
$global:IndexFile = $app.IndexFile
$global:TokenFile = $app.TokenFile
$global:LogFile = Join-Path (Split-Path $app.OrganizerLogFile -Parent) "folder_eraser.log"
$Global:Rules = $app.Rules

$Config = [PSCustomObject]@{
    ClientId = $app.ClientId
}

# Import core tools
Import-Module "$PSScriptRoot\modules\OneDriveTools.psm1" -ArgumentList $Config.ClientId, $global:TokenFile, $global:LogFile -Force

# =====================================================================
# GLOBAL STATE
# =====================================================================

# Initialize the global state object used by modules (specifically for Headers and Graph API calls)
$Global:State = @{
    Headers         = $null
    Cache           = $null
    ProcessedIds    = @{}
    PlannedActions  = New-Object System.Collections.Generic.List[PSCustomObject]
    FilesToProcess  = @{}
    VerifiedFolders = @{}
}

# =====================================================================
# CORE LOGIC
# =====================================================================

function Start-FolderEraser {
    Write-Log "=== FOLDER ERASER START: $(Get-Date) ===" "INFO"

    if (-not $Execute) {
        Write-Log "MODE: DRY-RUN (No folders will be deleted). Use -Execute `$true to apply changes." "WARN"
    }
    else {
        Write-Log "MODE: EXECUTION (Empty folders will be PERMANENTLY deleted)." "WARN"
    }

    try {
        # 1. Authenticate
        Connect-AzureGraph

        # 2. Fetch all items to build the tree
        Write-Log "Scanning OneDrive structure..." "INFO"
        $items = @{}         # ID -> Item Object
        $childCounts = @{}   # ID -> Count of children (files or folders)
        $folders = @()       # List of folder objects

        $uri = "<https://graph.microsoft.com/v1.0/me/drive/root/delta>?`$select=id,name,parentReference,folder"
        $page = 1

        while ($uri) {
            Write-Progress -Activity "Scanning OneDrive" -Status "Fetching page $page..."
            $response = Invoke-RestMethod -Headers $Global:State.Headers -Uri $uri -Method Get

            foreach ($item in $response.value) {
                # Skip deleted items
                if ($item.deleted) { continue }

                $items[$item.id] = $item

                # Track parent-child relationship
                if ($item.parentReference -and $item.parentReference.id) {
                    $parentId = $item.parentReference.id
                    if (-not $childCounts.ContainsKey($parentId)) { $childCounts[$parentId] = 0 }
                    $childCounts[$parentId]++
                }

                # Identify folders (excluding root)
                if ($item.folder -and $item.name -ne "root") {
                    $folders += $item
                }
            }

            $uri = $response.'@odata.nextLink'
            $page++
        }
        Write-Progress -Activity "Scanning OneDrive" -Completed
        Write-Log "Scan complete. Found $($folders.Count) folders." "SUCCESS"

        # 3. Calculate Path Depths
        # We need to delete deepest folders first so parents become empty
        Write-Log "Calculating folder depths..." "INFO"
        $sortedFolders = $folders | ForEach-Object {
            $depth = 0
            if ($_.parentReference -and $_.parentReference.path) {
                $depth = ($_.parentReference.path -split '/').Count
            }
            $_ | Add-Member -MemberType NoteProperty -Name "Depth" -Value $depth -PassThru
        } | Sort-Object Depth -Descending

        # 4. Processing
        $deletedCount = 0
        $skippedCount = 0
        $index = 0
        $total = $sortedFolders.Count

        foreach ($folder in $sortedFolders) {
            $index++
            $folderId = $folder.id
            $folderName = $folder.name
            $folderPath = if ($folder.parentReference.path) { "$($folder.parentReference.path)/$folderName" } else { "/$folderName" }

            Write-Progress -Activity "Cleaning folders" `
                -Status "Checking: $folderName" `
                -PercentComplete (($index / $total) * 100)

            # Check if current folder has any children
            # Note: We check our live $childCounts map which we update as we go
            $currentCount = if ($childCounts.ContainsKey($folderId)) { $childCounts[$folderId] } else { 0 }

            if ($currentCount -eq 0) {
                if ($Execute) {
                    try {
                        Write-Log "Deleting empty folder: $folderPath" "INFO"

                        $deleteUri = "https://graph.microsoft.com/v1.0/me/drive/items/$folderId"
                        Invoke-RestMethod -Headers $Global:State.Headers -Uri $deleteUri -Method DELETE

                        $deletedCount++

                        # Update parent's count so the parent can potentially be deleted too
                        if ($folder.parentReference -and $folder.parentReference.id) {
                            $parentId = $folder.parentReference.id
                            if ($childCounts.ContainsKey($parentId)) {
                                $childCounts[$parentId]--
                            }
                        }
                    }
                    catch {
                        $err = Get-ErrorDetails $_
                        Write-Log "Failed to delete $folderPath : $err" "ERROR"
                        $skippedCount++
                    }
                }
                else {
                    Write-Log "[DRY-RUN] Would delete empty folder: $folderPath" "INFO"
                    $deletedCount++

                    # In dry run, we still simulate the count decrease to show nested empty folders
                    if ($folder.parentReference -and $folder.parentReference.id) {
                        $parentId = $folder.parentReference.id
                        if ($childCounts.ContainsKey($parentId)) {
                            $childCounts[$parentId]--
                        }
                    }
                }
            }
        }

        Write-Progress -Activity "Cleaning folders" -Completed

        Write-Host "`n"
        Write-Log "=== CLEANUP SUMMARY ===" "SUCCESS"
        if ($Execute) {
            Write-Log "Folders deleted: $deletedCount" "SUCCESS"
            if ($skippedCount -gt 0) { Write-Log "Folders skipped (errors): $skippedCount" "ERROR" }
        }
        else {
            Write-Log "Folders identified for deletion: $deletedCount" "INFO"
        }

    }
    catch {
        Write-Log "FATAL ERROR in FolderEraser: $($_.Exception.Message)" "ERROR"
        if ($_.ScriptStackTrace) { Write-Log "Stack: $($_.ScriptStackTrace)" "DEBUG" }
    }

    Write-Log "=== SESSION END ===" "INFO"
}

# Execute the script
Start-FolderEraser
