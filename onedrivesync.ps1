# ============================================================
# ONEDRIVE INDEXER & CLEANUP - V12.4 (RAPPORT DOUBLONS CLOUD)
# ============================================================
# ============================================================
# SCRIPT : ONEDRIVE INDEXER & CLEANUP
# VERSION: 12.5 (Optimisée - Performance & Visibilité)
# ============================================================
param (
    [ValidateSet("Online", "Offline")]
    [string]$Mode = "Offline",
    [switch]$ForceNewScan = $false
)

$ProgressPreference = 'Continue' # Activé pour voir la barre de progression
Clear-Host

# ---------------- EN-TÊTE D'AFFICHAGE ----------------
$TimeStart = Get-Date
$Header = @"
************************************************************
  ONEDRIVE INDEXER & CLEANUP - V12.5
************************************************************
  Date de lancement : $($TimeStart.ToString("dd/MM/yyyy HH:mm:ss"))
  Mode sélectionné  : $Mode
  Forcer Scan      : $($ForceNewScan ? "OUI" : "NON")
  Dossier cible    : D:\recup
************************************************************
"@
Write-Host $Header -ForegroundColor Cyan

# ---------------- CONFIGURATION ----------------
# ---------------- CONFIGURATION ----------------
$LocalFolder    = "D:\recup"
$IndexFile      = ".\onedrive_cache.json"
$ReportFile     = ".\onedrive_doublons_rapport.txt"
$DupFolder      = Join-Path $LocalFolder "_Doublons"
$ClientId       = "176fc7bc-42c9-4a25-82b5-0ad584d3c061"

$AllowedExt = @(
    # Vidéos
    ".avi",".mov",".mp4",".mpg",".mpeg",".mkv",".wmv",".flv",".webm",".m4v",".3gp",
    # Images & Graphisme
    ".bmp",".gif",".jpg",".jpeg",".png",".svg",".tiff",".tif",".webp",".heic",".heif",".psd",".ai",".xcf",".ico",".thm",
    # Documents & Livres (Ajout EPUB)
    ".doc",".docx",".xls",".xlsx",".ppt",".pptx",".pdf",".rtf",".txt",".odt",".wpd",".epub",".pages",
    # Emails
    ".msg",".eml",
    # Audio (Ajout AMR)
    ".mp3",".wav",".m4a",".flac",".amr",".opus",
    # Web & Archives
    ".html",".htm",".zip",".7z",".rar",".csv",".json",".xml"
)
# ---------------- 1. CHARGEMENT / SCAN ----------------
$script:Cache = @{ Files = @{} }
if ($ForceNewScan -and (Test-Path $IndexFile)) { Remove-Item $IndexFile -Force }

if ($Mode -eq "Online") {
    Write-Host "[1/4] Connexion Microsoft Graph..." -ForegroundColor Cyan
    $DeviceCode = Invoke-RestMethod -Method POST -Uri "https://login.microsoftonline.com/common/oauth2/v2.0/devicecode" -Body @{ client_id = $ClientId; scope = "Files.Read.All" }
    Write-Host "`n$($DeviceCode.message)`n" -ForegroundColor Yellow
    $Auth = $null; while (!$Auth) { Start-Sleep 5; try { $Auth = Invoke-RestMethod -Method POST -Uri "https://login.microsoftonline.com/common/oauth2/v2.0/token" -Body @{ grant_type = "urn:ietf:params:oauth:grant-type:device_code"; client_id = $ClientId; device_code = $DeviceCode.device_code } } catch {} }
    $Headers = @{ Authorization = "Bearer $($Auth.access_token)" }

    $Uri = "https://graph.microsoft.com/v1.0/me/drive/root/delta?`$select=name,id,size,file,hashes,fileSystemInfo,parentReference,photo,location,video,audio,image"
    Write-Host "Indexation multimédia en cours..." -ForegroundColor Cyan
    while ($Uri) {
        try {
            $Res = Invoke-RestMethod -Headers $Headers -Uri $Uri -Method GET
            foreach ($item in $Res.value) {
                if ($item.file -and $item.file.hashes.sha1Hash) { 
                    $entry = @{ n = $item.name; s = $item.size; h = $item.file.hashes.sha1Hash.ToLower(); d = $item.fileSystemInfo.lastModifiedDateTime; p = $item.parentReference.path }
                    if ($item.audio) { if ($item.audio.duration) { $entry.dur = "$([Math]::Round($item.audio.duration / 1000))s" }; if ($item.audio.samplingRate) { $entry.smpl = $item.audio.samplingRate } }
                    if ($item.video) { if ($item.video.duration) { $entry.dur = "$([Math]::Round($item.video.duration / 1000))s" }; $entry.res = "$($item.video.width)x$($item.video.height)" }
                    if ($item.image) { $entry.res = "$($item.image.width)x$($item.image.height)" }
                    if ($item.photo.cameraModel) { $entry.cam = $item.photo.cameraModel }
                    if ($item.location) { $entry.gps = "$($item.location.latitude), $($item.location.longitude)" }
                    $script:Cache.Files[$item.id] = $entry
                }
            }
            $Uri = $Res.'@odata.nextLink'
            Write-Host " -> Indexé : $($script:Cache.Files.Count) fichiers..." -ForegroundColor Gray
        } catch { Start-Sleep -Seconds 5 }
    }
    $script:Cache | ConvertTo-Json -Depth 10 | Set-Content $IndexFile
} else {
    $script:Cache = Get-Content $IndexFile | ConvertFrom-Json -AsHashtable
}

