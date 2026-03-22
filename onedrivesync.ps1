# ============================================================
# VERSION: 15.0 (Runspace Edition + Scan delta optimisé)
# ============================================================

param (
    [ValidateSet("Online", "Offline")]
    [string]$Mode = "Online",
    [switch]$ForceNewScan = $false,
    [string]$LocalFolder = "D:\recup",
    [string]$TokenFile = ".\graph_token.json",
    [string]$ClientId = "176fc7bc-42c9-4a25-82b5-0ad584d3c061"
)

$ProgressPreference = 'SilentlyContinue'
Clear-Host

# --- LOG FILE ---
$global:LogFile = ".\onedrive_indexer_log.txt"

# ---------------- EN-TÊTE & CONFIG ----------------
function enteteConfig {

    $script:TimeStart = Get-Date

    $global:IndexFile = ".\onedrive_cache.json"
    $global:ReportFile = ".\onedrive_doublons_rapport.txt"
    $global:DupFolder = Join-Path $LocalFolder "_Doublons"
    $global:LocalHashCacheFile = ".\local_hash_cache.json"

    # Extensions autorisées
    $global:AllowedExt = @(
        ".avi", ".mov", ".mp4", ".mpg", ".mpeg", ".mkv", ".wmv", ".flv", ".webm", ".m4v", ".3gp",
        ".bmp", ".gif", ".jpg", ".jpeg", ".png", ".svg", ".tiff", ".tif", ".webp", ".heic", ".heif", ".psd", ".ai", ".xcf", ".ico", ".thm",
        ".doc", ".docx", ".xls", ".xlsx", ".ppt", ".pptx", ".pdf", ".rtf", ".txt", ".odt", ".wpd", ".epub", ".pages",
        ".msg", ".eml", ".mp3", ".wav", ".m4a", ".flac", ".amr", ".opus",
        ".html", ".htm", ".zip", ".7z", ".rar", ".csv", ".json", ".xml"
    )

    $global:AllowedExtSet = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($ext in $global:AllowedExt) { $null = $global:AllowedExtSet.Add($ext) }

    Write-Host "Configuration chargée"
    Write-Host "Mode: $Mode | ForceNewScan: $ForceNewScan | Dossier: $LocalFolder"

    if (Test-Path $global:LogFile) {
        Remove-Item $global:LogFile -Force
    }
}

# --- CHARGER MODULE APRÈS CONFIG ---
Import-Module ".\OneDriveTools\OneDriveTools.psm1" -ArgumentList $ClientId, $TokenFile, $global:LogFile -Force
Import-Module ".\OneDriveTools\OneDriveOrganize.psm1" 


# ---------------- 1. CHARGEMENT / SCAN ----------------

function Invoke-GraphWithRetry {
    param(
        [Parameter(Mandatory)] [string]$Uri,
        [Parameter(Mandatory)] $Headers,
        [int]$MaxRetry = 5
    )

    $retry = 0

    while ($retry -lt $MaxRetry) {

        try {
            # Tentative principale
            return Invoke-RestMethod -Headers $Headers -Uri $Uri -Method GET -ErrorAction Stop
        }
        catch {
            $retry++
            $err = $_.Exception.Message

            Write-Log "Graph ERROR (tentative $retry/$MaxRetry) : $err" "WARN"

            # Backoff exponentiel
            $delay = [math]::Min(10, [math]::Pow(2, $retry))
            Start-Sleep -Seconds $delay
        }
    }

    # Si on arrive ici → échec fatal
    Write-Log "ERREUR FATALE: Impossible de récupérer la page Graph après $MaxRetry tentatives." "ERROR"
    return $null
}

