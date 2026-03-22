param(
    [Parameter(Mandatory=$true)]
    [string]$ClientId,

    [Parameter(Mandatory=$true)]
    [string]$TokenFile,

    [Parameter(Mandatory=$true)]
    [string]$LogFile
)

# ============================================================
# 1. PROTECTION CONTRE LES IMPORTS MULTIPLES
# ============================================================

if ($script:ModuleLoaded) {
    Write-Host "OneDriveTools.psm1 déjà chargé → import ignoré (sécurisé)"
    return
}
$script:ModuleLoaded = $true

# ============================================================
# 2. VALIDATION DES PARAMÈTRES
# ============================================================

function Assert-ValidParam {
    param([string]$Name, [string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw "ERREUR CRITIQUE: Le paramètre '$Name' est vide ou invalide dans OneDriveTools.psm1"
    }
}

Assert-ValidParam -Name "ClientId" -Value $ClientId
Assert-ValidParam -Name "TokenFile" -Value $TokenFile
Assert-ValidParam -Name "LogFile"  -Value $LogFile

Write-Host "OneDriveTools.psm1 chargé avec succès"
Write-Host "ClientId=$ClientId"
Write-Host "TokenFile=$TokenFile"
Write-Host "LogFile=$LogFile"

# ============================================================
# 3. LOGGING ROBUSTE
# ============================================================

function Write-Log {
    param([string]$Message)

    try {
        $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        $line = "$ts | $Message"

        Write-Host $line
        Add-Content -Path $LogFile -Value $line -ErrorAction Stop
    }
    catch {
        Write-Host "ERREUR: Impossible d'écrire dans le fichier log '$LogFile'"
    }
}

# ============================================================
# 4. TOKEN MANAGEMENT ROBUSTE
# ============================================================

function Read-GraphToken {
    if (Test-Path $TokenFile) {
        try {
            return Get-Content $TokenFile -Raw | ConvertFrom-Json
        }
        catch {
            Write-Log "Token illisible → ignoré"
            return $null
        }
    }
    return $null
}

function Save-GraphToken {
    param($Auth)

    try {
        $Auth | ConvertTo-Json | Set-Content $TokenFile -ErrorAction Stop
    }
    catch {
        Write-Log "ERREUR: Impossible d'écrire le token dans '$TokenFile'"
    }
}

function Test-GraphToken {
    param([string]$AccessToken)

    try {
        $headers = @{ Authorization = "Bearer $AccessToken" }
        Invoke-RestMethod -Headers $headers `
            -Uri "https://graph.microsoft.com/v1.0/me" `
            -Method GET -ErrorAction Stop > $null
        return $true
    }
    catch {
        return $false
    }
}

# ============================================================
# 5. GET-GRAPHTOKEN (VERSION DURCIE)
# ============================================================

function Get-GraphToken {

    Write-Log "Get-GraphToken: Vérification du token existant"

    $existing = Read-GraphToken

    if ($existing -and $existing.access_token) {

        # Token non expiré
        if ($existing.expires_on -gt (Get-Date).ToUniversalTime().ToFileTimeUtc()) {
            Write-Log "Token valide chargé depuis le cache"
            return $existing
        }

        # Token expiré mais encore accepté par Graph
        if (Test-GraphToken $existing.access_token) {
            Write-Log "Token encore valide (Graph OK)"
            return $existing
        }
    }

    # ========================================================
    # NOUVELLE AUTHENTIFICATION
    # ========================================================

    Write-Log "[AUTH] Nouveau token requis"

    # Vérification ultime
    Assert-ValidParam -Name "ClientId" -Value $ClientId

    $DeviceCode = Invoke-RestMethod -Method POST `
        -Uri "https://login.microsoftonline.com/common/oauth2/v2.0/devicecode" `
        -Body @{
            client_id = $ClientId
            scope     = "Files.ReadWrite.All"
        }

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
        catch {
            Write-Log "Tentative d'obtention du token..."
        }
    }

    # Ajout expiration
    $Auth | Add-Member -NotePropertyName expires_on -NotePropertyValue (
        (Get-Date).AddSeconds($Auth.expires_in).ToUniversalTime().ToFileTimeUtc()
    )

    Save-GraphToken $Auth
    Write-Log "Token Graph obtenu"

    return $Auth
}

# ============================================================
# EXPORT
# ============================================================

Export-ModuleMember -Function * -Alias *