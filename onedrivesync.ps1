# ============================================================
# ONEDRIVE DEEP INDEXER & CLEANUP - V10.4 (CLEAN DISPLAY)
# ============================================================
param (
    [ValidateSet("Online", "Offline")]
    [string]$Mode = "Online",
    [switch]$Silent = $true 
)

# Supprime les barres de progression natives de PowerShell (la ligne bleue/blanche)
$ProgressPreference = 'SilentlyContinue'
Clear-Host

# ---------------- CONFIGURATION ----------------
$LocalFolder    = "D:\recup"
$ClientId       = "176fc7bc-42c9-4a25-82b5-0ad584d3c061"
$TenantId       = "common"
$IndexFile      = ".\onedrive_cache.json"
$ReportFolder   = ".\Reports"
$DupFolder      = Join-Path $LocalFolder "_Doublons"

# ---------------- NETTOYAGE INITIAL ----------------
Write-Host "[0/5] Nettoyage des anciens fichiers..." -ForegroundColor Gray
if (Test-Path $IndexFile) { Remove-Item $IndexFile -Force -ErrorAction SilentlyContinue }
if (Test-Path $ReportFolder) { Remove-Item $ReportFolder -Recurse -Force -ErrorAction SilentlyContinue }

if (!(Test-Path $DupFolder)) { New-Item -ItemType Directory -Path $DupFolder -Force | Out-Null }
if (!$Silent) { New-Item -ItemType Directory -Path $ReportFolder -Force | Out-Null }

$AllowedExt = @(".avi",".mov",".mp4",".mpg",".mpeg",".mkv",".wmv",".flv",".webm",".m4v",".bmp",".gif",".jpg",".jpeg",".png",".svg",".tiff",".tif",".webp",".heic",".heif",".psd",".ai",".doc",".docx",".docm",".dotx",".xls",".xlsx",".xlsm",".xlsb",".ppt",".pptx",".pptm",".pdf",".rtf",".txt",".csv",".odt",".ods",".odp",".mp3",".wav",".wma",".aac",".flac",".m4a",".ogg",".zip",".7z",".rar",".tar",".gz")

$script:Cache = [ordered]@{ Files = [ordered]@{} }
$script:folderCount = 0

