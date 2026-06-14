# =====================================================================
# Remove-AnimatedProcessedIds.ps1
# This script removes IDs of animated files from processed_ids.log
# so they can be reprocessed by OneDrive_PictureMovieOrganiser.ps1.
# =====================================================================

param (
    [string]$ConfigFile = ".\config.ini" # Application configuration
)

# --- Force Write-Progress display
$ProgressPreference = 'Continue'
Clear-Host

# =====================================================================
# GLOBAL CONFIGURATION (PLACED BEFORE MODULES)
# =====================================================================

Import-Module "$PSScriptRoot\modules\AppConfig.psm1" -Force
$app = Get-AppConfiguration -ConfigFile $ConfigFile

$global:IndexFile = $app.IndexFile
$global:TokenFile = $app.TokenFile
$global:LogFile = $app.OrganizerLogFile # Using organizer log for this script
$global:OrganizerLogFile = $app.OrganizerLogFile
$global:ProcessedLog = $app.ProcessedLog
$global:ExecutionReport = $app.ExecutionReport
$GpsCacheFile = $app.GpsCacheFile

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
# GLOBAL STATE (minimal for this script)
# =====================================================================

$Global:State = @{
    Headers         = $null
    Cache           = $null
    ProcessedIds    = @{} # This will be populated by Import-Set-Cache
    PlannedActions  = New-Object System.Collections.Generic.List[PSCustomObject]
    FilesToProcess  = @{}
    VerifiedFolders = @{}
}

# =====================================================================
# MAIN LOGIC
# =====================================================================

Write-Log "=== STARTING ANIMATED FILES CLEANUP ===" "INFO"

try {
    # 1. Load existing cache and processed IDs
    Import-Set-Cache # This populates $Global:State.Cache and $Global:State.ProcessedIds

    $initialProcessedCount = $Global:State.ProcessedIds.Count
    Write-Log "Initial processed_ids.log entries: $initialProcessedCount" "INFO"

    $idsToRemove = New-Object System.Collections.Generic.List[string]

    # 2. Identify animated files among processed IDs
    foreach ($id in $Global:State.ProcessedIds.Keys) {
        if ($Global:State.Cache.Files.ContainsKey($id)) {
            $fileMeta = $Global:State.Cache.Files[$id]
            if ($fileMeta.ani) {
                $idsToRemove.Add($id)
                Write-Log "Identified animated file to remove from processed_ids.log: $($fileMeta.n) (ID: $id)" "DEBUG"
            }
        }
        else {
            Write-Log "Warning: Processed ID '$id' not found in OneDrive cache. Skipping." "WARN"
        }
    }

    # 3. Remove identified IDs from ProcessedIds
    foreach ($id in $idsToRemove) {
        $Global:State.ProcessedIds.Remove($id)
    }

    $finalProcessedCount = $Global:State.ProcessedIds.Count
    $removedCount = $idsToRemove.Count

    Write-Log "Removed $removedCount animated file IDs from processed_ids.log." "SUCCESS"
    Write-Log "Final processed_ids.log entries: $finalProcessedCount" "INFO"

    # 4. Save the updated processed IDs list
    Save-ProcessedIds # This rewrites the processed_ids.log file

    Write-Log "Animated files cleanup completed." "SUCCESS"

}
catch {
    Write-Log "FATAL ERROR during animated files cleanup: $($_.Exception.Message)" "ERROR"
    Write-Log "Details: $($_.ScriptStackTrace)" "DEBUG"
}

Write-Log "=== SCRIPT END ===" "INFO"
