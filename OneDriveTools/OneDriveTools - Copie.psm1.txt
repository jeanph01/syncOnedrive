param(
    [string]$ClientId,
    [string]$TokenFile,
    [string]$LogFile
)

# ---------------- LOGGING ----------------
function Write-Log {
    param([string]$Message)

    $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $line = "$ts | $Message"

    Write-Host $line
    Add-Content -Path $LogFile -Value $line
}

# ---------------- TOKEN MANAGEMENT ----------------
function Read-GraphToken {
    if (Test-Path $TokenFile) {
        try { return Get-Content $TokenFile -Raw | ConvertFrom-Json }
        catch { return $null }
    }
    return $null
}

function Save-GraphToken {
    param($Auth)
    $Auth | ConvertTo-Json | Set-Content $TokenFile
}

function Test-GraphToken {
    param([string]$AccessToken)

    try {
        $headers = @{ Authorization = "Bearer $AccessToken" }
        Invoke-RestMethod -Headers $headers -Uri "https://graph.microsoft.com/v1.0/me" -Method GET -ErrorAction Stop > $null
        return $true
    }
    catch { return $false }
}

function Get-GraphToken {

    $existing = Read-GraphToken
    if ($existing -and $existing.access_token) {

        if ($existing.expires_on -gt (Get-Date).ToUniversalTime().ToFileTimeUtc()) {
            Write-Log "Token valide chargé depuis le cache"
            return $existing
        }

        if (Test-GraphToken $existing.access_token) {
            Write-Log "Token encore valide"
            return $existing
        }
    }

    Write-Log "[AUTH] Nouveau token requis"

    $DeviceCode = Invoke-RestMethod -Method POST `
        -Uri "https://login.microsoftonline.com/common/oauth2/v2.0/devicecode" `
        -Body @{ client_id = $ClientId; scope = "Files.ReadWrite.All" }

    Write-Log $DeviceCode.message

    $Auth = $null
    while (!$Auth) {
        Start-Sleep 5
        try {
            $Auth = Invoke-RestMethod -Method POST `
                -Uri "https://login.microsoftonline.com/common/oauth2/v2.0/token" `
                -Body @{
                    grant_type  = "urn:ietf:params:oauth:grant-type:device_code"
                    client_id   = $ClientId
                    device_code = $DeviceCode.device_code
                }
        }
        catch {}
    }

    $Auth | Add-Member -NotePropertyName expires_on -NotePropertyValue (
        (Get-Date).AddSeconds($Auth.expires_in).ToUniversalTime().ToFileTimeUtc()
    )

    Save-GraphToken $Auth
    Write-Log "Token Graph obtenu"

    return $Auth
}

Export-ModuleMember -Function * -Alias *