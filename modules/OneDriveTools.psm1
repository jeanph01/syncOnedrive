param(
    [Parameter(Mandatory = $true)]
    [string]$ClientId,

    [Parameter(Mandatory = $true)]
    [string]$TokenFile,

    [Parameter(Mandatory = $true)]
    [string]$LogFile
)

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
            "ERROR" { "Red" }
            "WARN" { "Yellow" }
            "SUCCESS" { "Green" }
            "DEBUG" { "DarkGray" }
            default { "Gray" }
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
        if ($Auth -and $Auth.PSObject.Properties.Name -notcontains 'acquired_on') {
            $Auth | Add-Member -NotePropertyName acquired_on -NotePropertyValue ((Get-Date).ToUniversalTime().ToFileTimeUtc())
        }
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
        Write-Log "Get-GraphToken: checking existing token" "DEBUG"

        $existing = Read-GraphToken
        $tenant = "consumers"
        $maxTokenAgeMinutes = 55
        $maxTokenAgeTicks = [TimeSpan]::FromMinutes($maxTokenAgeMinutes).Ticks

        if ($existing -and $existing.access_token) {
            $issuedOnUtc = $null
            if ($existing.PSObject.Properties.Name -contains 'acquired_on' -and $existing.acquired_on) {
                try {
                    $issuedOnUtc = [datetime]::FromFileTimeUtc([int64]$existing.acquired_on)
                }
                catch {
                    $issuedOnUtc = $null
                }
            }
            elseif (Test-Path $TokenFile) {
                $issuedOnUtc = (Get-Item $TokenFile).LastWriteTimeUtc
            }

            if ($issuedOnUtc) {
                $ageTicks = ((Get-Date).ToUniversalTime() - $issuedOnUtc).Ticks
                if ($ageTicks -gt $maxTokenAgeTicks) {
                    Write-Log "Cached token exceeded max age ($maxTokenAgeMinutes min). Forcing regeneration." "WARN"
                    $existing = $null
                }
            }

            if ($existing) {
                # 1. Vérification expiration locale avec marge de sécurité de 2 minutes
                $margin = [TimeSpan]::FromMinutes(2).Ticks
                $now = (Get-Date).ToUniversalTime().ToFileTimeUtc()

                if ($existing.expires_on -gt ($now + $margin)) {
                    if (Test-GraphToken -AccessToken $existing.access_token) {
                        Write-Log "Valid token loaded from cache" "DEBUG"
                        return $existing
                    }

                    Write-Log "Cached token rejected by Graph, forcing refresh/auth." "WARN"
                }

                # 2. Si expiré ou proche de l'expiration -> Tenter rafraîchissement silencieux
                if ($existing.refresh_token) {
                    Write-Log "[AUTH] Token expired or expiring soon. Attempting silent refresh..." "INFO"
                    try {
                        $Auth = Invoke-RestMethod -Method POST `
                            -Uri "https://login.microsoftonline.com/$tenant/oauth2/v2.0/token" `
                            -Body @{
                            client_id     = $ClientId
                            grant_type    = "refresh_token"
                            refresh_token = $existing.refresh_token
                            scope         = "Files.ReadWrite.All offline_access User.Read"
                        } -ErrorAction Stop

                        # Ajout expiration locale
                        $Auth | Add-Member -NotePropertyName expires_on -NotePropertyValue (
                            (Get-Date).AddSeconds($Auth.expires_in).ToUniversalTime().ToFileTimeUtc()
                        )

                        Save-GraphToken $Auth
                        Write-Log "[AUTH] Silent refresh successful" "SUCCESS"
                        return $Auth
                    }
                    catch {
                        Write-Log "[AUTH] Silent refresh failed: $($_.Exception.Message). Falling back to interactive auth." "WARN"
                    }
                }
            }
        }

        Write-Log "[AUTH] New token required"

        Assert-ValidParam -Name "ClientId" -Value $ClientId

        # === DEVICE CODE FLOW ===
        $Auth = $null
        $deviceCodeRetry = 0
        while (-not $Auth -and $deviceCodeRetry -lt 3) {
            $deviceCodeRetry++
            $DeviceCode = Invoke-RestMethod -Method POST `
                -Uri "https://login.microsoftonline.com/$tenant/oauth2/v2.0/devicecode" `
                -Body @{
                client_id = $ClientId
                scope     = "Files.ReadWrite.All offline_access User.Read"
            }

            $deviceIssuedUtc = Get-Date
            $deviceExpiresIn = 900
            if ($DeviceCode.PSObject.Properties.Name -contains 'expires_in' -and $DeviceCode.expires_in) {
                $deviceExpiresIn = [int]$DeviceCode.expires_in
            }

            $pollInterval = 5
            if ($DeviceCode.PSObject.Properties.Name -contains 'interval' -and $DeviceCode.interval) {
                $pollInterval = [Math]::Max(5, [int]$DeviceCode.interval)
            }

            Write-Log $DeviceCode.message
            Write-Log "Device code valid for $deviceExpiresIn seconds. It will be renewed automatically if you wait too long." "INFO"

            while (-not $Auth) {
                $elapsedSeconds = ((Get-Date) - $deviceIssuedUtc).TotalSeconds
                if ($elapsedSeconds -ge $deviceExpiresIn) {
                    Write-Log "Device code expired before authorization. Generating a new code..." "WARN"
                    break
                }

                Start-Sleep -Seconds $pollInterval
                try {
                    $Auth = Invoke-RestMethod -Method POST `
                        -Uri "https://login.microsoftonline.com/$tenant/oauth2/v2.0/token" `
                        -Body @{
                        grant_type  = "urn:ietf:params:oauth:grant-type:device_code"
                        client_id   = $ClientId
                        device_code = $DeviceCode.device_code
                    } -ErrorAction Stop
                }
                catch {
                    $msg = $_.Exception.Message
                    if ($msg -match 'authorization_pending|slow_down') {
                        Write-Log "Waiting for browser authorization..." "DEBUG"
                        continue
                    }

                    if ($msg -match 'expired_token|invalid_grant|authorization_declined|code.*expired') {
                        Write-Log "Device code no longer valid. A new code will be requested." "WARN"
                        break
                    }

                    Write-Log "Attempting to obtain token..." "DEBUG"
                }
            }
        }

        if (-not $Auth) {
            throw "Unable to obtain Graph token after repeated device-code renewals."
        }

        # Ajout expiration locale
        $Auth | Add-Member -NotePropertyName expires_on -NotePropertyValue (
            (Get-Date).AddSeconds($Auth.expires_in).ToUniversalTime().ToFileTimeUtc()
        )

        Save-GraphToken $Auth
        Write-Log "Graph token acquired"

        return $Auth
    }
    catch {
        Write-Log "Get-GraphToken failed: $($_.Exception.Message)" "ERROR"
    }
}

