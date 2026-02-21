# ============================================================
# ONEDRIVE DEEP INDEXER & CLEANUP - V10.6 (DELTA + RESUME)
# ============================================================
param (
    [ValidateSet("Online", "Offline")]
    [string]$Mode = "Online",
    [switch]$Silent = $true,
    [string[]]$SkipFolders = @("Vault", "Coffre-fort", "Apps", "Pièces jointes", "Fichiers Microsoft Copilot")
)

$ProgressPreference = 'SilentlyContinue'
Clear-Host

# ---------------- CONFIGURATION ----------------
$LocalFolder    = "D:\recup"
$ClientId       = "176fc7bc-42c9-4a25-82b5-0ad584d3c061"
$TenantId       = "common"
$IndexFile      = ".\onedrive_cache.json"
$ReportFolder   = ".\Reports"
$DupFolder      = Join-Path $LocalFolder "_Doublons"

# ---------------- INITIALISATION DU CACHE ----------------
if (Test-Path $IndexFile) {
    try {
        $loadedCache = Get-Content -Raw -Path $IndexFile | ConvertFrom-Json -AsHashtable
        $script:Cache = [ordered]@{
            Files       = [ordered]@{}
            FolderStats = [ordered]@{}
            DeltaLink   = $loadedCache.DeltaLink
            ScanState   = $loadedCache.ScanState
        }
        if ($loadedCache.Files) { foreach ($kv in $loadedCache.Files.GetEnumerator()) { $script:Cache.Files[$kv.Key] = $kv.Value } }
    } catch { $script:Cache = [ordered]@{ Files = [ordered]@{}; FolderStats = [ordered]@{} } }
} else {
    $script:Cache = [ordered]@{ Files = [ordered]@{}; FolderStats = [ordered]@{} }
}

$script:GraphAuth = $null

# ---------------- FONCTIONS UTILES ----------------
function Save-IndexCheckpoint { $script:Cache | ConvertTo-Json -Depth 12 | Set-Content $IndexFile }

function Invoke-GraphRequest {
    param($Uri, $ClientId, $MaxRetries = 8)
    $retry = 0
    while ($retry -lt $MaxRetries) {
        try {
            return Invoke-RestMethod -Headers @{ Authorization = "Bearer $($script:GraphAuth.access_token)" } -Uri $Uri -Method GET
        } catch {
            $status = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
            if ($status -eq 401) { # Refresh Token
                $tokenResponse = Invoke-RestMethod -Method POST -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" -Body @{
                    grant_type = "refresh_token"; client_id = $ClientId; refresh_token = $script:GraphAuth.refresh_token
                }
                $script:GraphAuth = $tokenResponse; $retry++; continue
            }
            if ($status -match "429|503|504") { # Throttling
                $pause = [Math]::Max(5, [Math]::Pow(2, $retry))
                Write-Host "  API saturée ($status), pause ${pause}s..." -ForegroundColor Yellow
                Start-Sleep -Seconds $pause; $retry++; continue
            }
            throw
        }
    }
}

# ---------------- LOGIQUE DE SCAN ----------------
if ($Mode -eq "Online") {
    Write-Host "[2/5] Connexion à Microsoft Graph (Mode Delta)..." -ForegroundColor Cyan
    $Scopes = "offline_access openid Files.Read.All"
    $DeviceCode = Invoke-RestMethod -Method POST -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/devicecode" -Body @{ client_id = $ClientId; scope = $Scopes }
    Write-Host "`n" $DeviceCode.message "`n" -ForegroundColor Yellow
    
    while (!$script:GraphAuth) { Start-Sleep 5; try { $script:GraphAuth = Invoke-RestMethod -Method POST -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" -Body @{ grant_type = "urn:ietf:params:oauth:grant-type:device_code"; client_id = $ClientId; device_code = $DeviceCode.device_code } } catch {} }

    $Uri = if ($script:Cache.ScanState -and $script:Cache.ScanState.NextLink) { $script:Cache.ScanState.NextLink } else { "https://graph.microsoft.com/v1.0/me/drive/root/delta?`$select=name,id,size,file,folder,parentReference,hashes" }
    $page = if ($script:Cache.ScanState -and $script:Cache.ScanState.Pages) { [int]$script:Cache.ScanState.Pages } else { 0 }

    while ($Uri) {
        $Response = Invoke-GraphRequest -Uri $Uri -ClientId $ClientId
        $page++
        foreach ($item in $Response.value) {
            if ($item.file) { $script:Cache.Files[$item.id] = $item }
        }
        $Uri = $Response.'@odata.nextLink'
        $script:Cache.ScanState = [ordered]@{ NextLink = $Uri; Pages = $page; Files = $script:Cache.Files.Count; Updated = (Get-Date).ToString('s') }
        
        if ($page % 10 -eq 0) {
            Write-Host "  Progression : $page pages | $($script:Cache.Files.Count) fichiers indexés" -ForegroundColor Gray
            Save-IndexCheckpoint
        }
        if (-not $Uri) { $script:Cache.DeltaLink = $Response.'@odata.deltaLink'; $script:Cache.ScanState = $null }
    }
    Save-IndexCheckpoint
}

# ---------------- ANALYSE LOCALE & TRI ----------------
Write-Host "[3/5] Préparation des index..." -ForegroundColor Gray
$CloudSha1List = [string[]]($script:Cache.Files.Values | Where-Object { $_.file.hashes.sha1Hash } | ForEach-Object { $_.file.hashes.sha1Hash.ToLower() })
$CloudPathList = [string[]]($script:Cache.Files.Values | ForEach-Object { "$($_.name.ToLower())|$($_.size)" })

Write-Host "[4/5] Analyse disque (Multithread)..." -ForegroundColor Cyan
$AllLocalFiles = Get-ChildItem -Path $LocalFolder -File -Recurse | Where-Object { $_.FullName -notlike "*_Doublons*" }

$results = $AllLocalFiles | ForEach-Object -Parallel {
    $file = $_
    $localSha1 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA1).Hash.ToLower()
    $key = "$($file.Name.ToLower())|$($file.Length)"
    if ($using:CloudSha1List -contains $localSha1 -or $using:CloudPathList -contains $key) {
        return [PSCustomObject]@{ Action = 'Move'; Path = $file.FullName; Name = $file.Name }
    }
} -ThrottleLimit 8

Write-Host "[5/5] Nettoyage des doublons..." -ForegroundColor Cyan
foreach ($res in $results) {
    if ($res.Action -eq 'Move') {
        Move-Item -LiteralPath $res.Path -Destination (Join-Path $DupFolder $res.Name) -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "`n[BILAN FINAL]" -ForegroundColor White -BackgroundColor DarkCyan
Write-Host "- OneDrive Indexé : $($script:Cache.Files.Count) fichiers"
Write-Host "- Doublons écartés : $($results.Count)"