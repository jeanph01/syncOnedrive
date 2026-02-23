# ============================================================
# VERSION: 12.6 (Real-Time Feedback & Size-Optimized)
# ============================================================
param (
    [ValidateSet("Online", "Offline")]
    [string]$Mode = "Online",
    [switch]$ForceNewScan = $true
)

$ProgressPreference = 'SilentlyContinue' # Désactivé car Write-Host est plus fluide pour des milliers de fichiers
Clear-Host

# ---------------- EN-TÊTE D'AFFICHAGE ----------------
$TimeStart = Get-Date
$Header = @"
************************************************************
  ONEDRIVE INDEXER & CLEANUP - V12.6
************************************************************
  Date de lancement : $($TimeStart.ToString("dd/MM/yyyy HH:mm:ss"))
  Mode sélectionné  : $Mode
  Forcer Scan      : $($ForceNewScan ? "OUI" : "NON")
  Dossier cible    : D:\recup
************************************************************
"@
Write-Host $Header -ForegroundColor Cyan

# ---------------- CONFIGURATION ----------------
$LocalFolder    = "D:\recup"
$IndexFile      = ".\onedrive_cache.json"
$ReportFile     = ".\onedrive_doublons_rapport.txt"
$DupFolder      = Join-Path $LocalFolder "_Doublons"
$ClientId       = "176fc7bc-42c9-4a25-82b5-0ad584d3c061"

$AllowedExt = @(
    ".avi",".mov",".mp4",".mpg",".mpeg",".mkv",".wmv",".flv",".webm",".m4v",".3gp",
    ".bmp",".gif",".jpg",".jpeg",".png",".svg",".tiff",".tif",".webp",".heic",".heif",".psd",".ai",".xcf",".ico",".thm",
    ".doc",".docx",".xls",".xlsx",".ppt",".pptx",".pdf",".rtf",".txt",".odt",".wpd",".epub",".pages",
    ".msg",".eml",".mp3",".wav",".m4a",".flac",".amr",".opus",
    ".html",".htm",".zip",".7z",".rar",".csv",".json",".xml"
)

# ---------------- 1. CHARGEMENT / SCAN ----------------
$script:Cache = @{ Files = @{} }
if ($ForceNewScan -and (Test-Path $IndexFile)) { 
    Write-Host "[!] Suppression de l'ancien cache..." -ForegroundColor Yellow
    Remove-Item $IndexFile -Force 
}

if ($Mode -eq "Online") {
    Write-Host "[1/4] Connexion Microsoft Graph..." -ForegroundColor Cyan
    $DeviceCode = Invoke-RestMethod -Method POST -Uri "https://login.microsoftonline.com/common/oauth2/v2.0/devicecode" -Body @{ client_id = $ClientId; scope = "Files.Read.All" }
    Write-Host "`n$($DeviceCode.message)`n" -ForegroundColor Yellow
    $Auth = $null; while (!$Auth) { Start-Sleep 5; try { $Auth = Invoke-RestMethod -Method POST -Uri "https://login.microsoftonline.com/common/oauth2/v2.0/token" -Body @{ grant_type = "urn:ietf:params:oauth:grant-type:device_code"; client_id = $ClientId; device_code = $DeviceCode.device_code } } catch {} }
    $Headers = @{ Authorization = "Bearer $($Auth.access_token)" }

    $Uri = "https://graph.microsoft.com/v1.0/me/drive/root/delta?`$select=name,id,size,file,hashes,fileSystemInfo,parentReference,photo,location,video,audio,image"
    while ($Uri) {
        try {
            $Res = Invoke-RestMethod -Headers $Headers -Uri $Uri -Method GET
            foreach ($item in $Res.value) {
                if ($item.file -and $item.file.hashes.sha1Hash) { 
                    $entry = @{ n = $item.name; s = $item.size; h = $item.file.hashes.sha1Hash.ToLower(); d = $item.fileSystemInfo.lastModifiedDateTime; p = $item.parentReference.path }
                    $script:Cache.Files[$item.id] = $entry
                }
            }
            $Uri = $Res.'@odata.nextLink'
            Write-Host " -> Indexé : $($script:Cache.Files.Count) fichiers..." -ForegroundColor Gray
        } catch { Start-Sleep -Seconds 5 }
    }
    $script:Cache | ConvertTo-Json -Depth 10 | Set-Content $IndexFile
} else {
    if (Test-Path $IndexFile) {
        $script:Cache = Get-Content $IndexFile | ConvertFrom-Json -AsHashtable
        Write-Host "[1/4] Cache chargé ($($script:Cache.Files.Count) fichiers)." -ForegroundColor Gray
    } else {
        Write-Host "[!] ERREUR : Fichier cache absent. Lancez en mode -Online." -ForegroundColor Red; return
    }
}