function ChargementScan {

    Write-Log "[1/4] Chargement / Scan OneDrive (V15.0 - Scan delta optimisé)"

    # Préparation du cache
    $script:Cache = @{ Files = @{} }

    # Reset cache si demandé
    if ($ForceNewScan -and (Test-Path $global:IndexFile)) {
        Write-Log "Suppression ancien cache"
        Remove-Item $global:IndexFile -Force
    }

    # Mode offline
    if ($Mode -ne "Online") {
        Write-Log "Mode Offline → chargement du cache existant"
        if (Test-Path $global:IndexFile) {
            $script:Cache = Get-Content $global:IndexFile -Raw | ConvertFrom-Json -AsHashtable
            if (-not $script:Cache.Files) { $script:Cache.Files = @{} }
            Write-Log "Cache chargé ($($script:Cache.Files.Count) fichiers)"
        }
        return
    }

    # Auth via module
    $Auth = Get-GraphToken
    $Token = $Auth.access_token
    $Headers = @{ Authorization = "Bearer $Token" }

    # Charger cache existant si présent
    if ((-not $ForceNewScan) -and (Test-Path $global:IndexFile)) {
        try {
            $script:Cache = Get-Content $global:IndexFile -Raw | ConvertFrom-Json -AsHashtable
            if (-not $script:Cache.Files) { $script:Cache.Files = @{} }
            Write-Log "Cache existant chargé ($($script:Cache.Files.Count) fichiers)"
        }
        catch {
            $script:Cache = @{ Files = @{} }
            Write-Log "Cache existant illisible, recréation"
        }
    }

    # Champs demandés
    $select = "name,id,size,file,hashes,fileSystemInfo,parentReference,photo,location,video,audio,image"
    $baseUrl = "https://graph.microsoft.com/v1.0/me/drive/root/delta?`$select=$select"

    # Delta complet ou incrémental
    if ($ForceNewScan -or -not $script:Cache.DeltaToken) {
        $deltaUrl = $baseUrl
        Write-Log "Scan delta complet (nouvelle base)"
    }
    else {
        $deltaUrl = $script:Cache.DeltaToken
        Write-Log "Scan delta incrémental depuis le dernier deltaToken"
    }

    # Boucle delta
    while ($deltaUrl) {

        $res = Invoke-GraphWithRetry -Uri $deltaUrl -Headers $Headers
        if (-not $res) {
            Write-Log "Abandon du scan delta (page irrécupérable)." "ERROR"
            break
        }

        $items = $res.value
        $count = if ($items) { $items.Count } else { 0 }

        foreach ($item in $items) {

            $entry = Read-AzureFileInfo $item
            if ($null -eq $entry) {
                continue
            }
            $script:Cache.Files[$item.id] = $entry
        }

        Write-Log "Graph: $count items → total $($script:Cache.Files.Count)"

        # Pagination delta
        if ($res.'@odata.nextLink') {
            $deltaUrl = $res.'@odata.nextLink'
        }
        elseif ($res.'@odata.deltaLink') {
            $script:Cache.DeltaToken = $res.'@odata.deltaLink'
            Write-Log "deltaLink final reçu → fin du scan"
            break
        }
        else {
            Write-Log "Fin du scan"
            break
        }
    }

    # Sauvegarde finale
    $script:Cache | ConvertTo-Json -Depth 10 | Out-File $global:IndexFile -Encoding utf8 -NoNewline
    Write-Log "Cache OneDrive sauvegardé"
}

# ---------------- 2. RAPPORT DES DOUBLONS ----------------
function DoublonsOneDrive {
    Write-Log "[2/4] Analyse des doublons OneDrive"

    $script:CloudDupCount = 0
    $HashGroups = @{}

    foreach ($item in $script:Cache.Files.Values) {

        if ($null -eq $item) { continue }
        if (-not $item.h)    { continue }

        if (-not $HashGroups.ContainsKey($item.h)) {
            $HashGroups[$item.h] = New-Object System.Collections.Generic.List[Object]
        }

        $HashGroups[$item.h].Add($item)
    }

    foreach ($h in $HashGroups.Keys) {
        if ($HashGroups[$h].Count -gt 1) { $script:CloudDupCount++ }
    }

    Write-Log "Groupes doublons Cloud: $($script:CloudDupCount)"
}

