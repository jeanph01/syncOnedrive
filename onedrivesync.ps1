# ============================================================
# ONEDRIVE RESTORE & CLEANUP AUDIT
# Filtre strict + Log des suppressions + Multi-Hash comparison
# ============================================================

# ---------------- CONFIGURATION ----------------
$LocalFolder    = "D:\recup"
$ClientId       = "176fc7bc-42c9-4a25-82b5-0ad584d3c061"
$TenantId       = "common"
$IndexFile      = ".\onedrive_cache.json"
$ReportFolder   = ".\Reports"
$LogFile        = Join-Path $ReportFolder "deleted_files.log"
$DupFolder      = Join-Path $LocalFolder "_Doublons"

# Extensions autorisées (Whitelist)
$AllowedExt = @(".avi", ".bmp", ".doc", ".docx", ".gif", ".jpg", ".mov", ".mp3", ".mp4", ".mpg", ".pdf", ".png", ".rtf", ".svg", ".xlsx", ".zip")

# Initialisation
if (!(Test-Path $ReportFolder)) { New-Item -ItemType Directory -Path $ReportFolder | Out-Null }
if (!(Test-Path $DupFolder))    { New-Item -ItemType Directory -Path $DupFolder | Out-Null }
$Stream = [System.IO.StreamWriter]$LogFile

# ---------------- CHARGEMENT CACHE ----------------
$Cache = @{ DeltaToken = $null; Files = @{} }
if (Test-Path $IndexFile) {
    Write-Host "Chargement du cache JSON..." -ForegroundColor Gray
    $RawCache = Get-Content $IndexFile -Raw | ConvertFrom-Json
    $Cache.DeltaToken = $RawCache.DeltaToken
    if ($RawCache.Files) {
        foreach ($prop in $RawCache.Files.psobject.Properties) {
            $Cache.Files[$prop.Name] = $prop.Value
        }
    }
}

