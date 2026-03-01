# ============================================================
# ONEDRIVE CLOUD CLEANER - SUPPRESSION DES DOUBLONS GRAPH
# ============================================================
$IndexFile = ".\onedrive_cache.json"
$ClientId  = "176fc7bc-42c9-4a25-82b5-0ad584d3c061"

if (!(Test-Path $IndexFile)) { Write-Error "Cache introuvable."; exit }
$Cache = Get-Content $IndexFile | ConvertFrom-Json -AsHashtable

# 1. CONNEXION
Write-Host "[1/3] Connexion à Microsoft Graph..." -ForegroundColor Cyan
$DeviceCode = Invoke-RestMethod -Method POST -Uri "https://login.microsoftonline.com/common/oauth2/v2.0/devicecode" -Body @{ client_id = $ClientId; scope = "Files.ReadWrite.All" }
Write-Host "`n$($DeviceCode.message)`n" -ForegroundColor Yellow
$Auth = $null; while (!$Auth) { Start-Sleep 5; try { $Auth = Invoke-RestMethod -Method POST -Uri "https://login.microsoftonline.com/common/oauth2/v2.0/token" -Body @{ grant_type = "urn:ietf:params:oauth:grant-type:device_code"; client_id = $ClientId; device_code = $DeviceCode.device_code } } catch {} }
$Headers = @{ Authorization = "Bearer $($Auth.access_token)" }

# 2. GROUPEMENT PAR HASH
Write-Host "[2/3] Analyse des priorités de conservation..." -ForegroundColor Cyan
$HashGroups = @{}
foreach ($id in $Cache.Files.Keys) {
    $item = $Cache.Files[$id]
    $item.id = $id # On réinjecte l'ID pour la suppression
    if (!$HashGroups.ContainsKey($item.h)) { $HashGroups[$item.h] = New-Object System.Collections.Generic.List[Object] }
    $HashGroups[$item.h].Add($item)
}

# 3. SUPPRESSION
$count = 0
foreach ($hash in $HashGroups.Keys) {
    $group = $HashGroups[$hash]
    if ($group.Count -gt 1) {
        # --- ALGORITHME DE DÉCISION ---
        # On trie pour mettre le "meilleur" en premier
        $sorted = $group | Sort-Object {
            # Score de priorité (plus bas = mieux)
            $score = 100
            if ($_.n -like "* - Copie*") { $score += 50 }
            if ($_.n -like "* (1)*") { $score += 40 }
            if ($_.p -like "*/Importations/*") { $score += 30 }
            if ($_.p -like "*/Old/*") { $score += 20 }
            if ($_.p -like "*/bureau/*") { $score += 10 }
            $score
        }

        $ToKeep = $sorted[0]
         
        $ToDelete = $sorted | Select-Object -Skip 1

        Write-Host "`nGroupe $hash :" -ForegroundColor Gray
        Write-Host " [KEEP] -> $($ToKeep.p)/$($ToKeep.n)" -ForegroundColor Green

        foreach ($file in $ToDelete) {
            Write-Host " [DEL]  -> $($file.p)/$($file.n)" -ForegroundColor Red
            try {
                # APPEL API DELETE
                $deleteUri = "https://graph.microsoft.com/v1.0/me/drive/items/$($file.id)"
                Invoke-RestMethod -Headers $Headers -Uri $deleteUri -Method DELETE
                $count++
            } catch {
                Write-Host " Erreur lors de la suppression de $($file.n)" -ForegroundColor Yellow
            }
        }
    }
}

Write-Host "`n[TERMINÉ] $count doublons ont été supprimés de OneDrive." -ForegroundColor White -BackgroundColor DarkGreen