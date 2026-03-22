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

# Vérifie la dépendance OneDriveTools
if (-not (Get-Command Get-GraphToken -ErrorAction SilentlyContinue)) {
    throw "ERREUR: Les fonctions de OneDriveTools ne sont pas disponibles. Vérifie l'import dans le script principal."
}

# --- AJOUT 1 : User-Agent conforme Nominatim ---
$script:UserAgent = "OneDriveOrganizer_JPM_$($Config.ClientId)"

# --- Marqueur mémoire pour rate-limit ---
if (-not $script:LastApiCall) {
$script:LastApiCall = Get-Date
}

# ============================
#   CHARGEMENT DU CACHE
# ============================
function Import-GpsCache {
    try {
        if ($GpsCacheFile -and (Test-Path $GpsCacheFile)) {
            $json = Get-Content $GpsCacheFile -Raw
            if ($json -and $json.Trim() -ne "") {
                $script:GpsCache = $json | ConvertFrom-Json -AsHashtable
                Write-Log "Cache GPS chargé : $($script:GpsCache.Count) entrées" "DEBUG"
                return
            }
        }
        # Si fichier vide ou absent → Hashtable vide
        $script:GpsCache = @{}
        Write-Log "Cache GPS initialisé (vide)" "DEBUG"
    }
    catch {
        Write-Log "Erreur Import-GpsCache: $_" "ERREUR"
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
            Write-Log "Conversion du cache GPS en Hashtable" "DEBUG"
            $new = @{ }
            foreach ($p in $script:GpsCache.PSObject.Properties) {
                $new[$p.Name] = $p.Value
            }
            $script:GpsCache = $new
        }
    }
    catch {
        Write-Log "Échec Initialize-GpsCache: $_" "ERREUR"
    }
} # Initialize-GpsCache

# Sauvegarde le cache GPS dans le fichier JSON global
function Save-GpsCache {
    try {
        if (-not $GpsCacheFile) {
            Write-Log "Save-GpsCache appelé sans GpsCacheFile défini" "WARN"
            return
        }

        $script:GpsCache | ConvertTo-Json | Set-Content $GpsCacheFile
        Write-Log "Cache GPS sauvegardé dans $GpsCacheFile" "DEBUG"
    }
    catch {
        Write-Log "Échec Save-GpsCache: $_" "ERREUR"
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
        Write-Log "Échec Get-GpsGridKey: $_" "ERREUR"
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
        Write-Log "Échec Find-NearbyGpsKey: $_" "ERREUR"
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
        Write-Log "Échec Convert-LocationName: $_" "ERREUR"
    }
} # Convert-LocationName

# Appelle l’API Nominatim pour résoudre une position GPS
function Resolve-GpsApi {
    param([double]$Lat, [double]$Lon)

    try {

        # --- Rate-limit intelligent ---
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
            # Retourner le contenu brut pour debug
            if ($_.Exception.Response) {
                $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
                $raw = $reader.ReadToEnd()
                Write-Log "Réponse brute API GPS: $raw" "ERROR"
                return $raw
            }

            Write-Log "Erreur API GPS: $_" "ERREUR"
        return $null
        }
    }
    catch {
        Write-Log "Échec Resolve-GpsApi: $_" "ERREUR"
    }
} # Resolve-GpsApi

# Répare le cache GPS : normalise clés/noms, fusionne les doublons et réécrit le fichier
function Repair-GpsCache {
    param([string]$CacheFile)

    try {
        Write-Log "Réparation du cache GPS ($CacheFile)" "INFO"

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

        Write-Log "Cache GPS réparé : $($newCache.Count) entrées" "SUCCESS"
    }
    catch {
        Write-Log "Échec Repair-GpsCache: $_" "ERREUR"
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

        $gridKey = Get-GpsGridKey -Lat $lat -Lon $lon

        # 1. Cache exact
        if ($script:GpsCache.ContainsKey($gridKey)) {
            return $script:GpsCache[$gridKey]
        }

        # 2. Clustering
        $near = Find-NearbyGpsKey -Lat $lat -Lon $lon -Cache $script:GpsCache
        if ($near) {
            return $script:GpsCache[$near]
        }

        Write-Log "[API GPS] Résolution ($gridKey)" "WARN"

        # 3. API principale
        $res = Resolve-GpsApi -Lat $lat -Lon $lon

        # 4. Tolérance ±1 km
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

        # Si aucune réponse exploitable
        if (!$res -or !$res.address) {
            Write-Log "=== DEBUG GPS DUMP ===" "ERROR"
            Write-Log "URL : https://nominatim.openstreetmap.org/reverse?format=json&lat=$lat&lon=$lon&zoom=10&addressdetails=1" "ERROR"
            try {
                $raw = $res | ConvertTo-Json -Depth 10
                Write-Log "Réponse JSON brute : $raw" "ERROR"
            }
            catch {
                Write-Log "Réponse brute non JSON : $res" "ERROR"
            }
            Write-Log "Aucun champ address trouvé dans la réponse" "ERROR"
            Write-Log "=== FIN DEBUG GPS DUMP ===" "ERROR"
            Write-Log "GPS introuvable : $gridKey" "WARN"
            return $null
        }

        $addr = $res.address

        # Fallbacks intelligents (ville → municipalité → comté → état → pays)
        $city = $addr.city ??
                $addr.town ??
                $addr.village ??
                $addr.hamlet ??
                $addr.suburb ??
                $addr.neighbourhood ??
                $addr.municipality ??
                $addr.county ??
                $addr.state ??
                $addr.country

        # Fallback ultime si vraiment rien
        if (-not $city) {
            $city = "UNKNOWN-$lat-$lon"
            Write-Log "=== DEBUG GPS DUMP (NO CITY FOUND) ===" "ERROR"
            try {
                $raw = $res | ConvertTo-Json -Depth 10
                Write-Log "Réponse JSON brute : $raw" "ERROR"
            }
            catch {
                Write-Log "Réponse brute non JSON : $res" "ERROR"
            }
            Write-Log "=== FIN DEBUG GPS DUMP ===" "ERROR"
        }
        $state   = $addr.state   ?? $addr.county  ?? "NA"
        $country = $addr.country ?? "NA"


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
        Write-Log "Erreur Get-LocationName: $_" "ERREUR"
        return $null
    }
} # Get-LocationName


# ============================
# EXPORT
# ============================
Export-ModuleMember -Function *