# ---------------- AUTHENTICATION ----------------
$Scopes = "offline_access openid Files.Read"
$DeviceCode = Invoke-RestMethod -Method POST -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/devicecode" -Body @{ client_id = $ClientId; scope = $Scopes }
Write-Host $DeviceCode.message -ForegroundColor Yellow
$Auth = $null
while (!$Auth) { Start-Sleep 5; try { $Auth = Invoke-RestMethod -Method POST -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" -Body @{ grant_type = "urn:ietf:params:oauth:grant-type:device_code"; client_id = $ClientId; device_code = $DeviceCode.device_code } } catch {} }
$AccessToken = $Auth.access_token

# ---------------- SYNC ONEDRIVE (DELTA) ----------------
# On demande tous les champs utiles pour la détection de doublons
$BaseUri = "https://graph.microsoft.com/v1.0/me/drive/root/delta?select=name,id,size,file,hashes,lastModifiedDateTime"
$NextLink = if ($Cache.DeltaToken) { $Cache.DeltaToken } else { $BaseUri }

Write-Host "Synchronisation OneDrive (Page par Page)..." -ForegroundColor Cyan
while ($NextLink) {
    $Response = Invoke-RestMethod -Headers @{ Authorization = "Bearer $AccessToken" } -Uri $NextLink -Method GET
    
    foreach ($item in $Response.value) {
        if ($item.deleted) {
            $Cache.Files.Remove($item.id)
        }
        elseif ($item.file) {
            # On stocke l'objet structuré comme demandé
            $Cache.Files[$item.id] = $item
        }
    }

    # Sauvegarde du DeltaToken et de l'index
    if ($Response.'@odata.deltaLink') { 
        $Cache.DeltaToken = $Response.'@odata.deltaLink'
        $NextLink = $null 
    } else {
        $NextLink = $Response.'@odata.nextLink'
    }

    # Mise à jour du JSON physiquement à chaque page
    $Cache | ConvertTo-Json -Depth 10 | Set-Content $IndexFile
    Write-Host "Page traitée. Total indexé : $($Cache.Files.Count)" -ForegroundColor DarkGray
}

# ---------------- PRÉPARATION LOOKUPS RAPIDES ----------------
$CloudSha1   = New-Object System.Collections.Generic.HashSet[string]
$CloudSha256 = New-Object System.Collections.Generic.HashSet[string]
$CloudQuick  = New-Object System.Collections.Generic.HashSet[string]
$CloudPaths  = New-Object System.Collections.Generic.HashSet[string]

foreach ($f in $Cache.Files.Values) {
    if ($f.file.hashes.sha1Hash)   { [void]$CloudSha1.Add($f.file.hashes.sha1Hash.ToLower()) }
    if ($f.file.hashes.sha256Hash) { [void]$CloudSha256.Add($f.file.hashes.sha256Hash.ToLower()) }
    if ($f.file.hashes.quickXorHash) { [void]$CloudQuick.Add($f.file.hashes.quickXorHash) }
    [void]$CloudPaths.Add("$($f.name.ToLower())|$($f.size)")
}

# ---------------- NETTOYAGE & AUDIT LOCAL ----------------
Write-Host "`nAnalyse du disque local : $LocalFolder" -ForegroundColor Cyan
$AllLocalFiles = Get-ChildItem -Path $LocalFolder -File -Recurse | Where-Object { $_.FullName -notlike "*_Doublons*" -and $_.FullName -notlike "*$ReportFolder*" }
$NotBackedUp = @()
$Total = $AllLocalFiles.Count
$DeletedCount = 0

for ($i = 0; $i -lt $Total; $i++) {
    $file = $AllLocalFiles[$i]
    Write-Progress -Activity "Audit HDD Crash" -Status "Fichier: $($file.Name)" -PercentComplete (($i / $Total) * 100)

    # 1. Filtre extension + Log
    if ($AllowedExt -notcontains $file.Extension.ToLower()) {
        $Stream.WriteLine("DELETED: $($file.FullName) | Reason: Extension not in whitelist")
        Remove-Item -Path $file.FullName -Force
        $DeletedCount++
        continue
    }

    # 2. Calcul Hash Local (SHA1 par défaut pour comparaison)
    $localSha1 = (Get-FileHash $file.FullName -Algorithm SHA1).Hash.ToLower()
    $fallbackKey = "$($file.Name.ToLower())|$($file.Length)"
    
    # 3. Comparaison multi-niveaux
    $isDuplicate = $false
    if ($CloudSha1.Contains($localSha1) -or $CloudPaths.Contains($fallbackKey)) {
        $isDuplicate = $true
    }

    if ($isDuplicate) {
        $dest = Join-Path $DupFolder $file.Name
        if (Test-Path $dest) { $dest = Join-Path $DupFolder "$($file.BaseName)_$(Get-Random)$($file.Extension)" }
        Move-Item -Path $file.FullName -Destination $dest -Force
    } else {
        $NotBackedUp += [PSCustomObject]@{
            Nom       = $file.Name
            Chemin    = $file.FullName
            TailleMB  = [math]::Round($file.Length / 1MB, 2)
            SHA1      = $localSha1
            Extension = $file.Extension.ToUpper()
        }
    }
}

$Stream.Close()

# ---------------- RAPPORT ----------------
$ReportPath = Join-Path $ReportFolder "Restore_Report_$(Get-Date -Format 'yyyyMMdd_HHmm').csv"
$NotBackedUp | Export-Csv -Path $ReportPath -NoTypeInformation -Encoding UTF8

Write-Host "`nNettoyage et Audit terminés." -ForegroundColor Green
Write-Host "- Supprimés (Log dans $LogFile) : $DeletedCount"
Write-Host "- Doublons trouvés et déplacés : $($Total - $DeletedCount - $NotBackedUp.Count)"
Write-Host "- Fichiers uniques à restaurer  : $($NotBackedUp.Count)"
Write-Host "- Rapport disponible ici : $ReportPath"