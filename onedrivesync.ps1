# ============================================================
# ONEDRIVE BACKUP AUDIT AVEC HASHES COMPLETS ET MISE À JOUR PROGRESSIVE
# Compatible OneDrive Personal / Family
# ============================================================

# ---------------- CONFIGURATION ----------------
$LocalFolder       = "D:\recup\test"
$ClientId          = "176fc7bc-42c9-4a25-82b5-0ad584d3c061"
$TenantId          = "common"
$IndexFile         = ".\onedrive_index.json"
$DeltaTokenFile    = ".\onedrive_delta.token"
$ReportFolder      = ".\Reports"

if (!(Test-Path $ReportFolder)) { New-Item -ItemType Directory -Path $ReportFolder | Out-Null }
Clear-Host

# ---------------- AUTHENTICATION ----------------
Write-Host "Authenticating to Microsoft Graph..." -ForegroundColor Cyan

$Scopes = "offline_access openid Files.Read"

$DeviceCode = Invoke-RestMethod -Method POST `
    -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/devicecode" `
    -Body @{
        client_id = $ClientId
        scope     = $Scopes
    }

Write-Host $DeviceCode.message -ForegroundColor Yellow

do {
    Start-Sleep 5
    try {
        $Auth = Invoke-RestMethod -Method POST `
            -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" `
            -Body @{
                grant_type  = "urn:ietf:params:oauth:grant-type:device_code"
                client_id   = $ClientId
                device_code = $DeviceCode.device_code
            }
    } catch {}
} until ($Auth.access_token)

$AccessToken = $Auth.access_token
Write-Host "Authentication successful.`n" -ForegroundColor Green

# ---------------- LOAD CACHED INDEX ----------------
$OneDriveHashes = @{}
if (Test-Path $IndexFile) {
    Write-Host "Loading cached OneDrive index..."
    $OneDriveHashes = Get-Content $IndexFile | ConvertFrom-Json
}

# ---------------- DELTA OR FULL ----------------
if (Test-Path $DeltaTokenFile) {
    Write-Host "Running incremental DELTA sync..."
    $NextLink = Get-Content $DeltaTokenFile
} else {
    Write-Host "Running FULL OneDrive scan..."
    $NextLink = "https://graph.microsoft.com/v1.0/me/drive/root/delta?select=name,id,hashes,size,file"
}

$page = 0
while ($NextLink) {

    $page++

    try {
        $Response = Invoke-RestMethod -Headers @{Authorization = "Bearer $AccessToken"} -Uri $NextLink -Method GET
    } catch {
        Write-Host "Error reading OneDrive: $($_.Exception.Message)" -ForegroundColor Red
        break
    }

    $updatedThisPage = 0
    foreach ($item in $Response.value) {

        if ($item.deleted) {
            if ($item.id -and $OneDriveHashes.ContainsKey($item.id)) {
                $OneDriveHashes.Remove($item.id)
                $updatedThisPage++
            }
            continue
        }

        if ($item.file) {
            $hashEntry = @{}

            if ($item.hashes?.quickXorHash) { $hashEntry.quickXorHash = $item.hashes.quickXorHash }
            if ($item.hashes?.sha1Hash) { $hashEntry.sha1Hash = $item.hashes.sha1Hash.ToLower() }
            if ($item.hashes?.crc32Hash) { $hashEntry.crc32Hash = $item.hashes.crc32Hash }
            if ($hashEntry.Count -eq 0) { $hashEntry.fallback = "$($item.name.ToLower())|$($item.size)" }

            $OneDriveHashes[$item.id] = $hashEntry
            $updatedThisPage++
        }
    }

    # ---------------- UPDATE CACHE AND TOKEN AFTER EACH PAGE ----------------
    $OneDriveHashes | ConvertTo-Json | Set-Content $IndexFile
    if ($Response.'@odata.deltaLink') { $Response.'@odata.deltaLink' | Set-Content $DeltaTokenFile }

    Write-Progress `
        -Activity "Updating OneDrive cache" `
        -Status "Page $page | Updated items this page: $updatedThisPage | Total indexed: $($OneDriveHashes.Count)" `
        -PercentComplete 0

    $NextLink = $Response.'@odata.nextLink'
}

Write-Host "`nCloud index ready: $($OneDriveHashes.Count) files.`n" -ForegroundColor Green

# ---------------- LOCAL SCAN ----------------
Write-Host "Scanning local folder: $LocalFolder" -ForegroundColor Cyan
$LocalFiles = Get-ChildItem -Path $LocalFolder -File -Recurse
$total = $LocalFiles.Count
Write-Host "Total local files: $total`n"

$NotBackedUp = @()
$i = 0
foreach ($file in $LocalFiles) {
    $i++
    Write-Progress -Activity "Checking local files" -Status "$i / $total" -PercentComplete (($i / $total) * 100)

    $sha1 = (Get-FileHash $file.FullName -Algorithm SHA1).Hash.ToLower()
    $fallback = "$($file.Name.ToLower())|$($file.Length)"

    $found = $false
    foreach ($cloudFile in $OneDriveHashes.GetEnumerator()) {
        $hashObj = $cloudFile.Value

        if (($hashObj.sha1Hash -and $hashObj.sha1Hash -eq $sha1) -or
            ($hashObj.quickXorHash -and $hashObj.quickXorHash -eq $null) -or
            ($hashObj.crc32Hash -and $hashObj.crc32Hash -eq $null) -or
            ($hashObj.fallback -and $hashObj.fallback -eq $fallback)) {
            $found = $true
            break
        }
    }

    if (-not $found) {
        $NotBackedUp += [PSCustomObject]@{
            Path = $file.FullName
            Size = $file.Length
        }
    }
}

Write-Progress -Completed

# ---------------- STATISTICS ----------------
Write-Host "`n===== BACKUP AUDIT =====" -ForegroundColor Cyan
$TotalLocalSize = ($LocalFiles | Measure-Object Length -Sum).Sum
$NotBackedSize  = ($NotBackedUp | Measure-Object Size -Sum).Sum
$TotalGB = [math]::Round($TotalLocalSize / 1GB, 2)
$RiskGB  = [math]::Round($NotBackedSize / 1GB, 2)
$Coverage = 100 - (($NotBackedUp.Count / $LocalFiles.Count) * 100)

Write-Host "Local files scanned       : $($LocalFiles.Count)"
Write-Host "Files NOT in OneDrive     : $($NotBackedUp.Count)"
Write-Host "Size NOT in OneDrive      : $RiskGB GB"
Write-Host "Backup coverage           : $([math]::Round($Coverage,2)) %"

# ---------------- EXPORT CSV ----------------
$Report = Join-Path $ReportFolder ("backup_report_$(Get-Date -Format yyyyMMdd_HHmm).csv")
$NotBackedUp | Export-Csv $Report -NoTypeInformation
Write-Host "`nReport saved: $Report" -ForegroundColor Yellow

Write-Host "`nAudit complete." -ForegroundColor Green