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
    param(
        [Parameter(Mandatory)][string]$Message, 
        [string]$Level = "INFO"
    )

    try {
        $timestamp = Get-Date -Format "HH:mm:ss"
        $normalized = $Level.Trim().ToUpper()

        # Définition des couleurs pour la console
        $color = switch ($normalized) {
            "ERREUR" { "Red" }
            "ERROR"  { "Red" }
            "WARN"   { "Yellow" }
            "SUCCESS"{ "Green" }
            "DEBUG"  { "DarkGray" }
            default  { "Gray" }
        }

        $msg = "[$timestamp] [$normalized] $Message"

        # Affichage console (sauf si DEBUG est désactivé)
        if ($normalized -ne "DEBUG" -or $script:VerboseMode) {
            Write-Host $msg -ForegroundColor $color
        }

        # Écriture dans le fichier log avec gestion du verrouillage (3 tentatives)
        $maxRetries = 3
        for ($i = 0; $i -lt $maxRetries; $i++) {
            try {
                $msg | Add-Content $LogFile -ErrorAction Stop
                break 
            }
            catch {
                Start-Sleep -Milliseconds 150
            }
        }
    }
    catch {
        Write-Host "ERREUR critique dans Write-Log: $_" -ForegroundColor Red
    }
} # Write-Log


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



# =====================================================================
# HASH DU CACHE
# =====================================================================

# Calcule le hash du fichier de cache OneDrive
function Get-CacheHash {
    try {
        if (-not (Test-Path $IndexFile)) {
            Write-Log "Impossible de calculer le hash, fichier absent : $IndexFile" "WARN"
            return $null
        }
        return (Get-FileHash $IndexFile -Algorithm SHA256).Hash
    }
    catch {
        Write-Log "Erreur calcul hash : $($_.Exception.Message)" "ERROR"
        return $null
    }
} # Get-CacheHash


# Retourne les détails d'une erreur HTTP
function Get-ErrorDetails {
    param(
        $Exception  # Exception à analyser
    )
    try {
        if ($Exception.Response) {
            $reader = New-Object System.IO.StreamReader($Exception.Response.GetResponseStream())
            return $reader.ReadToEnd()
        }
    }
    catch {
        Write-Log "Erreur lors de la lecture des détails d'erreur : $($_.Exception.Message)" "ERROR"
    }
    return $Exception.Message
} # Get-ErrorDetails


# Convertit une chaîne en ASCII safe pour noms de fichiers/chemins
function Convert-ToAscii {
    param(
        [string]$Text,          # Texte à normaliser
        [bool]$IsPath = $false  # Indique si c'est un chemin
    )

    try {
        if ([string]::IsNullOrWhiteSpace($Text)) { return "" }

        # Normalisation Unicode → ASCII
        $clean = $Text.Normalize([System.Text.NormalizationForm]::FormD) -replace '\p{M}', ''
        # Suppression GUIDs et longues séquences hex/base64
        $clean = $clean -replace "[a-fA-F0-9]{8}-([a-fA-F0-9]{4}-){3}[a-fA-F0-9]{12}", ""
        $clean = $clean -replace "[a-zA-Z0-9]{16,}", ""

        # Filtrage caractères invalides
        $pattern = if ($IsPath) { "[^a-zA-Z0-9\.\-/]" } else { "[^a-zA-Z0-9\.\-]" }
        return ($clean -replace $pattern, "_" -replace "_+", "_").Trim("_")
    }
    catch {
        Write-Log "Erreur Convert-ToAscii : $($_.Exception.Message)" "ERROR"
        return ""
    }
} # Convert-ToAscii

# =====================================================================
# AUTHENTIFICATION
# =====================================================================

# Obtient un token Graph et prépare les en-têtes
function Connect-AzureGraph {
    try {
        Write-Log "Obtention du token Graph via module..."
        $auth = Get-GraphToken

        if (-not $auth.access_token) {
            Write-Log "Échec token Graph" "ERROR"
            throw "Impossible d'obtenir un token Graph."
        }

        $Global:State.Headers = @{
            Authorization  = "Bearer $($auth.access_token)"
            "Content-Type" = "application/json"
        }

        Write-Log "Token Graph chargé." "SUCCESS"
    }
    catch {
        Write-Log "Erreur Connect-AzureGraph : $($_.Exception.Message)" "ERROR"
        throw
    }
} # Connect-AzureGraph


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
} # main


main
# ============================================================
# EXPORT
# ============================================================
Export-ModuleMember -Function *