# Helper to convert JSON to Hashtable with PS 5.1 fallback
function ConvertFrom-JsonOptimized {
    param(
        [Parameter(Mandatory = $true)]
        [string]$JsonString,
        [switch]$AsHashtable
    )

    if ([string]::IsNullOrWhiteSpace($JsonString)) { return $null }

    try {
        if ($AsHashtable) {
            if ($PSVersionTable.PSVersion.Major -ge 6) {
                return $JsonString | ConvertFrom-Json -AsHashtable
            }

            # PS 5.1 Fallback: Recursive conversion for Hashtables
            $obj = $JsonString | ConvertFrom-Json
            return Convert-ObjectToHashtable -InputObject $obj
        }
        return $JsonString | ConvertFrom-Json
    }
    catch {
        return $null
    }
}

# Private helper for ConvertFrom-JsonOptimized
function Convert-ObjectToHashtable {
    param($InputObject)
    if ($InputObject -is [System.Array] -or $InputObject -is [System.Collections.Generic.List[object]]) {
        return @($InputObject | ForEach-Object { Convert-ObjectToHashtable $_ })
    }
    elseif ($InputObject -is [PSCustomObject]) {
        $hash = @{}
        foreach ($prop in $InputObject.psobject.Properties) {
            $hash[$prop.Name] = Convert-ObjectToHashtable $prop.Value
        }
        return $hash
    }
    return $InputObject
}

# =====================================================================
# CACHE HASH
# =====================================================================

# Calculate hash of OneDrive cache file
function Get-CacheHash {
    try {
        if (-not (Test-Path $Global:IndexFile)) {
            Write-Log "Unable to calculate hash, file missing: $Global:IndexFile" "WARN"
            return $null
        }
        return (Get-FileHash $Global:IndexFile -Algorithm SHA256).Hash
    }
    catch {
        Write-Log "Erreur calcul hash : $($_.Exception.Message)" "ERROR"
        return $null
    }
} # Get-CacheHash


# Return the details of an HTTP error
function Get-ErrorDetails {
    param(
        $Exception
    )

    try {
        # Cas PowerShell 5 : WebException
        if ($Exception.Response -and $Exception.Response.GetType().Name -eq "HttpWebResponse") {
            $reader = New-Object System.IO.StreamReader($Exception.Response.GetResponseStream())
            return $reader.ReadToEnd()
        }

        # Cas PowerShell 7 : HttpResponseMessage
        if ($Exception.Response -and $Exception.Response.Content) {
            return $Exception.Response.Content.ReadAsStringAsync().Result
        }
    }
    catch {
        Write-Log "Failed to read error details: $($_.Exception.Message)" "ERROR"
    }

    return $Exception.Message
}

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
        Write-Log "Checking Graph token validity..." "DEBUG"
        $auth = Get-GraphToken

        if (-not $auth.access_token) {
            throw "Unable to obtain Graph token."
        }

        $Global:State.Headers = @{
            Authorization  = "Bearer $($auth.access_token)"
            "Content-Type" = "application/json"
        }
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
