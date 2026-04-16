param(
    [string]$GpsCacheFile
)
# ============================
#   MODULE GPS TOOLS
# ============================
# Gestion du cache GPS : grille, clustering, API et normalisation.

if ($script:ModuleLoaded) {
    return
}
$script:ModuleLoaded = $true

# Validate OneDriveTools dependency
if (-not (Get-Command Get-GraphToken -ErrorAction SilentlyContinue)) {
    throw "ERROR: OneDriveTools functions are not available. Check the import in the main script."
}

# --- Configure user agent for Nominatim ---
$script:UserAgent = "OneDriveOrganizer_$($Config.ClientId)"

# --- Rate limit tracking ---
if (-not $script:LastApiCall) {
    $script:LastApiCall = Get-Date
}

# ============================
#   CACHE LOADING
# ============================
function Import-GpsCache {
    try {
        if ($GpsCacheFile -and (Test-Path $GpsCacheFile)) {
            $json = Get-Content $GpsCacheFile -Raw
            if ($json -and $json.Trim() -ne "") {
                $script:GpsCache = $json | ConvertFrom-Json -AsHashtable
                Write-Log "GPS cache loaded: $($script:GpsCache.Count) entries" "DEBUG"
                return
            }
        }
        # If file is empty or missing -> start with an empty Hashtable
        $script:GpsCache = @{}
        Write-Log "GPS cache initialized empty" "DEBUG"
    }
    catch {
        Write-Log "Import-GpsCache error: $_" "ERROR"
        $script:GpsCache = @{}
    }
}
function Initialize-GpsCache {
    try {
        if (-not $script:GpsCache) {
            Import-GpsCache
            return
        }

        if ($script:GpsCache -isnot [hashtable]) {
            Write-Log "Converting GPS cache to Hashtable" "DEBUG"
            $new = @{ }
            foreach ($p in $script:GpsCache.PSObject.Properties) {
                $new[$p.Name] = $p.Value
            }
            $script:GpsCache = $new
        }
    }
    catch {
        Write-Log "Initialize-GpsCache failure: $_" "ERROR"
    }
} # Initialize-GpsCache

# Save GPS cache to global JSON file
function Save-GpsCache {
    try {
        if (-not $GpsCacheFile) {
            Write-Log "Save-GpsCache called without GpsCacheFile defined" "WARN"
            return
        }

        $script:GpsCache | ConvertTo-Json | Set-Content $GpsCacheFile
        Write-Log "GPS cache saved to $GpsCacheFile" "DEBUG"
    }
    catch {
        Write-Log "Save-GpsCache failure: $_" "ERROR"
    }
} # Save-GpsCache

# Génère une clé GPS normalisée (grille ~100 m via arrondi)
function Get-GpsGridKey {
    param([double]$Lat, [double]$Lon)

    try {
        $gLat = [math]::Round($Lat, 4)
        $gLon = [math]::Round($Lon, 4)
        return "$gLat,$gLon"
    }
    catch {
        Write-Log "Get-GpsGridKey failure: $_" "ERROR"
    }
} # Get-GpsGridKey

# Trouve une clé GPS existante dans un rayon ~100 m dans le cache
function Find-NearbyGpsKey {
    param(
        [double]$Lat,
        [double]$Lon,
        [hashtable]$Cache,
        [double]$Tolerance = 0.001 # ~100 m
    )

    try {
        foreach ($key in $Cache.Keys) {
            $eLat, $eLon = $key -split ","
            if ([math]::Abs($eLat - $Lat) -lt $Tolerance -and
                [math]::Abs($eLon - $Lon) -lt $Tolerance) {
                return $key
            }
        }
        return $null
    }
    catch {
        Write-Log "Find-NearbyGpsKey failure: $_" "ERROR"
    }
} # Find-NearbyGpsKey

# Normalise un nom de localisation (ASCII, sans accents, tirets propres)
function Convert-LocationName {
    param([string]$Name)

    try {
        $normalized = $Name.Normalize([System.Text.NormalizationForm]::FormD)
        $clean = ($normalized.ToCharArray() | Where-Object {
            [System.Globalization.CharUnicodeInfo]::GetUnicodeCategory($_) -ne
            [System.Globalization.UnicodeCategory]::NonSpacingMark
        }) -join ""

        $clean = [Regex]::Replace($clean, "[^a-zA-Z0-9\-]", "")
        return ($clean -replace "-+", "-").Trim("-")
    }
    catch {
        Write-Log "Convert-LocationName failure: $_" "ERROR"
    }
} # Convert-LocationName

# Call the Nominatim API to resolve a GPS position
function Resolve-GpsApi {
    param([double]$Lat, [double]$Lon)

    try {

        # --- Smart rate limiting ---
        $elapsed = (Get-Date) - $script:LastApiCall
        if ($elapsed.TotalSeconds -lt 1.2) {
            $sleepMs = [int](1200 - $elapsed.TotalMilliseconds)
            if ($sleepMs -gt 0) {
                Start-Sleep -Milliseconds $sleepMs
            }
        }
        $script:LastApiCall = Get-Date

        $uri = "https://nominatim.openstreetmap.org/reverse?format=json&lat=$Lat&lon=$Lon&zoom=10&addressdetails=1"

            try {
                return Invoke-RestMethod -Uri $uri -UserAgent $script:UserAgent -ErrorAction Stop
            }
            catch {
# Return raw response for debug
                if ($_.Exception.Response) {
                    $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
                    $raw = $reader.ReadToEnd()
                    Write-Log "GPS API raw response: $raw" "ERROR"
                return $raw
            }

            Write-Log "GPS API error: $_" "ERROR"
        return $null
        }
    }
    catch {
        Write-Log "Resolve-GpsApi failure: $_" "ERROR"
    }
} # Resolve-GpsApi

