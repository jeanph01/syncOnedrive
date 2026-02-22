# ============================================================
# ONEDRIVE INDEXER & CLEANUP - V11.9 (CACHE LISIBLE + ONLINE)
# ============================================================
param (
    [ValidateSet("Online", "Offline")]
    [string]$Mode = "Online",
    [switch]$ForceNewScan = $true
)

$ProgressPreference = 'SilentlyContinue'
Clear-Host

# ---------------- CONFIGURATION ----------------
$LocalFolder    = "D:\recup"
$IndexFile      = ".\onedrive_cache.json"
$DupFolder      = Join-Path $LocalFolder "_Doublons"
$ClientId       = "176fc7bc-42c9-4a25-82b5-0ad584d3c061"

$AllowedExt = @(".avi",".mov",".mp4",".mpg",".mpeg",".mkv",".wmv",".flv",".webm",".m4v",".bmp",".gif",".jpg",".jpeg",".png",".svg",".tiff",".tif",".webp",".heic",".heif",".psd",".ai",".doc",".docx",".xls",".xlsx",".ppt",".pptx",".pdf",".rtf",".zip",".7z",".rar",".txt")

# ---------------- 1. CHARGEMENT DU CACHE ----------------
$script:Cache = @{ Files = @{} }
if ($ForceNewScan -and (Test-Path $IndexFile)) { Remove-Item $IndexFile -Force }

if (Test-Path $IndexFile) {
    Write-Host "[1/4] Chargement de l'index..." -ForegroundColor Gray
    $Loaded = Get-Content $IndexFile | ConvertFrom-Json -AsHashtable
    if ($Loaded.Files) { $script:Cache.Files = $Loaded.Files }
    Write-Host " -> OK : $($script:Cache.Files.Count) fichiers en mémoire." -ForegroundColor Green
}

if (!(Test-Path $DupFolder)) { New-Item -ItemType Directory -Path $DupFolder -Force | Out-Null }

# ---------------- 2. SCAN DELTA (ONLINE) ----------------
if ($Mode -eq "Online") {
    Write-Host "[2/4] Connexion Microsoft Graph..." -ForegroundColor Cyan
    $DeviceCode = Invoke-RestMethod -Method POST -Uri "https://login.microsoftonline.com/common/oauth2/v2.0/devicecode" -Body @{ client_id = $ClientId; scope = "Files.Read.All" }
    Write-Host "`n$($DeviceCode.message)`n" -ForegroundColor Yellow
    
    $Auth = $null; while (!$Auth) { Start-Sleep 5; try { $Auth = Invoke-RestMethod -Method POST -Uri "https://login.microsoftonline.com/common/oauth2/v2.0/token" -Body @{ grant_type = "urn:ietf:params:oauth:grant-type:device_code"; client_id = $ClientId; device_code = $DeviceCode.device_code } } catch {} }
    $Headers = @{ Authorization = "Bearer $($Auth.access_token)" }

    $Uri = "https://graph.microsoft.com/v1.0/me/drive/root/delta?`$select=name,id,size,file,hashes,fileSystemInfo,parentReference"
    
    Write-Host "Mise à jour de l'index OneDrive..." -ForegroundColor Cyan
    while ($Uri) {
        try {
            $Res = Invoke-RestMethod -Headers $Headers -Uri $Uri -Method GET
            foreach ($item in $Res.value) {
                if ($item.file -and $item.file.hashes.sha1Hash) { 
                    $script:Cache.Files[$item.id] = @{
                        n = $item.name
                        s = $item.size
                        h = $item.file.hashes.sha1Hash.ToLower()
                        d = $item.fileSystemInfo.lastModifiedDateTime
                        p = $item.parentReference.path
                    }
                }
            }
            $Uri = $Res.'@odata.nextLink'
            Write-Host " -> Indexé : $($script:Cache.Files.Count) fichiers..." -ForegroundColor Gray
            
            # Sauvegarde propre et lisible (formatée)
            $script:Cache | ConvertTo-Json -Depth 10 | Set-Content $IndexFile
        } catch {
            Start-Sleep -Seconds 5
        }
    }
}

# ---------------- 3. ANALYSE ET COMPARAISON ----------------
Write-Host "[3/4] Analyse locale et comparaison..." -ForegroundColor Cyan
$Lookup = @{}
foreach ($f in $script:Cache.Files.Values) { $Lookup[$f.h] = $f.p }

$LocalFiles = Get-ChildItem -Path $LocalFolder -File -Recurse | Where-Object { $_.FullName -notlike "*_Doublons*" }
$cDel = 0; $cMove = 0; $total = $LocalFiles.Count; $i = 0

foreach ($file in $LocalFiles) {
    $i++; $ext = $file.Extension.ToLower()
    Write-Progress -Activity "Vérification des doublons" -Status "$i/$total : $($file.Name)" -PercentComplete (($i/$total)*100)

    if ($AllowedExt -notcontains $ext) {
        Remove-Item -LiteralPath $file.FullName -Force
        $cDel++; continue
    }

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

# ---------------- 4. NETTOYAGE FINAL ----------------
Write-Host "[4/4] Nettoyage des dossiers vides..." -ForegroundColor Gray
Get-ChildItem -Path $LocalFolder -Directory -Recurse | Sort-Object { $_.FullName.Length } -Descending | ForEach-Object {
    try {
        $items = Get-ChildItem -LiteralPath $_.FullName -ErrorAction SilentlyContinue
        if ($null -eq $items -or $items.Count -eq 0) {
            if ($_.FullName -notlike "*_Doublons*") {
                Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
            }
        }
    } catch {}
}

Write-Host "`n[BILAN]" -ForegroundColor White -BackgroundColor DarkGreen
Write-Host "- OneDrive : $($script:Cache.Files.Count) fichiers"
Write-Host "- Supprimés : $cDel"
Write-Host "- Doublons : $cMove"