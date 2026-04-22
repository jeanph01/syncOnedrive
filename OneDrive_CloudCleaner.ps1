# ============================================================
# ONEDRIVE CLOUD CLEANER - GRAPH DUPLICATE REMOVAL
# ============================================================

param(
    [string]$ConfigFile = ".\config.ini"
)

Clear-Host

Import-Module "$PSScriptRoot\modules\AppConfig.psm1" -Force
$app = Get-AppConfiguration -ConfigFile $ConfigFile
$Global:Rules = $app.Rules
$IndexFile = $app.IndexFile
$ClientId = $app.ClientId
$TokenFile = $app.TokenFile
$LogFile = $app.CloudCleanerLogFile

# Load shared utilities
Import-Module ".\modules\OneDriveTools.psm1" -ArgumentList $ClientId, $TokenFile, $LogFile -Force

Write-Log "=== ONEDRIVE CLOUD CLEANER ==="

# Load cache
if (!(Test-Path $IndexFile)) {
    Write-Log "ERROR: Cache not found."
    exit 1
}

$Cache = ConvertFrom-JsonOptimized -JsonString (Get-Content $IndexFile -Raw) -AsHashtable
Write-Log "Cache loaded: $($Cache.Files.Count) files"

# Authenticate
Write-Log "[1/3] Connecting to Microsoft Graph..."
$Auth = Get-GraphToken
$Headers = @{ Authorization = "Bearer $($Auth.access_token)" }

# Group by hash
Write-Log "[2/3] Grouping duplicate candidates..."

$HashGroups = @{}

foreach ($id in $Cache.Files.Keys) {
    $item = $Cache.Files[$id]

    if ($null -eq $item) { continue }
    if (-not $item.ContainsKey("h")) { continue }
    if ([string]::IsNullOrWhiteSpace($item.h)) { continue }

    $item.id = $id
    
    if (-not $HashGroups.ContainsKey($item.h)) {
        $HashGroups[$item.h] = New-Object System.Collections.Generic.List[Object]
    }

    $HashGroups[$item.h].Add($item)
}

# Delete duplicates
Write-Log "[3/3] Removing duplicate cloud items..."

$count = 0

foreach ($hash in $HashGroups.Keys) {
    $group = $HashGroups[$hash]

    if ($group.Count -gt 1) {
        $sorted = $group | Sort-Object {
            $score = 100
            foreach ($rule in $Global:Rules.cleanerRules.priorityRules) {
                if ($rule.field -eq "name" -and $_.n -like $rule.pattern) {
                    $score += [int]$rule.score
                }
                elseif ($rule.field -eq "path" -and $_.p -like $rule.pattern) {
                    $score += [int]$rule.score
                }
            }
            $score
        }

        $ToKeep   = $sorted[0]
        $ToDelete = $sorted | Select-Object -Skip 1

        Write-Log "Group $hash → KEEP: $($ToKeep.p)/$($ToKeep.n)"

        foreach ($file in $ToDelete) {
            Write-Log "DEL: $($file.p)/$($file.n)"
            try {
                $deleteUri = "https://graph.microsoft.com/v1.0/me/drive/items/$($file.id)"
                Invoke-RestMethod -Headers $Headers -Uri $deleteUri -Method DELETE
                $count++
            }
            catch {
                Write-Log "Delete error: $($file.n)" "ERROR"
            }
        }
    }
}

Write-Log "[COMPLETE] $count duplicates deleted from OneDrive."