# ---------------- 2. RAPPORT DES DOUBLONS SUR ONEDRIVE ----------------
Write-Host "[2/4] Analyse des doublons sur OneDrive..." -ForegroundColor Yellow
$HashGroups = @{}
foreach ($item in $script:Cache.Files.Values) {
    if (!$HashGroups.ContainsKey($item.h)) { $HashGroups[$item.h] = New-Object System.Collections.Generic.List[Object] }
    $HashGroups[$item.h].Add($item)
}

$Report = New-Object System.Text.StringBuilder
[void]$Report.AppendLine("=== RAPPORT DES DOUBLONS SUR ONEDRIVE ($(Get-Date)) ===")
[void]$Report.AppendLine("Fichiers ayant le même contenu (SHA1 identique)`n")

$CloudDupCount = 0
foreach ($h in $HashGroups.Keys) {
    if ($HashGroups[$h].Count -gt 1) {
        $CloudDupCount++
        [void]$Report.AppendLine("HASH: $h")
        foreach ($f in $HashGroups[$h]) {
            [void]$Report.AppendLine("  - Nom: $($f.n) | Chemin: $($f.p)")
        }
        [void]$Report.AppendLine("-" * 50)
    }
}
$Report.ToString() | Set-Content $ReportFile -Encoding UTF8
Write-Host " -> Terminé : $CloudDupCount groupes de doublons trouvés sur le Cloud." -ForegroundColor Green

# ... (Gardez vos sections 1 et 2 identiques)

# ---------------- 3. NETTOYAGE LOCAL OPTIMISÉ ----------------
Write-Host "[3/4] Analyse locale et comparaison (Optimisée)..." -ForegroundColor Cyan
if (!(Test-Path $DupFolder)) { New-Item -ItemType Directory -Path $DupFolder -Force | Out-Null }

# Création d'un dictionnaire des tailles présentes sur OneDrive pour un filtrage ultra-rapide
$CloudSizes = @{}
foreach ($f in $script:Cache.Files.Values) { 
    $CloudSizes[$f.s] = $true 
}

# Index des Hashs pour la recherche finale
$Lookup = @{}
foreach ($f in $script:Cache.Files.Values) { $Lookup[$f.h] = $true }

$LocalFiles = Get-ChildItem -Path $LocalFolder -File -Recurse | Where-Object { $_.FullName -notlike "*_Doublons*" }
$cDel = 0; $cMove = 0; $total = $LocalFiles.Count; $i = 0
$cSkipped = 0

foreach ($file in $LocalFiles) {
    $i++
    $ext = $file.Extension.ToLower()
    
    # Mise à jour de la progression (tous les 10 fichiers pour ne pas ralentir le script)
    if ($i % 10 -eq 0 -or $i -eq $total) {
        $percent = [Math]::Round(($i / $total) * 100, 1)
        Write-Progress -Activity "Comparaison locale" -Status "Fichier $i/$total ($percent%) - Nom: $($file.Name)" -PercentComplete $percent
    }

    # 1. Filtre Extension
    if ($AllowedExt -notcontains $ext) { 
        Remove-Item -LiteralPath $file.FullName -Force
        $cDel++
        continue 
    }

    # 2. OPTIMISATION : Filtre par taille avant calcul du Hash
    # Si la taille du fichier local n'existe pas sur OneDrive, inutile de calculer le SHA1
    if (-not $CloudSizes.ContainsKey($file.Length)) {
        $cSkipped++
        continue
    }

    # 3. Calcul du Hash (Uniquement si la taille correspond)
    $sha1 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA1).Hash.ToLower()
    
    if ($Lookup.ContainsKey($sha1)) {
        $dest = Join-Path $DupFolder $file.Name
        $idx = 1
        while (Test-Path -LiteralPath $dest) { 
            $dest = Join-Path $DupFolder "$($file.BaseName)_$idx$($file.Extension)"
            $idx++ 
        }
        Move-Item -LiteralPath $file.FullName -Destination $dest -Force
        $cMove++
    }
}
Write-Progress -Activity "Comparaison locale" -Completed


# ---------------- 4. DOSSIERS VIDES ----------------
Write-Host "[4/4] Nettoyage dossiers locaux..." -ForegroundColor Gray
Get-ChildItem -Path $LocalFolder -Directory -Recurse | Sort-Object { $_.FullName.Length } -Descending | ForEach-Object {
    try {
        $items = Get-ChildItem -LiteralPath $_.FullName -ErrorAction SilentlyContinue
        if ($null -eq $items -or $items.Count -eq 0) {
            if ($_.FullName -notlike "*_Doublons*") { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
        }
    } catch {}
}

Write-Host "`n[BILAN]" -ForegroundColor White -BackgroundColor DarkCyan
Write-Host "- Doublons Cloud détectés : $CloudDupCount (voir $ReportFile)"
Write-Host "- Doublons Locaux écartés  : $cMove"