# ---------------- 3. NETTOYAGE LOCAL OPTIMISÉ ----------------
function NettoyageLocal {

    Write-Log "[3/4] Analyse locale"

    # Dossier des doublons
    if (!(Test-Path $global:DupFolder)) {
        New-Item -ItemType Directory -Path $global:DupFolder -Force | Out-Null
    }

    # Construction du dictionnaire CloudSizes : taille → liste de hash
    $CloudSizes = @{}

    foreach ($f in $script:Cache.Files.Values) {

        # --- FILTRES DE SÉCURITÉ ---
        if ($null -eq $f) { continue }
        if ($null -eq $f.s) { continue }   # taille manquante
        if ($null -eq $f.h) { continue }   # hash manquant

        # --- AJOUT DANS CloudSizes ---
        if (-not $CloudSizes.ContainsKey($f.s)) {
            $CloudSizes[$f.s] = New-Object System.Collections.Generic.List[string]
        }

        $CloudSizes[$f.s].Add($f.h)
    }

    # Chargement du cache local des hash
    $script:LocalHashCache = @{}
    if (Test-Path $global:LocalHashCacheFile) {
        try {
            $script:LocalHashCache = Get-Content $global:LocalHashCacheFile -Raw | ConvertFrom-Json -AsHashtable
        }
        catch { $script:LocalHashCache = @{} }
    }

    # Fichiers locaux
    $LocalFiles = Get-ChildItem -Path $LocalFolder -File -Recurse |
                  Where-Object { $_.FullName -notlike "*_Doublons*" }

    $script:cDel = 0
    $script:cMove = 0
    $script:cSkipped = 0
    $script:total = $LocalFiles.Count

    $i = 0

    foreach ($file in $LocalFiles) {
        $i++

        if ($i % 300 -eq 0) {
            Write-Log "Progression: $i / $($script:total)"
        }

        # Extension non autorisée → suppression
        if (-not $global:AllowedExtSet.Contains($file.Extension.ToLower())) {
            Remove-Item -LiteralPath $file.FullName -Force
            $script:cDel++
            continue
        }

        # Taille non présente dans le cloud → ignoré
        if (-not $CloudSizes.ContainsKey($file.Length)) {
            $script:cSkipped++
            continue
        }

        $possibleHashes = $CloudSizes[$file.Length]

        # Cas simple : un seul hash possible
        if ($possibleHashes.Count -eq 1) {
            $expected = $possibleHashes[0]

            if ($script:LocalHashCache.ContainsKey($file.FullName)) {
                if ($script:LocalHashCache[$file.FullName] -eq $expected) {

                    # Déplacement dans _Doublons
                    $dest = Join-Path $global:DupFolder $file.Name
                    $idx = 1
                    while (Test-Path -LiteralPath $dest) {
                        $dest = Join-Path $global:DupFolder "$($file.BaseName)_$idx$($file.Extension)"
                        $idx++
                    }

                    [System.IO.File]::Move($file.FullName, $dest)
                    $script:cMove++
                    continue
                }
            }
        }

        # Calcul du hash local si nécessaire
        $sha1 = $null
        if ($script:LocalHashCache.ContainsKey($file.FullName)) {
            $sha1 = $script:LocalHashCache[$file.FullName]
        }
        else {
            $sha1 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA1).Hash.ToLower()
            $script:LocalHashCache[$file.FullName] = $sha1
        }

        # Si le hash correspond → doublon
        if ($possibleHashes -contains $sha1) {

            $dest = Join-Path $global:DupFolder $file.Name
            $idx = 1
            while (Test-Path -LiteralPath $dest) {
                $dest = Join-Path $global:DupFolder "$($file.BaseName)_$idx$($file.Extension)"
                $idx++
            }

            [System.IO.File]::Move($file.FullName, $dest)
            $script:cMove++
        }
    }

    # Sauvegarde du cache local
    $script:LocalHashCache | ConvertTo-Json -Depth 5 |
        Out-File $global:LocalHashCacheFile -Encoding utf8 -NoNewline

    Write-Log "Nettoyage local terminé"
}

# ---------------- 4. DOSSIERS VIDES ----------------
function DossiersVides {
    Write-Log "[4/4] Nettoyage dossiers vides"

    Get-ChildItem -Path $LocalFolder -Directory -Recurse |
    Sort-Object { $_.FullName.Length } -Descending |
    ForEach-Object {
        if ((Get-ChildItem -LiteralPath $_.FullName -ErrorAction SilentlyContinue).Count -eq 0) {
            if ($_.FullName -notlike "*_Doublons*") {
                Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

# ---------------- BILAN ----------------
function Bilan {
    $Duration = (Get-Date) - $script:TimeStart

    Write-Log "=== BILAN FINAL ==="
    Write-Log "Temps écoulé: $($Duration.Minutes)m $($Duration.Seconds)s"
    Write-Log "Fichiers locaux: $($script:total)"
    Write-Log "Ignorés (taille diff): $($script:cSkipped)"
    Write-Log "Groupes doublons Cloud: $($script:CloudDupCount)"
    Write-Log "Doublons locaux déplacés: $($script:cMove)"
    Write-Log "Fichiers supprimés (ext non autorisées): $($script:cDel)"
}

function main {
    
    Write-Log "=== LANCEMENT DU SCRIPT V15.0 ==="

    enteteConfig
    ChargementScan
    DoublonsOneDrive
    NettoyageLocal
    DossiersVides
    Bilan
}

main