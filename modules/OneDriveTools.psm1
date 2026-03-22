param(
    [Parameter(Mandatory = $true)]
    [string]$ClientId,

    [Parameter(Mandatory = $true)]
    [string]$TokenFile,

    [Parameter(Mandatory = $true)]
    [string]$LogFile
)

# ============================================================
#   MODULE ONEDRIVETOOLS — Logging, Token Graph, Validation
# ============================================================

if ($script:ModuleLoaded) {
    Write-Log "OneDriveTools.psm1 déjà chargé → import ignoré" "DEBUG"
    return
}
$script:ModuleLoaded = $true


# ============================================================
# LOGGING UNIFIÉ
# ============================================================
function Write-Log {
    [CmdletBinding()]
    param([string]$Message, [string]$Level = "INFO")

    try {
        $timestamp = Get-Date -Format "HH:mm:ss"
        $normalized = $Level.Trim().ToUpper()

        $color = switch ($normalized) {
            "ERREUR" { "Red" }
            "ERROR"  { "Red" }
            "E"      { "Red" }

            "WARN"   { "Yellow" }
            "WARNING"{ "Yellow" }
            "W"      { "Yellow" }

            "SUCCESS"{ "Green" }
            "OK"     { "Green" }
            "S"      { "Green" }

            "DEBUG"  { "DarkGray" }
            "D"      { "DarkGray" }

            "INFO"   { "DarkGray" }
            "I"      { "DarkGray" }

            default  { "Gray" }
        }

        $msg = "[$timestamp] [$normalized] $Message"

        if ($normalized -ne "DEBUG" -or $VerboseMode) {
            Write-Host $msg -ForegroundColor $color
        }

        $msg | Add-Content $LogFile -ErrorAction SilentlyContinue
    }
    catch {
        Write-Host "ERREUR Write-Log: $_" -ForegroundColor Red
    }
}


# ============================================================
# VALIDATION PARAMÈTRES
# ============================================================
function Assert-ValidParam {
    param([string]$Name, [string]$Value)

    try {
        if ([string]::IsNullOrWhiteSpace($Value)) {
            Write-Log "Paramètre '$Name' vide ou invalide" "ERREUR"
            throw "Paramètre '$Name' invalide"
        }
    }
    catch {
        Write-Log "Échec Assert-ValidParam: $_" "ERREUR"
        throw
    }
}


# ============================================================
# TOKEN MANAGEMENT
# ============================================================
function Read-GraphToken {
    try {
        if (Test-Path $TokenFile) {
            return Get-Content $TokenFile -Raw | ConvertFrom-Json
        }
        return $null
    }
    catch {
        Write-Log "Token illisible → ignoré" "WARN"
        return $null
    }
}

function Save-GraphToken {
    param($Auth)

    try {
        $Auth | ConvertTo-Json | Set-Content $TokenFile -ErrorAction Stop
        Write-Log "Token Graph sauvegardé" "DEBUG"
    }
    catch {
        Write-Log "Impossible d'écrire le token dans '$TokenFile'" "ERREUR"
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
# GET-GRAPHTOKEN (DURCI)
# ============================================================
function Get-GraphToken {
    try {
        Write-Log "Get-GraphToken: Vérification du token existant"

        $existing = Read-GraphToken

        if ($existing -and $existing.access_token) {

            if ($existing.expires_on -gt (Get-Date).ToUniversalTime().ToFileTimeUtc()) {
                Write-Log "Token valide chargé depuis le cache"
                return $existing
            }

            if (Test-GraphToken $existing.access_token) {
                Write-Log "Token encore valide (Graph OK)"
                return $existing
            }
        }

        Write-Log "[AUTH] Nouveau token requis"

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
                Write-Log "Tentative d'obtention du token..." "DEBUG"
            }
        }

        $Auth | Add-Member -NotePropertyName expires_on -NotePropertyValue (
            (Get-Date).AddSeconds($Auth.expires_in).ToUniversalTime().ToFileTimeUtc()
        )

        Save-GraphToken $Auth
        Write-Log "Token Graph obtenu"

        return $Auth
    }
    catch {
        Write-Log "Échec Get-GraphToken: $_" "ERREUR"
    }
}


# ============================================================
# INITIALISATION
# ============================================================
function main {
    try {
        Assert-ValidParam -Name "ClientId"  -Value $ClientId
        Assert-ValidParam -Name "TokenFile" -Value $TokenFile
        Assert-ValidParam -Name "LogFile"   -Value $LogFile

        Write-Log "OneDriveTools.psm1 chargé"
        Write-Log "ClientId=$ClientId"  "DEBUG"
        Write-Log "TokenFile=$TokenFile" "DEBUG"
        Write-Log "LogFile=$LogFile"     "DEBUG"
    }
    catch {
        Write-Log "Échec main: $_" "ERREUR"
    }
}

main


# ============================================================
# EXPORT
# ============================================================
Export-ModuleMember -Function *