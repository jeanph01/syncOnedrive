# ================================
# CONFIGURATION
# ================================
$LocalFolder = "D:\recup\test"
# Use the app registration for personal accounts and the consumer tenant
# (created earlier: syncOnedrive-personal)
$ClientId = "53dc372d-26e4-46f8-b999-74bcdbe1d1e2"
$TenantId = "consumers"

clear-host

# ================================
# AUTHENTICATION
# ================================
Write-Host "Authenticating to Microsoft Graph..."
## Request openid/offline_access so we can get refresh tokens if needed
$Scopes = "offline_access openid Files.Read"

# Using device-code flow below; removed incorrect immediate token request.

# Device code flow step 1
$DeviceCode = Invoke-RestMethod -Method POST -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/devicecode" `
    -Body @{
        client_id = $ClientId
        scope     = $Scopes
    }

Write-Host $DeviceCode.message

# Poll until authenticated, respecting server-provided interval and expiry
$interval = if ($DeviceCode.interval) { $DeviceCode.interval } else { 5 }
$expiresAt = (Get-Date).AddSeconds($DeviceCode.expires_in)

do {
    Start-Sleep -Seconds $interval
    try {
        $Auth = Invoke-RestMethod -Method POST -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" `
            -Body @{
                grant_type = "urn:ietf:params:oauth:grant-type:device_code"
                client_id  = $ClientId
                device_code = $DeviceCode.device_code
            }
    } catch {
        # Try to extract the error body for better diagnostics across PS versions
        $err = $_.Exception
        $resp = $err.Response
        $body = $null
        if ($resp) {
            try {
                if ($resp -is [System.Net.Http.HttpResponseMessage]) {
                    $body = $resp.Content.ReadAsStringAsync().Result
                } else {
                    $sr = New-Object System.IO.StreamReader($resp.GetResponseStream())
                    $body = $sr.ReadToEnd()
                }
            } catch {
                $body = $null
            }

            if ($body) {
                try {
                    $json = $body | ConvertFrom-Json
                    if ($json.error -and $json.error -ne 'authorization_pending') {
                        Write-Host "Token request error: $($json.error) - $($json.error_description)"
                    } else {
                        Write-Host "Waiting for user to authenticate..."
                    }
                } catch {
                    Write-Host "Waiting for user to authenticate..."
                }
            } else {
                Write-Host "Waiting for user to authenticate..."
            }
        } else {
            Write-Host "Waiting for user to authenticate..."
        }
    }

    if ($Auth.access_token) { break }
    if ((Get-Date) -gt $expiresAt) {
        Write-Host "Device code expired. Please restart the script to request a new code."
        exit 1
    }
} until ($false)

$AccessToken = $Auth.access_token
Write-Host "Authentication successful."

# ================================
# GET ALL ONEDRIVE FILES + HASHES
# ================================
Write-Host "Retrieving OneDrive file list..."

$OneDriveFiles = @()
$NextLink = "https://graph.microsoft.com/v1.0/me/drive/root/search(q='')?select=name,id,hashes,size"

while ($NextLink) {
    $Response = Invoke-RestMethod -Headers @{Authorization = "Bearer $AccessToken"} -Uri $NextLink -Method GET
    $OneDriveFiles += $Response.value
    $NextLink = $Response.'@odata.nextLink'
}

Write-Host "Retrieved $($OneDriveFiles.Count) OneDrive items."

# Build a lookup table by SHA1
$OneDriveHashIndex = @{}
foreach ($item in $OneDriveFiles) {
    if ($item.hashes.sha1Hash) {
        $h = $item.hashes.sha1Hash.ToLower()
        if ($OneDriveHashIndex.ContainsKey($h)) {
            $OneDriveHashIndex[$h] += ,$item
        } else {
            $OneDriveHashIndex[$h] = @($item)
        }
    }
}

# ================================
# SCAN LOCAL FOLDER
# ================================
Write-Host "Scanning local folder: $LocalFolder"

$LocalFiles = Get-ChildItem -Path $LocalFolder -File -Recurse

$Duplicates = @()
$TotalScanned = 0
foreach ($file in $LocalFiles) {
    $TotalScanned++
    Write-Host "Checking $($file.FullName)..."

    # Compute SHA1
    $LocalHash = (Get-FileHash -Path $file.FullName -Algorithm SHA1).Hash.ToLower()

    if ($OneDriveHashIndex.ContainsKey($LocalHash)) {
        foreach ($Match in $OneDriveHashIndex[$LocalHash]) {
            Write-Host ">>> DUPLICATE FOUND!"
            Write-Host " Local: $($file.FullName)"
            Write-Host " OneDrive: $($Match.name)  (ID: $($Match.id))"
            Write-Host ""
            $Duplicates += [PSCustomObject]@{
                LocalPath = $file.FullName
                OneDriveName = $Match.name
                OneDriveId = $Match.id
            }
        }
    }
}

# Summary
Write-Host "Scan complete. Scanned $TotalScanned local files."
if ($Duplicates.Count -gt 0) {
    Write-Host "Found $($Duplicates.Count) duplicate(s):"
    foreach ($d in $Duplicates) {
        Write-Host " - $($d.LocalPath)  =>  $($d.OneDriveName) (ID: $($d.OneDriveId))"
    }
} else {
    Write-Host "No duplicates found."
}
