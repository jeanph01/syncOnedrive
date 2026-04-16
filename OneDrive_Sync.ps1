# ============================================================
# VERSION: 15.0 (Runspace Edition + Scan delta optimisé)
# ============================================================

param (
    [ValidateSet("Online", "Offline")]
    [string]$Mode = "Online",                     # Mode de scan OneDrive
    [switch]$ForceNewScan,   # Force uniquement le scan OneDrive (Index Cloud)
    [switch]$ResetCache,     # Reset TOTAL (Cloud + Hash Locaux + Logs)
    [string]$ConfigFile = ".\config.ini"         # Configuration applicative
)

$ProgressPreference = 'SilentlyContinue'
Clear-Host

Import-Module "$PSScriptRoot\modules\AppConfig.psm1" -Force
$app = Get-AppConfiguration -ConfigFile $ConfigFile
$Global:Rules = $app.Rules

$LocalFolder = $app.LocalFolder
$TokenFile = $app.TokenFile
$ClientId = $app.ClientId
$VerboseMode = $app.VerboseMode

# --- LOG FILE ---
$global:LogFile = $app.SyncLogFile

# ---------------- EN-TÊTE & CONFIG ----------------
function enteteConfig {

    # todo déplacer les extensions dans un fichier externe
    $script:TimeStart = Get-Date

    $cache = $app.CacheDir
    if (!(Test-Path $cache)) { New-Item -ItemType Directory -Path $cache | Out-Null }
    $global:IndexFile          = $app.IndexFile
    $global:ReportFile         = $app.SyncReportFile
    $global:LocalHashCacheFile = $app.LocalHashCacheFile
    $global:LogFile            = $app.SyncLogFile
    $global:DupFolder = Join-Path $LocalFolder "_Doublons"

    # Extensions autorisées
    $global:AllowedExt = if ($app.AllowedExt -and $app.AllowedExt.Count -gt 0) {
        $app.AllowedExt
    }
    else {
        @()
    }

    $global:AllowedExtSet = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($ext in $global:AllowedExt) { $null = $global:AllowedExtSet.Add($ext) }

    Write-Log "Configuration chargée"
    Write-Log "Mode: $Mode | ForceNewScan: $ForceNewScan | Dossier: $LocalFolder"

    if (Test-Path $global:LogFile) {
        Remove-Item $global:LogFile -Force
    }
} # enteteConfig
# =====================================================================
# MODULES EXTERNES
# =====================================================================
Import-Module ".\modules\OneDriveTools.psm1" -ArgumentList $ClientId, $TokenFile, $global:LogFile -Force
Import-Module ".\modules\OneDriveOrganize.psm1" 

# =====================================================================
# 1. CHARGEMENT / SCAN
# =====================================================================

function Invoke-GraphWithRetry {
    param(
        [Parameter(Mandatory)] [string]$Uri,      # URL Graph
        [Parameter(Mandatory)] $Headers,          # En-têtes Graph
        [int]$MaxRetry = 5                        # Nombre max de tentatives
    )

    $retry = 0

    while ($retry -lt $MaxRetry) {

        try {
            # Tentative principale
            return Invoke-RestMethod -Headers $Headers -Uri $Uri -Method GET -ErrorAction Stop
        }
        catch {
            $retry++

            Write-Log "Graph ERROR (tentative $retry/$MaxRetry) : $($_.Exception.Message)" "WARN"

            Start-Sleep -Seconds ([math]::Min(10, [math]::Pow(2, $retry)))
        }
    }

    # Si on arrive ici → échec fatal
    Write-Log "ERREUR FATALE: Impossible de récupérer la page Graph après $MaxRetry tentatives." "ERROR"
    return $null
} # Invoke-GraphWithRetry

function ChargementScan {

    Write-Log "[1/4] Chargement / Scan OneDrive (V15.1)"

    try {
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
            $deltaUrl = $script:Cache.DDeltaToken
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
    catch {
        Write-Log "Erreur ChargementScan : $($_.Exception.Message)" "ERROR"
    }
} # ChargementScan

# =====================================================================
# 2. RAPPORT DES DOUBLONS
# =====================================================================
function DoublonsOneDrive {
    try {
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
    catch {
        Write-Log "Erreur DoublonsOneDrive : $($_.Exception.Message)" "ERROR"
    }
} # DoublonsOneDrive

# =====================================================================
# 3. NETTOYAGE LOCAL
# =====================================================================
function NettoyageLocal {
    try {
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
    catch {
        Write-Log "Erreur NettoyageLocal : $($_.Exception.Message)" "ERROR"
    }
} # NettoyageLocal

# =====================================================================
# 4. DOSSIERS VIDES
# =====================================================================
function DossiersVides {
    try {
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
    catch {
        Write-Log "Erreur DossiersVides : $($_.Exception.Message)" "ERROR"
    }
} # DossiersVides

# =====================================================================
# BILAN
# =====================================================================
function Bilan {
    try {
    $Duration = (Get-Date) - $script:TimeStart

    Write-Log "=== BILAN FINAL ==="
    Write-Log "Temps écoulé: $($Duration.Minutes)m $($Duration.Seconds)s"
    Write-Log "Fichiers locaux: $($script:total)"
    Write-Log "Ignorés (taille diff): $($script:cSkipped)"
    Write-Log "Groupes doublons Cloud: $($script:CloudDupCount)"
    Write-Log "Doublons locaux déplacés: $($script:cMove)"
    Write-Log "Fichiers supprimés (ext non autorisées): $($script:cDel)"
}
    catch {
        Write-Log "Erreur Bilan : $($_.Exception.Message)" "ERROR"
    }
} # Bilan

# =====================================================================
# MAIN
# =====================================================================
function main {
    try {
        Write-Log "=== LANCEMENT DU SCRIPT V15.1 ==="

        enteteConfig

        if ($ResetCache) {
            Write-Log "Reset du cache interne..." "WARN"
            $files = @(
                $global:IndexFile,
                $global:ReportFile,
                $global:LocalHashCacheFile,
                $global:LogFile
            )
            foreach ($f in $files) {
                if (Test-Path $f) { Remove-Item $f -Force }
            }
            Write-Log "Reset terminé." "SUCCESS"
        }

        ChargementScan
        DoublonsOneDrive
        NettoyageLocal
        DossiersVides
        Bilan
}
    catch {
        Write-Log "Erreur main : $($_.Exception.Message)" "ERROR"
    }
} # main

main
