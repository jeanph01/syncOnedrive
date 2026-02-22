<#
.SYNOPSIS
    V14.8 - Organisateur Ultra-Rapide (Arrondi 1km / 2 décimales).
    
.DESCRIPTION
    NOMENCLATURE ET ARCHITECTURE CIBLE :
    1. PHOTOS (.jpg, .png, .heic) -> /Images/Pellicule/Année/Mois/
       Format : yyyyMMdd_HHmmss_[Ville-Province-Pays]_[Tags]_[Nom]_[Appareil].ext
    2. VIDÉOS (.mp4, .mov) -> /Vidéos/Pellicule/Année/Mois/
       Format : yyyyMMdd_HHmmss_[Ville-Province-Pays]_[Tags]_[Durée]_[Résol].ext
    3. AUDIO (.mp3, .m4a, .flac) -> /Musique/Artiste/Album/
       Format : [Artiste] - [Album] - [Titre].ext

    OPTIMISATION GPS : 
    Arrondi à 2 décimales (~1.1 km). Idéal pour grouper massivement les requêtes API.
#>

<#
.SYNOPSIS
    V15.5 - Limite Stricte 100 Caractères & Nettoyage Redondance.
#>

param (
    [bool]$Execute = $false,
    [string]$LogFile = ".\organisation_log.txt",
    [string]$GpsCacheFile = ".\gps_cache.json"
)

Clear-Host

# --- 1. INITIALISATION ---
$IndexFile = ".\onedrive_cache.json"
if (!(Test-Path $IndexFile)) { Write-Error "Cache JSON introuvable."; exit }

Write-Host "--- OPTIMISATION POUR NOMS COURTS (Max 100 char) ---" -ForegroundColor Cyan
$Cache = Get-Content $IndexFile | ConvertFrom-Json -AsHashtable
$FileIds = $Cache.Files.Keys
$script:GpsCache = @{}
if (Test-Path $GpsCacheFile) { $script:GpsCache = Get-Content $GpsCacheFile | ConvertFrom-Json -AsHashtable }

# --- 2. FONCTIONS DE COMPRESSION ---

function Get-PathTags($fullPath) {
    # On ignore les dossiers racines et chronologiques
    $parts = $fullPath -replace "^/drive/root:/?", "" -split "/" | 
             Where-Object { $_ -and $_ -notmatch "^(Documents|Images|Vidéos|Musique|Pellicule|JPM|drive|root|\d{4}|\d{2})$" }
    
    if ($parts.Count -eq 0) { return "" }
    [array]::Reverse($parts)
    
    $compactTags = New-Object System.Collections.Generic.List[string]
    $currentLength = 0
    $MaxChars = 25 # Limite très serrée pour les tags de dossiers

    foreach ($p in $parts) {
        if (($currentLength + $p.Length) -lt $MaxChars) {
            $compactTags.Add($p)
            $currentLength += $p.Length + 1
        } else { break }
    }
    $final = $compactTags.ToArray(); [array]::Reverse($final)
    return ($final -join "_")
}

# --- 3. GÉNÉRATION DU LOG ---
Write-Host "Traitement des $($FileIds.Count) fichiers..." -ForegroundColor Green
$Log = New-Object System.Collections.Generic.List[string]

foreach ($id in $FileIds) {
    $f = $Cache.Files[$id]
    if (!$f.d) { continue }

    # Extraction Ville (On ne garde que le premier mot de la ville pour gagner de la place)
    $villeStr = $null
    if ($f.gps) {
        $latRaw, $lonRaw = $f.gps -split ","
        $approx = "$([Math]::Round([double]$latRaw.Trim(), 2)),$([Math]::Round([double]$lonRaw.Trim(), 2))"
        $fullVille = $script:GpsCache[$approx]
        if ($fullVille) { $villeStr = ($fullVille -split "-")[0] } # Juste "Montreal" au lieu de "Montreal-Quebec-Canada"
    }
    
    $ext = [System.IO.Path]::GetExtension($f.n).ToLower()
    $ts = ([DateTime]$f.d).ToString("yyyyMMdd_HHmmss")
    $tags = Get-PathTags $f.p
    
    # Nettoyage du nom original
    $cleanName = [System.IO.Path]::GetFileNameWithoutExtension($f.n) -replace "\(Copie.*\)|- Copie|\(1\)", ""
    # Supprimer si c'est une date (ex: 20231225...)
    if ($cleanName -match "\d{8}") { $cleanName = "" }
    $cleanName = $cleanName.Trim("_").Trim("-").Trim()

    # Assemblage intelligent
    $parts = New-Object System.Collections.Generic.List[string]
    $parts.Add($ts)
    if ($villeStr) { $parts.Add($villeStr) }
    if ($tags) { $parts.Add($tags) }
    
    if ($ext -match ".mp4|.mov") {
        if($f.dur){$parts.Add($f.dur)}
        $targetDir = "/Vidéos/Pellicule/$(([DateTime]$f.d).Year)/$(([DateTime]$f.d).ToString('MM'))"
    } else {
        # On n'ajoute le nom d'origine que s'il reste beaucoup de place
        if ($cleanName -and $cleanName.Length -gt 2 -and $cleanName -notmatch "^\d+$") { $parts.Add($cleanName) }
        $targetDir = "/Images/Pellicule/$(([DateTime]$f.d).Year)/$(([DateTime]$f.d).ToString('MM'))"
    }
    
    # --- LA LIMITE DES 100 CARACTÈRES ---
    $finalBase = ($parts -join "_") -replace '[\\\/:*?"<>|]', '-' -replace '_+', '_'
    
    # Si trop long, on coupe à 100 moins l'extension
    $maxBaseLength = 100 - $ext.Length
    if ($finalBase.Length -gt $maxBaseLength) {
        $finalBase = $finalBase.Substring(0, $maxBaseLength).Trim("_")
    }
    
    $newName = $finalBase + $ext
    $Log.Add("SRC : $($f.p)/$($f.n) | DST : $targetDir/$newName")
}

$Log | Set-Content $LogFile
Write-Host "`nTerminé ! Noms limités à 100 caractères." -ForegroundColor Cyan