# ---------------- LOGIQUE DE SCAN RÉCURSIF ----------------
if ($Mode -eq "Online") {
    Write-Host "[2/5] Connexion à Microsoft Graph (Deep Scan)..." -ForegroundColor Cyan
    $Scopes = "offline_access openid Files.Read.All"
    
    $DeviceCode = Invoke-RestMethod -Method POST -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/devicecode" -Body @{ client_id = $ClientId; scope = $Scopes }
    Write-Host "`n" $DeviceCode.message "`n" -ForegroundColor Yellow
    
    $Auth = $null
    while (!$Auth) { Start-Sleep 5; try { $Auth = Invoke-RestMethod -Method POST -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" -Body @{ grant_type = "urn:ietf:params:oauth:grant-type:device_code"; client_id = $ClientId; device_code = $DeviceCode.device_code } } catch {} }
    $AccessToken = $Auth.access_token

    function Get-OneDriveRecursive {
        param ($FolderId = "root", $Path = "Racine")
        $Uri = "https://graph.microsoft.com/v1.0/me/drive/items/$FolderId/children?`$select=name,id,size,file,folder,hashes&`$top=999"
        
        while ($Uri) {
            try {
                $Response = Invoke-RestMethod -Headers @{ Authorization = "Bearer $AccessToken" } -Uri $Uri -Method GET
                foreach ($item in $Response.value) {
                    if ($item.file) { $script:Cache.Files[$item.id] = $item }
                    elseif ($item.folder) {
                        if ($item.name -match "Vault|Coffre-fort") { continue }
                        $script:folderCount++
                        Write-Host "  Exploration : $Path/$($item.name) ($($script:Cache.Files.Count) fichiers...)" -ForegroundColor Gray
                        
                        if ($script:folderCount % 10 -eq 0) {
                            $script:Cache | ConvertTo-Json -Depth 10 | Set-Content $IndexFile
                        }
                        Get-OneDriveRecursive -FolderId $item.id -Path "$Path/$($item.name)"
                    }
                }
                $Uri = $Response.'@odata.nextLink'
            } catch { $Uri = $null }
        }
    }

    Write-Host "Début de l'énumération récursive..." -ForegroundColor Cyan
    Get-OneDriveRecursive
    $script:Cache | ConvertTo-Json -Depth 10 | Set-Content $IndexFile
}

# ---------------- ANALYSE LOCALE ----------------
Write-Host "[3/5] Préparation des index..." -ForegroundColor Gray
$CloudSha1List = [string[]]($script:Cache.Files.Values | Where-Object { $_.file.hashes.sha1Hash } | ForEach-Object { $_.file.hashes.sha1Hash.ToLower() })
$CloudPathList = [string[]]($script:Cache.Files.Values | ForEach-Object { "$($_.name.ToLower())|$($_.size)" })

Write-Host "[4/5] Analyse disque (Multithread)..." -ForegroundColor Cyan
$AllLocalFiles = Get-ChildItem -Path $LocalFolder -File -Recurse | Where-Object { $_.FullName -notlike "*_Doublons*" -and $_.FullName -notlike "*$ReportFolder*" }

$results = $AllLocalFiles | ForEach-Object -Parallel {
    $file = $_
    $ext = [System.IO.Path]::GetExtension($file.FullName).ToLower()
    if ($using:AllowedExt -notcontains $ext) { return [PSCustomObject]@{ Action = 'Delete'; Path = $file.FullName } }
    $localSha1 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA1).Hash.ToLower()
    $key = "$($file.Name.ToLower())|$($file.Length)"
    if ($using:CloudSha1List -contains $localSha1 -or $using:CloudPathList -contains $key) {
        return [PSCustomObject]@{ Action = 'Move'; Path = $file.FullName; Name = $file.Name; Hash = $localSha1 }
    } else {
        return [PSCustomObject]@{ Action = 'Keep'; Path = $file.FullName; Name = $file.Name; Hash = $localSha1; Size = $file.Length }
    }
} -ThrottleLimit 8

# ---------------- ACTIONS ----------------
Write-Host "[5/5] Nettoyage et Tri..." -ForegroundColor Cyan
$NotBackedUp = @(); $DupEntries = @()

foreach ($res in $results) {
    switch ($res.Action) {
        'Delete' { Remove-Item -LiteralPath $res.Path -Force -ErrorAction SilentlyContinue }
        'Move' {
            $dest = Join-Path $DupFolder $res.Name
            $idx = 1; while (Test-Path $dest) { $dest = Join-Path $DupFolder "$([System.IO.Path]::GetFileNameWithoutExtension($res.Name))_$idx$([System.IO.Path]::GetExtension($res.Name))"; $idx++ }
            Move-Item -LiteralPath $res.Path -Destination $dest -Force -ErrorAction SilentlyContinue
            if (!$Silent) { $DupEntries += [PSCustomObject]@{ Path = $res.Path; Hash = $res.Hash; Date = (Get-Date) } }
        }
        'Keep' { if (!$Silent) { $NotBackedUp += [PSCustomObject]@{ Nom = $res.Name; Chemin = $res.Path; TailleMB = [math]::Round($res.Size/1MB,2); SHA1 = $res.Hash } } }
    }
}

# Dossiers vides
Get-ChildItem -Path $LocalFolder -Directory -Recurse | Sort-Object { $_.FullName.Length } -Descending | ForEach-Object {
    if ($_.FullName -notlike "*_Doublons*" -and (Get-ChildItem -Path $_.FullName -Recurse | Measure-Object).Count -eq 0) {
        Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
    }
}

# ---------------- BILAN ----------------
if (!$Silent) {
    $NotBackedUp | Export-Csv -Path (Join-Path $ReportFolder "Fichiers_Uniques.csv") -NoTypeInformation
    $DupEntries  | Export-Csv -Path (Join-Path $ReportFolder "doublons_ecartes.csv") -NoTypeInformation
}
Write-Host "`n[BILAN FINAL]" -ForegroundColor White -BackgroundColor DarkCyan
Write-Host "- OneDrive Indexé     : $($script:Cache.Files.Count) fichiers"
Write-Host "- Supprimés (Extras)  : $(($results | ? Action -eq 'Delete').Count)"
Write-Host "- Doublons déplacés   : $(($results | ? Action -eq 'Move').Count)"