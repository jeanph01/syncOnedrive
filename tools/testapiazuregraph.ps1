# ============================================================
# ONEDRIVE INDEXER V12.1 - FOCUS EXCLUSIF (FORCE)
# ============================================================
$ClientId = "176fc7bc-42c9-4a25-82b5-0ad584d3c061"
$IndexFile = ".\onedrive_cache.json"

# ID spécifique du dossier 'ensemble' que nous avons identifié
$TargetID = "440B3E9A717E6203!130354" 

# --- CHARGEMENT DE L'INDEX EXISTANT ---
if (Test-Path $IndexFile) {
    $script:Cache = Get-Content $IndexFile | ConvertFrom-Json -AsHashtable
    Write-Host "Index existant chargé : $($script:Cache.Files.Count) fichiers." -ForegroundColor Cyan
} else {
    $script:Cache = @{ Files = @{} }
}

# --- AUTH --- (On réutilise la méthode DeviceCode)
$DeviceCode = Invoke-RestMethod -Method POST -Uri "https://login.microsoftonline.com/common/oauth2/v2.0/devicecode" -Body @{ client_id = $ClientId; scope = "Files.Read.All" }
Write-Host "`n$($DeviceCode.message)" -ForegroundColor Yellow
$Auth = $null; while (!$Auth) { Start-Sleep 5; try { $Auth = Invoke-RestMethod -Method POST -Uri "https://login.microsoftonline.com/common/oauth2/v2.0/token" -Body @{ grant_type = "urn:ietf:params:oauth:grant-type:device_code"; client_id = $ClientId; device_code = $DeviceCode.device_code } } catch {} }
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
                    Write-Host " -> Dossier Photos : $PathName/$($item.name) (Total index : $($script:Cache.Files.Count))" -ForegroundColor Gray
                    Get-OneDriveDeepFocus -FolderId $item.id -PathName "$PathName/$($item.name)"
                }
            }
            $Uri = $Dir.'@odata.nextLink'
        } catch { $Uri = $null }
    }
}

# --- ACTION ---
Write-Host "Ciblage forcé sur le dossier 'ensemble'..." -ForegroundColor Green
Get-OneDriveDeepFocus -FolderId $TargetID -PathName "ENSEMBLE"

# Sauvegarde
$script:Cache | ConvertTo-Json -Depth 10 | Set-Content $IndexFile
Write-Host "`nTerminé. Nouvel index global : $($script:Cache.Files.Count) fichiers." -ForegroundColor Green