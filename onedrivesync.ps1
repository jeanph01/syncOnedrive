# ============================================================
# ONEDRIVE RESTORE & CLEANUP AUDIT - V7 (FINAL)
# Logic : Full (Default), Delta, Offline
# ============================================================
param (
    [ValidateSet("Full", "Delta", "Offline")]
    [string]$Mode = "Delta"
)

Clear-Host

# ---------------- CONFIGURATION ----------------
$LocalFolder    = "D:\recup"
$ClientId       = "176fc7bc-42c9-4a25-82b5-0ad584d3c061"
$TenantId       = "common"
$IndexFile      = ".\onedrive_cache.json"
$ReportFolder   = ".\Reports"
$LogFile        = Join-Path $ReportFolder "deleted_files.log"
$DupLogFile     = Join-Path $ReportFolder "duplicates_found.csv"
$DupFolder      = Join-Path $LocalFolder "_Doublons"

# Whitelist étendue (Vidéo, Photo, Office, PDF, Archives)
$AllowedExt = @(
    ".avi", ".mov", ".mp4", ".mpg", ".mpeg", ".mkv", ".wmv", ".flv", ".webm", ".m4v",
    ".bmp", ".gif", ".jpg", ".jpeg", ".png", ".svg", ".tiff", ".tif", ".webp", ".heic", ".heif", ".psd", ".ai",
    ".doc", ".docx", ".docm", ".dotx", ".xls", ".xlsx", ".xlsm", ".xlsb", ".ppt", ".pptx", ".pptm",
    ".pdf", ".rtf", ".txt", ".csv", ".odt", ".ods", ".odp",
    ".mp3", ".wav", ".wma", ".aac", ".flac", ".m4a", ".ogg",
    ".zip", ".7z", ".rar", ".tar", ".gz"
)

# Initialisation des répertoires de travail
foreach ($path in $ReportFolder, $DupFolder) { 
    if (!(Test-Path $path)) { New-Item -ItemType Directory -Path $path -Force | Out-Null } 
}

# ---------------- GESTION DU CACHE ----------------
$Cache = [ordered]@{ DeltaToken = $null; Files = [ordered]@{} }

if (Test-Path $IndexFile) {
    Write-Host "[1/5] Chargement du cache local..." -ForegroundColor Gray
    $RawCache = Get-Content $IndexFile -Raw | ConvertFrom-Json
    $Cache.DeltaToken = $RawCache.DeltaToken
    if ($RawCache.Files) {
        foreach ($prop in $RawCache.Files.psobject.Properties) { $Cache.Files[$prop.Name] = $prop.Value }
    }
}

# ---------------- LOGIQUE DE SYNCHRONISATION ----------------
if ($Mode -eq "Offline") {
    Write-Host "[2/5] MODE OFFLINE : Analyse basée sur le cache existant." -ForegroundColor Yellow
    if ($Cache.Files.Count -eq 0) { 
        Write-Error "Le cache est vide. Lancez un scan 'Full' ou 'Delta' d'abord."
        return 
    }
} else {
    Write-Host "[2/5] Connexion à Microsoft Graph..." -ForegroundColor Cyan
    $Scopes = "offline_access openid Files.Read"
    try {
        $DeviceCode = Invoke-RestMethod -Method POST -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/devicecode" -Body @{ client_id = $ClientId; scope = $Scopes }
        Write-Host "`n" $DeviceCode.message "`n" -ForegroundColor Yellow
        
        $Auth = $null
        while (!$Auth) { 
            Start-Sleep 5
            try { $Auth = Invoke-RestMethod -Method POST -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" -Body @{ grant_type = "urn:ietf:params:oauth:grant-type:device_code"; client_id = $ClientId; device_code = $DeviceCode.device_code } } catch {} 
        }
        
        $AccessToken = $Auth.access_token
        $BaseUri = "https://graph.microsoft.com/v1.0/me/drive/root/delta?select=name,id,size,file,hashes"
        $NextLink = if ($Mode -eq "Full") { $BaseUri } else { if ($Cache.DeltaToken) { $Cache.DeltaToken } else { $BaseUri } }
        
        Write-Host "Synchronisation OneDrive (Mode: $Mode)..." -ForegroundColor Cyan
        while ($NextLink) {
            $Response = Invoke-RestMethod -Headers @{ Authorization = "Bearer $AccessToken" } -Uri $NextLink -Method GET
            foreach ($item in $Response.value) {
                if ($item.deleted) { $Cache.Files.Remove($item.id) }
                elseif ($item.file) { $Cache.Files[$item.id] = $item }
            }
            Write-Progress -Activity "Indexation Cloud" -Status "Fichiers : $($Cache.Files.Count)"
            $NextLink = $Response.'@odata.nextLink'
            if (!$NextLink) {
                $Cache.DeltaToken = $Response.'@odata.deltaLink'
                $Cache | ConvertTo-Json -Depth 10 | Set-Content $IndexFile
            }
        }
    } catch {
        Write-Error "Erreur lors de la synchronisation : $($_.Exception.Message)"
        return
    }
}

# ---------------- PRÉPARATION LOOKUPS ----------------
Write-Host "[3/5] Préparation des index de recherche..." -ForegroundColor Gray
$CloudSha1List = [string[]]($Cache.Files.Values | Where-Object { $_.file.hashes.sha1Hash } | ForEach-Object { $_.file.hashes.sha1Hash.ToLower() })
$CloudPathList = [string[]]($Cache.Files.Values | ForEach-Object { "$($_.name.ToLower())|$($_.size)" })

# ---------------- ANALYSE LOCALE PARALLÈLE ----------------
Write-Host "[4/5] Analyse du disque local (Mode Parallèle PS7)..." -ForegroundColor Cyan
$AllLocalFiles = Get-ChildItem -Path $LocalFolder -File -Recurse | Where-Object { 
    $_.FullName -notlike "*_Doublons*" -and $_.FullName -notlike "*$ReportFolder*" 
}

$results = $AllLocalFiles | ForEach-Object -Parallel {
    $file = $_
    $ext = [System.IO.Path]::GetExtension($file.FullName).ToLower()
    
    if ($using:AllowedExt -notcontains $ext) {
        return [PSCustomObject]@{ Action = 'Delete'; Path = $file.FullName }
    }

    $localSha1 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA1).Hash.ToLower()
    $key = "$($file.Name.ToLower())|$($file.Length)"

    if ($using:CloudSha1List -contains $localSha1 -or $using:CloudPathList -contains $key) {
        return [PSCustomObject]@{ Action = 'Move'; Path = $file.FullName; Name = $file.Name; Hash = $localSha1 }
    } else {
        return [PSCustomObject]@{ Action = 'Keep'; Path = $file.FullName; Name = $file.Name; Hash = $localSha1; Size = $file.Length }
    }
} -ThrottleLimit 8

