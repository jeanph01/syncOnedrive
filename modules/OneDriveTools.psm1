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
    Write-Log "OneDriveTools.psm1 already loaded -> import ignored" "DEBUG"
    return
}
$script:ModuleLoaded = $true


# ============================================================
# UNIFIED LOGGING
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

        # Define console colors
        $color = switch ($normalized) {
            "ERREUR" { "Red" }
            "ERROR"  { "Red" }
            "WARN"   { "Yellow" }
            "SUCCESS"{ "Green" }
            "DEBUG"  { "DarkGray" }
            default  { "Gray" }
        }

        $msg = "[$timestamp] [$normalized] $Message"

        # Console output (unless DEBUG is disabled)
        if ($normalized -ne "DEBUG" -or $script:VerboseMode) {
            Write-Host $msg -ForegroundColor $color
        }

        # Write to log file with locking retry (3 attempts)
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
        Write-Host "CRITICAL ERROR in Write-Log: $_" -ForegroundColor Red
    }
} # Write-Log


# ============================================================
# PARAMETER VALIDATION
# ============================================================
function Assert-ValidParam {
    param([string]$Name, [string]$Value)

    try {
        if ([string]::IsNullOrWhiteSpace($Value)) {
            Write-Log "Parameter '$Name' is empty or invalid" "ERROR"
            throw "Parameter '$Name' is invalid"
        }
    }
    catch {
        Write-Log "Assert-ValidParam failed: $_" "ERROR"
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
        Write-Log "Unreadable token -> ignored" "WARN"
        return $null
    }
}

function Save-GraphToken {
    param($Auth)

    try {
        $Auth | ConvertTo-Json | Set-Content $TokenFile -ErrorAction Stop
        Write-Log "Graph token saved" "DEBUG"
    }
    catch {
        Write-Log "Unable to write token to '$TokenFile'" "ERROR"
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
        Write-Log "Get-GraphToken: checking existing token"

        $existing = Read-GraphToken

        if ($existing -and $existing.access_token) {

            if ($existing.expires_on -gt (Get-Date).ToUniversalTime().ToFileTimeUtc()) {
                Write-Log "Valid token loaded from cache"
                return $existing
            }

            if (Test-GraphToken $existing.access_token) {
                Write-Log "Token still valid (Graph OK)"
                return $existing
            }
        }

        Write-Log "[AUTH] New token required"

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
                Write-Log "Attempting to obtain token..." "DEBUG"
            }
        }

        $Auth | Add-Member -NotePropertyName expires_on -NotePropertyValue (
            (Get-Date).AddSeconds($Auth.expires_in).ToUniversalTime().ToFileTimeUtc()
        )

        Save-GraphToken $Auth
        Write-Log "Graph token acquired"

        return $Auth
    }
    catch {
        Write-Log "Get-GraphToken failed: $_" "ERROR"
    }
}



# =====================================================================
# CACHE HASH
# =====================================================================

# Calculate hash of OneDrive cache file
function Get-CacheHash {
    try {
        if (-not (Test-Path $IndexFile)) {
            Write-Log "Unable to calculate hash, file missing: $IndexFile" "WARN"
            return $null
        }
        return (Get-FileHash $IndexFile -Algorithm SHA256).Hash
    }
    catch {
        Write-Log "Erreur calcul hash : $($_.Exception.Message)" "ERROR"
        return $null
    }
} # Get-CacheHash


# Return the details of an HTTP error
function Get-ErrorDetails {
    param(
        $Exception  # Exception to analyze
    )
    try {
        if ($Exception.Response) {
            $reader = New-Object System.IO.StreamReader($Exception.Response.GetResponseStream())
            return $reader.ReadToEnd()
        }
    }
    catch {
        Write-Log "Failed to read error details: $($_.Exception.Message)" "ERROR"
    }
    return $Exception.Message
} # Get-ErrorDetails


# Convert a string to ASCII-safe form for file names/paths
function Convert-ToAscii {
    param(
        [string]$Text,          # Text to normalize
        [bool]$IsPath = $false  # Indicates if it's a path
    )

    try {
        if ([string]::IsNullOrWhiteSpace($Text)) { return "" }

        # Normalisation Unicode → ASCII
        $clean = $Text.Normalize([System.Text.NormalizationForm]::FormD) -replace '\p{M}', ''
        # Remove GUIDs and long hex/base64 sequences
        $clean = $clean -replace "[a-fA-F0-9]{8}-([a-fA-F0-9]{4}-){3}[a-fA-F0-9]{12}", ""
        $clean = $clean -replace "[a-zA-Z0-9]{16,}", ""

        # Filter invalid characters
        $pattern = if ($IsPath) { "[^a-zA-Z0-9\.\-/]" } else { "[^a-zA-Z0-9\.\-]" }
        return ($clean -replace $pattern, "_" -replace "_+", "_").Trim("_")
    }
    catch {
        Write-Log "Convert-ToAscii failed: $($_.Exception.Message)" "ERROR"
        return ""
    }
} # Convert-ToAscii

# =====================================================================
# AUTHENTICATION
# =====================================================================

# Obtain a Graph token and prepare headers
function Connect-AzureGraph {
    try {
        Write-Log "Obtaining Graph token via module..."
        $auth = Get-GraphToken

        if (-not $auth.access_token) {
            Write-Log "Graph token failed" "ERROR"
            throw "Unable to obtain Graph token."
        }

        $Global:State.Headers = @{
            Authorization  = "Bearer $($auth.access_token)"
            "Content-Type" = "application/json"
        }

        Write-Log "Graph token loaded." "SUCCESS"
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

        Write-Log "OneDriveTools.psm1 loaded"
        Write-Log "ClientId=$ClientId"  "DEBUG"
        Write-Log "TokenFile=$TokenFile" "DEBUG"
        Write-Log "LogFile=$LogFile"     "DEBUG"
    }
    catch {
        Write-Log "Main failed: $_" "ERROR"
    }
} # main


main
# ============================================================
# EXPORT
# ============================================================
Export-ModuleMember -Function *