# ---------------- 2. RAPPORT DES DOUBLONS SUR ONEDRIVE ----------------
Write-Host "[2/4] Analyse des doublons sur OneDrive..." -ForegroundColor Yellow
$HashGroups = @{}
foreach ($item in $script:Cache.Files.Values) {
    if (!$HashGroups.ContainsKey($item.h)) { $HashGroups[$item.h] = New-Object System.Collections.Generic.List[Object] }
    $HashGroups[$item.h].Add($item)
}

$CloudDupCount = 0
foreach ($h in $HashGroups.Keys) { if ($HashGroups[$h].Count -gt 1) { $CloudDupCount++ } }
Write-Host " -> Terminé : $CloudDupCount groupes de doublons trouvés sur le Cloud." -ForegroundColor Green

# ---------------- 3. NETTOYAGE LOCAL OPTIMISÉ ----------------
Write-Host "[3/4] Analyse locale et comparaison..." -ForegroundColor Cyan
if (!(Test-Path $DupFolder)) { New-Item -ItemType Directory -Path $DupFolder -Force | Out-Null }

$CloudSizes = @{}
$Lookup = @{}
foreach ($f in $script:Cache.Files.Values) { 
    $CloudSizes[$f.s] = $true 
    $Lookup[$f.h] = $true
}

$LocalFiles = Get-ChildItem -Path $LocalFolder -File -Recurse | Where-Object { $_.FullName -notlike "*_Doublons*" }
$cDel = 0; $cMove = 0; $cSkipped = 0; $total = $LocalFiles.Count; $i = 0

foreach ($file in $LocalFiles) {
    $i++
    $pct = [Math]::Round(($i / $total) * 100, 1)
    
    # 1. Filtre Extension
    if ($AllowedExt -notcontains $file.Extension.ToLower()) { 
        Remove-Item -LiteralPath $file.FullName -Force
        $cDel++
        continue 
    }

    # 2. OPTIMISATION : Filtre par taille
    if (-not $CloudSizes.ContainsKey($file.Length)) {
        if ($i % 100 -eq 0) { Write-Host "[$pct%] Analyse : $i/$total (Passage rapide...)" -ForegroundColor DarkGray }
        $cSkipped++
        continue
    }

    # 3. CALCUL HASH (Uniquement si taille identique détectée)
    # On affiche AVANT pour voir quel fichier "bloque"
    Write-Host "[$pct%] HASHING : $($file.Name) ($([Math]::Round($file.Length/1MB,1)) MB)... " -ForegroundColor Yellow -NoNewline
    $sha1 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA1).Hash.ToLower()

    if ($Lookup.ContainsKey($sha1)) {
        $dest = Join-Path $DupFolder $file.Name
        $idx = 1
        while (Test-Path -LiteralPath $dest) { $dest = Join-Path $DupFolder "$($file.BaseName)_$idx$($file.Extension)"; $idx++ }
        Move-Item -LiteralPath $file.FullName -Destination $dest -Force
        $cMove++
        Write-Host "DOUBLON !" -ForegroundColor Green
    } else {
        Write-Host "Unique." -ForegroundColor Gray
    }
}

# ---------------- 4. DOSSIERS VIDES ----------------
Write-Host "[4/4] Nettoyage dossiers locaux..." -ForegroundColor Gray
Get-ChildItem -Path $LocalFolder -Directory -Recurse | Sort-Object { $_.FullName.Length } -Descending | ForEach-Object {
    if ((Get-ChildItem -LiteralPath $_.FullName -ErrorAction SilentlyContinue).Count -eq 0) {
        if ($_.FullName -notlike "*_Doublons*") { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
    }
}

# ---------------- BILAN ----------------
$Duration = (Get-Date) - $TimeStart
Write-Host "`n[BILAN FINAL]" -ForegroundColor White -BackgroundColor DarkCyan
Write-Host "- Temps écoulé         : $($Duration.Minutes)m $($Duration.Seconds)s"
Write-Host "- Fichiers locaux total : $total"
Write-Host "- Ignorés (Taille diff) : $cSkipped"
Write-Host "- Doublons Cloud       : $CloudDupCount"
Write-Host "- Doublons Locaux écartés: $cMove"
Write-Host "- Fichiers supprimés    : $cDel (Ext. non autorisées)"