# ---------------- ACTIONS PHYSIQUES ----------------
Write-Host "[5/5] Application des actions sur les fichiers..." -ForegroundColor Cyan
$NotBackedUp = @()
$DupEntries  = @()
$DelLog      = [System.IO.StreamWriter]$LogFile
$i = 0; $total = $results.Count

foreach ($res in $results) {
    $i++; Write-Progress -Activity "Traitement physique" -Status "$i / $total" -PercentComplete (($i/$total)*100)
    
    switch ($res.Action) {
        'Delete' {
            $DelLog.WriteLine("REMOVED: $($res.Path)")
            # Suppression forcée, récursive et sans confirmation pour les fichiers/dossiers corrompus
            Remove-Item -LiteralPath $res.Path -Force -Recurse -Confirm:$false -ErrorAction SilentlyContinue
        }
        'Move' {
            $dest = Join-Path $DupFolder $res.Name
            $idx = 1; while (Test-Path $dest) { $dest = Join-Path $DupFolder "$([System.IO.Path]::GetFileNameWithoutExtension($res.Name))_$idx$([System.IO.Path]::GetExtension($res.Name))"; $idx++ }
            Move-Item -LiteralPath $res.Path -Destination $dest -Force
            $DupEntries += [PSCustomObject]@{ OriginalPath = $res.Path; Hash = $res.Hash; Date = (Get-Date) }
        }
        'Keep' {
            $NotBackedUp += [PSCustomObject]@{ Nom = $res.Name; Chemin = $res.Path; TailleMB = [math]::Round($res.Size/1MB,2); SHA1 = $res.Hash }
        }
    }
}
$DelLog.Close()

# --- Nettoyage final des dossiers vides ---
Write-Host "Nettoyage des dossiers vides..." -ForegroundColor Gray
Get-ChildItem -Path $LocalFolder -Directory -Recurse | Sort-Object { $_.FullName.Length } -Descending | ForEach-Object {
    if ($_.FullName -notlike "*_Doublons*" -and (Get-ChildItem -Path $_.FullName -Recurse | Measure-Object).Count -eq 0) {
        Remove-Item -LiteralPath $_.FullName -Force -Recurse -Confirm:$false -ErrorAction SilentlyContinue
    }
}

# ---------------- RÉSUMÉ ----------------
Write-Progress -Activity "Traitement physique" -Completed
$NotBackedUp | Export-Csv -Path (Join-Path $ReportFolder "Fichiers_Uniques.csv") -NoTypeInformation
$DupEntries  | Export-Csv -Path $DupLogFile -NoTypeInformation

Write-Host "`n[RÉSUMÉ FINAL DU RUN]" -ForegroundColor White -BackgroundColor DarkBlue
Write-Host "- Mode utilisé          : $Mode"
Write-Host "- Fichiers OneDrive     : $($Cache.Files.Count)"
Write-Host "- Écartés (Hors WL)     : $(($results | ? Action -eq 'Delete').Count)"
Write-Host "- Doublons (Déplacés)   : $(($results | ? Action -eq 'Move').Count)"
Write-Host "- Uniques (À SAUVER)    : $($NotBackedUp.Count)"
Write-Host "- Dossier des rapports  : $ReportFolder"