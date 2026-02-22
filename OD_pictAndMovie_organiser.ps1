<#
.SYNOPSIS
    V14.0 - Organisateur avec Feedback détaillé, Chronométrage et Cache GPS Persistant.
    
.DESCRIPTION
    NOMENCLATURE ET ARCHITECTURE CIBLE :
    
    1. PHOTOS (.jpg, .png, .heic) -> /Images/Pellicule/Année/Mois/
       Format : yyyyMMdd_HHmmss_[Ville]_[Dossiers_Tags]_[Nom_Original]_[Appareil].ext
       
    2. VIDÉOS (.mp4, .mov) -> /Vidéos/Pellicule/Année/Mois/
       Format : yyyyMMdd_HHmmss_[Ville]_[Dossiers_Tags]_[Durée]_[Résolution].ext
       
    3. AUDIO (.mp3, .m4a, .flac) -> /Musique/Artiste/Album/
       Format : [Artiste] - [Album] - [Titre].ext

    FONCTIONNEMENT :
    - WhatIf par défaut : Analyse et génère un log sans déplacer de fichiers.
    - Cache GPS Persistant : Sauvegarde automatique à chaque découverte de lieu.
    - Tags de Chemin : Préserve le contexte hiérarchique original.

    FONCTIONNEMENT DU CACHE :
    Si une entrée GPS existe mais ne contient pas la hiérarchie complète (ex: juste "Palma"),
    le script force un rafraîchissement via l'API pour obtenir Province et Pays.
.PARAMETER Execute
    $false (DÉFAUT) : Mode simulation. Génère le fichier de log.
    $true : Applique les changements sur OneDrive.
#>
param (
    [bool]$Execute = $false,
    [string]$LogFile = ".\organisation_log.txt",
    [string]$GpsCacheFile = ".\gps_cache.json"
)

# --- 1. INITIALISATION ---
$IndexFile = ".\onedrive_cache.json"
if (!(Test-Path $IndexFile)) { Write-Error "Cache introuvable."; exit }
$Cache = Get-Content $IndexFile | ConvertFrom-Json -AsHashtable
$FileIds = $Cache.Files.Keys
$TotalFiles = $FileIds.Count
$StartTime = Get-Date

$script:GpsCache = @{}
if (Test-Path $GpsCacheFile) { $script:GpsCache = Get-Content $GpsCacheFile | ConvertFrom-Json -AsHashtable }

# --- 2. FONCTIONS ---

function Get-LocationName($gps) {
    if (!$gps -or $gps -eq "," -or $gps -match "^0,0$") { return $null }
    
    $cachedValue = $script:GpsCache[$gps]
    
    # CRITÈRES DE RAFRAÎCHISSEMENT
    $isIncomplete = $cachedValue -and ($cachedValue -split "-").Count -lt 3
    $hasSpecialChars = $cachedValue -and ($cachedValue -match "[^\x00-\x7F]") # Détecte tout ce qui n'est pas ASCII standard

    if ($cachedValue -and !$isIncomplete -and !$hasSpecialChars) { 
        return $cachedValue 
    }
    
    $reason = if ($hasSpecialChars) { "Caractères Spéciaux" } elseif ($isIncomplete) { "Incomplet" } else { "Nouveau" }
    Write-Host " [API GPS] $reason ($gps)..." -ForegroundColor DarkYellow -NoNewline
    
    try {
        $lat, $lon = $gps -split ","
        $Uri = "https://nominatim.openstreetmap.org/reverse?format=json&lat=$($lat.Trim())&lon=$($lon.Trim())&zoom=10&addressdetails=1"
        $res = Invoke-RestMethod -Uri $Uri -UserAgent "OneDriveOrganizer_JPM" -ErrorAction SilentlyContinue
        
        $addr = $res.address
        $city = if ($addr.city) { $addr.city } elseif ($addr.town) { $addr.town } else { $addr.village }
        $state = if ($addr.state) { $addr.state } else { $addr.county }
        $country = $addr.country

        if ($city -and $country) { 
            # 1. Concaténation
            $fullLoc = "$city-$state-$country" -replace " ", "-"
            
            # 2. Nettoyage strict (ASCII uniquement + tirets)
            # On normalise pour transformer les accents (é -> e) si possible, sinon on supprime le non-latin
            $normalized = $fullLoc.Normalize([System.Text.NormalizationForm]::FormD)
            $cleanBuilder = New-Object System.Text.StringBuilder
            foreach ($char in $normalized.ToCharArray()) {
                if ([System.Globalization.CharUnicodeInfo]::GetUnicodeCategory($char) -ne [System.Globalization.UnicodeCategory]::NonSpacingMark) {
                    [void]$cleanBuilder.Append($char)
                }
            }
            $fullLoc = $cleanBuilder.ToString()
            $fullLoc = [Regex]::Replace($fullLoc, "[^a-zA-Z0-9\-]", "")
            $fullLoc = ($fullLoc -replace "-+", "-").Trim("-")
            
            $script:GpsCache[$gps] = $fullLoc
            $script:GpsCache | ConvertTo-Json | Set-Content $GpsCacheFile
            Write-Host " OK: $fullLoc" -ForegroundColor Green
            Start-Sleep -Milliseconds 1100 
            return $fullLoc
        }
    } catch { Write-Host " Échec." -ForegroundColor Red }
    return $null
}

