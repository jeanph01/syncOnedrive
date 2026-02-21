# ================================
# CONFIGURATION
# ================================
$LocalFolder = "D:\recup\test"
# Use the app registration for personal accounts and the consumer tenant
# (created earlier: syncOnedrive-personal)
# $ClientId = "176fc7bc-42c9-4a25-82b5-0ad584d3c061"
# $TenantId = "e3f75fb4-c0eb-4d7d-a335-65e4e3e32c76"

# ID de votre application "requete onedrive"
$ClientId = "176fc7bc-42c9-4a25-82b5-0ad584d3c061"
# Utilisation de 'common' pour autoriser les comptes personnels (Famille/Perso)
$TenantId = "common"
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

# Poll for token until success or expiry
$Auth = $null
while (-not $Auth -or -not $Auth.access_token) {
    Start-Sleep -Seconds $interval
    try {
        $tokenResponse = Invoke-RestMethod -Method POST -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" -Body @{
            grant_type  = "urn:ietf:params:oauth:grant-type:device_code"
            client_id   = $ClientId
            device_code = $DeviceCode.device_code
        } -ErrorAction Stop

        $Auth = $tokenResponse
        break
    } catch {
        # Try to read structured error from response body
        $resp = $_.Exception.Response
        $handled = $false
        if ($resp) {
            try {
                $sr = New-Object System.IO.StreamReader($resp.GetResponseStream())
                $body = $sr.ReadToEnd()
                $js = $body | ConvertFrom-Json -ErrorAction SilentlyContinue
                if ($js -and $js.error) {
                    switch ($js.error) {
                        'authorization_pending' { Write-Host 'Waiting for user to authenticate...'; $handled = $true }
                        'authorization_declined' { Write-Host 'User declined authentication.'; exit 1 }
                        default { Write-Host "Token request error: $($js.error) - $($js.error_description)"; exit 1 }
                    }
                }
            } catch {
                # fallback to a simple wait
                Write-Host 'Waiting for user to authenticate...'
                $handled = $true
            }
        }
        if (-not $handled) { Write-Host 'Waiting for user to authenticate...' }
    }

    if ((Get-Date) -gt $expiresAt) {
        Write-Host "Device code expired. Please restart the script to request a new code."
        exit 1
    }
}

$AccessToken = $Auth.access_token
Write-Host "Authentication successful."

# ================================
# GET ALL ONEDRIVE FILES + HASHES
# ================================
Write-Host "Retrieving OneDrive file list..." -ForegroundColor Cyan

$OneDriveFiles = @()
# On utilise 'delta' qui est le moyen le plus efficace de lister tout le contenu récursivement
$NextLink = "https://graph.microsoft.com/v1.0/me/drive/root/delta?select=name,id,hashes,size,file"

while ($NextLink) {
    try {
        $Response = Invoke-RestMethod -Headers @{Authorization = "Bearer $AccessToken"} -Uri $NextLink -Method GET
        # On ne garde que les éléments qui sont des fichiers (on ignore les dossiers)
        $FilesOnly = $Response.value | Where-Object { $_.file -ne $null }
        $OneDriveFiles += $FilesOnly
        $NextLink = $Response.'@odata.nextLink'
    } catch {
        Write-Host "Error retrieving files: $($_.Exception.Message)" -ForegroundColor Red
        $NextLink = $null
    }
}

Write-Host "Retrieved $($OneDriveFiles.Count) files from OneDrive."


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
