# ============================================================
# ONEDRIVE INDEXER V12.1 - FOCUSED TEST SCRIPT
# ============================================================
$ClientId = "176fc7bc-42c9-4a25-82b5-0ad584d3c061"
$IndexFile = ".\onedrive_cache.json"

# Specific folder ID used for focused traversal
$TargetID = "440B3E9A717E6203!130354"

# --- LOAD EXISTING INDEX ---
if (Test-Path $IndexFile) {
    $script:Cache = Get-Content $IndexFile | ConvertFrom-Json -AsHashtable
    Write-Host "Existing index loaded: $($script:Cache.Files.Count) files." -ForegroundColor Cyan
} else {
    $script:Cache = @{ Files = @{} }
}

# --- AUTH --- (Reusing device code flow)
$DeviceCode = Invoke-RestMethod -Method POST -Uri "https://login.microsoftonline.com/common/oauth2/v2.0/devicecode" -Body @{ client_id = $ClientId; scope = "Files.Read.All" }
Write-Host "`n$($DeviceCode.message)" -ForegroundColor Yellow
$Auth = $null
while (!$Auth) {
    Start-Sleep 5
    try {
        $Auth = Invoke-RestMethod -Method POST -Uri "https://login.microsoftonline.com/common/oauth2/v2.0/token" -Body @{ grant_type = "urn:ietf:params:oauth:grant-type:device_code"; client_id = $ClientId; device_code = $DeviceCode.device_code }
    }
    catch {}
}
$Headers = @{ Authorization = "Bearer $($Auth.access_token)" }

function Get-OneDriveDeepFocus {
    param ($FolderId, $PathName)
    $Uri = "https://graph.microsoft.com/v1.0/me/drive/items/$FolderId/children?`$top=999"
    
    while ($Uri) {
        try {
            $Dir = Invoke-RestMethod -Headers $Headers -Uri $Uri -Method GET
            foreach ($item in $Dir.value) {
                if ($item.file) {
                    $script:Cache.Files[$item.id] = $item
                } elseif ($item.folder) {
                    Write-Host " -> Photos folder: $PathName/$($item.name) (Total index: $($script:Cache.Files.Count))" -ForegroundColor Gray
                    Get-OneDriveDeepFocus -FolderId $item.id -PathName "$PathName/$($item.name)"
                }
            }
            $Uri = $Dir.'@odata.nextLink'
        } catch {
            $Uri = $null
        }
    }
}

# --- ACTION ---
Write-Host "Forced targeting of the 'ensemble' folder..." -ForegroundColor Green
Get-OneDriveDeepFocus -FolderId $TargetID -PathName "ENSEMBLE"

# Save index
$script:Cache | ConvertTo-Json -Depth 10 | Set-Content $IndexFile
Write-Host "`nDone. New global index: $($script:Cache.Files.Count) files." -ForegroundColor Green