function Get-PathTags($fullPath) {
    $parts = $fullPath -replace "^/drive/root:/?", "" -split "/" | 
             Where-Object { $_ -and $_ -notmatch "Documents|Images|Vidéos|Musique|Pellicule|JPM" }
    return ($parts -join "_")
}

# --- 3. TRAITEMENT ---
$Log = New-Object System.Collections.Generic.List[string]
$Log.Add("=== RAPPORT V14.5 - $(Get-Date) ===")

Write-Host "`n--- DÉMARRAGE DE L'ANALYSE ($TotalFiles fichiers) ---" -ForegroundColor Cyan

$count = 0
foreach ($id in $FileIds) {
    $count++
    $f = $Cache.Files[$id]
    
    # Progression
    $elapsed = (Get-Date) - $StartTime
    $avgTime = $elapsed.TotalSeconds / $count
    $remainingStr = "{0:hh\:mm\:ss}" -f [TimeSpan]::FromSeconds($avgTime * ($TotalFiles - $count))

    if ($count % 10 -eq 0) {
        Write-Progress -Activity "Analyse $([Math]::Round(($count/$TotalFiles)*100,1))%" `
                       -Status "Fichiers: $count/$TotalFiles | Restant: $remainingStr" `
                       -PercentComplete (($count / $TotalFiles) * 100)
    }

    if (!$f.d) { continue }
    $ext = [System.IO.Path]::GetExtension($f.n).ToLower()
    $dateRef = [DateTime]$f.d
    
    $villeStr = Get-LocationName $f.gps
    $tags = Get-PathTags $f.p
    $name = ([System.IO.Path]::GetFileNameWithoutExtension($f.n) -replace "\(Copie.*\)|- Copie|\(1\)", "").Trim()
    
    $newName = ""
    $targetDir = ""

    # NOMENCLATURE PHOTOS / VIDÉOS
    if ($ext -match ".jpg|.jpeg|.png|.heic|.mp4|.mov") {
        $parts = New-Object System.Collections.Generic.List[string]
        $parts.Add($dateRef.ToString("yyyyMMdd_HHmmss"))
        if ($villeStr) { $parts.Add($villeStr) }
        if ($tags) { $parts.Add($tags) }
        
        if ($ext -match ".mp4|.mov") {
            if($f.dur){$parts.Add($f.dur)}; if($f.res){$parts.Add($f.res)}
            $targetDir = "/Vidéos/Pellicule/$($dateRef.Year)/$($dateRef.ToString('MM'))"
        } else {
            if ($name -and $tags -notlike "*$name*" -and $name -notmatch "^\d+$") { $parts.Add($name) }
            if($f.cam){$parts.Add($f.cam)}
            $targetDir = "/Images/Pellicule/$($dateRef.Year)/$($dateRef.ToString('MM'))"
        }
        $newName = ($parts -join "_") + $ext
    }
    # NOMENCLATURE AUDIO
    elseif ($ext -match ".mp3|.m4a|.flac") {
        $artiste = if($f.art){$f.art}else{"Inconnu"}
        $album = if($f.alb){$f.alb}else{"Inconnu"}
        $newName = "$artiste - $album - $name$ext"
        $targetDir = "/Musique/$artiste/$album"
    }

    if ($newName) {
        $newName = ($newName -replace '[\\\/:*?"<>|]', '-') -replace '_+', '_'
        $Log.Add("SRC : $($f.p)/$($f.n)")
        $Log.Add("DST : $targetDir/$newName")
    }
}

$Log | Set-Content $LogFile
Write-Host "`nTERMINÉ. Log généré : $LogFile" -ForegroundColor Green