# Repair the GPS cache: normalize keys/names, merge duplicates, and rewrite the file
function Repair-GpsCache {
    param([string]$CacheFile)

    try {
        Write-Log "Repairing GPS cache ($CacheFile)" "INFO"

        $cache = Get-Content $CacheFile | ConvertFrom-Json
        $newCache = @{ }

        foreach ($key in $cache.PSObject.Properties.Name) {
            $val = $cache.$key
            if (-not $val) { continue }

            $lat, $lon = $key -split ","
            $lat = [math]::Round([double]$lat, 5)
            $lon = [math]::Round([double]$lon, 5)
            $normKey = "$lat,$lon"

            $clean = Convert-LocationName $val

            $near = Find-NearbyGpsKey -Lat $lat -Lon $lon -Cache $newCache
            if ($near) {
                if ($clean.Length -gt $newCache[$near].Length) {
                    $newCache[$near] = $clean
                }
            }
            else {
                $newCache[$normKey] = $clean
            }
        }

        $newCache | ConvertTo-Json | Set-Content $CacheFile
        $script:GpsCache = $newCache

        Write-Log "GPS cache repaired: $($newCache.Count) entries" "SUCCESS"
    }
    catch {
        Write-Log "Repair-GpsCache failure: $_" "ERROR"
    }
} # Repair-GpsCache

# Résout un GPS en nom de localisation (cache → clustering → API → normalisation)
function Get-LocationName($gps) {
    try {
        if (!$gps -or $gps -eq "," -or $gps -match "^0,0$") { return $null }

        Initialize-GpsCache

        $lat, $lon = $gps -split ","
        $lat = [double]$lat
        $lon = [double]$lon

        # Clé de grille pour le cache (~100m)
        $gridKey = Get-GpsGridKey -Lat $lat -Lon $lon

        # 1. Cache exact
        if ($script:GpsCache.ContainsKey($gridKey)) {
            return $script:GpsCache[$gridKey]
        }

        # 2. Vérification de proximité (Clustering)
        $near = Find-NearbyGpsKey -Lat $lat -Lon $lon -Cache $script:GpsCache
        if ($near) {
            return $script:GpsCache[$near]
        }

        # 3. Call Nominatim API
        Write-Log "[API GPS] Résolution ($gridKey)" "WARN"

        # 3. API principale
        $res = Resolve-GpsApi -Lat $lat -Lon $lon

        # 4. Tolerance ±1 km
        if (!$res) {
            $offsets = @(-0.01, 0, 0.01)
            foreach ($dx in $offsets) {
                foreach ($dy in $offsets) {
                    $res = Resolve-GpsApi -Lat ($lat + $dx) -Lon ($lon + $dy)
                    if ($res) { break }
                }
                if ($res) { break }
            }
        }




        # Handle geocoding errors (e.g. open ocean)
        if (-not $res -or $res.error -or -not $res.address) {
            Write-Log "GPS not found for $gridKey (off-map area or API error)" "DEBUG"
            return $null 
        }

        # Extraction intelligente (Ville > Village > Comté > Pays)
        $addr = $res.address
        $locPart = $addr.city
        if (-not $locPart) { $locPart = $addr.town }
        if (-not $locPart) { $locPart = $addr.village }
        if (-not $locPart) { $locPart = $addr.hamlet }
        if (-not $locPart) { $locPart = $addr.suburb }
        if (-not $locPart) { $locPart = $addr.municipality }
        if (-not $locPart) { $locPart = $addr.county }
        if (-not $locPart) { $locPart = $addr.country }

        if (-not $locPart) { return $null }



        $addr = $res.address

        # Fallbacks intelligents (ville → municipalité → comté → état → pays)
        $city = $addr.city
        if (-not $city) { $city = $addr.town }
        if (-not $city) { $city = $addr.village }
        if (-not $city) { $city = $addr.hamlet }
        if (-not $city) { $city = $addr.suburb }
        if (-not $city) { $city = $addr.neighbourhood }
        if (-not $city) { $city = $addr.municipality }
        if (-not $city) { $city = $addr.county }
        if (-not $city) { $city = $addr.state }
        if (-not $city) { $city = $addr.country }

        # Fallback ultime si vraiment rien
        if (-not $city) {
            $city = "UNKNOWN-$lat-$lon"
            Write-Log "=== DEBUG GPS DUMP (NO CITY FOUND) ===" "ERROR"
            try {
                $raw = $res | ConvertTo-Json -Depth 10
                Write-Log "Réponse JSON brute : $raw" "ERROR"
            }
            catch {
                Write-Log "Raw non-JSON response: $res" "ERROR"
            }
            Write-Log "=== FIN DEBUG GPS DUMP ===" "ERROR"
        }

        $state = $addr.state
        if (-not $state) { $state = $addr.county }
        if (-not $state) { $state = "NA" }

        $country = $addr.country
        if (-not $country) { $country = "NA" }


        $fullLoc = "$city-$state-$country" -replace " ", "-"
        $clean = Convert-LocationName $fullLoc

        # Mise à jour du cache
        $before = $script:GpsCache[$gridKey]
        $script:GpsCache[$gridKey] = $clean

        if ($before -ne $clean) {
            Write-Log "GPS Cache Update:`n   Key   : $gridKey`n   Before: $before`n   After : $clean" "DEBUG"
        }

        Save-GpsCache

        Write-Log "GPS OK: $clean" "INFO"
        return $clean
    }
    catch {
        Write-Log "Get-LocationName error: $_" "ERROR"
        return $null
    }
} # Get-LocationName


# ============================
# EXPORT
# ============================
Export-ModuleMember -Function *
