# ===============================
# TEMP SCRIPT - Récupère 1 page de delta et dump JSON complet
# ===============================
$ClientId = "176fc7bc-42c9-4a25-82b5-0ad584d3c061"
$TenantId = "common"
$Scopes = "offline_access openid Files.Read"

# Auth
$DeviceCode = Invoke-RestMethod -Method POST `
    -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/devicecode" `
    -Body @{ client_id = $ClientId; scope = $Scopes }

Write-Host $DeviceCode.message

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
Write-Host "Authenticated.`n"

# Première page delta
$NextLink = "https://graph.microsoft.com/v1.0/me/drive/root/delta?select=name,id,hashes,size,file"
try {
    $Response = Invoke-RestMethod -Headers @{ Authorization = "Bearer $AccessToken" } -Uri $NextLink -Method GET
} catch {
    Write-Host "Error retrieving delta: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# Écrire tout le JSON dans un fichier pour inspection
$DumpFile = ".\onedrive_firstpage.json"
$Response | ConvertTo-Json -Depth 10 | Set-Content $DumpFile

Write-Host "First page JSON dumped to $DumpFile. Stop processing now." -ForegroundColor Green