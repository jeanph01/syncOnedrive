# ============================================================
# ONEDRIVE CLOUD CLEANER - SUPPRESSION DES DOUBLONS GRAPH
# ============================================================

param(
    [string]$IndexFile = ".\onedrive_cache.json",
    [string]$ClientId  = "176fc7bc-42c9-4a25-82b5-0ad584d3c061",
    [string]$TokenFile = ".\graph_token.json",
    [string]$LogFile   = ".\onedrive_cleaner_log.txt"
)

Clear-Host

# --- Charger le module utilitaire ---
Import-Module ".\OneDriveTools\OneDriveTools.psm1" -ArgumentList $ClientId, $TokenFile, $LogFile -Force

Write-Log "=== ONEDRIVE CLOUD CLEANER ==="

# --- Charger le cache ---
if (!(Test-Path $IndexFile)) {
    Write-Log "ERREUR: Cache introuvable."
    exit
}

$Cache = Get-Content $IndexFile -Raw | ConvertFrom-Json -AsHashtable
Write-Log "Cache chargé: $($Cache.Files.Count) fichiers"

# --- Auth via module ---
Write-Log "[1/3] Connexion à Microsoft Graph..."
$Auth = Get-GraphToken
$Headers = @{ Authorization = "Bearer $($Auth.access_token)" }

# --- Grouper par hash ---
Write-Log "[2/3] Analyse des groupes de doublons..."

$HashGroups = @{}

foreach ($id in $Cache.Files.Keys) {
    $item = $Cache.Files[$id]
    $item.id = $id

    if (-not $HashGroups.ContainsKey($item.h)) {
        $HashGroups[$item.h] = New-Object System.Collections.Generic.List[Object]
    }

    $HashGroups[$item.h].Add($item)
}

# --- Suppression ---
Write-Log "[3/3] Suppression des doublons..."

$count = 0

foreach ($hash in $HashGroups.Keys) {

    $group = $HashGroups[$hash]

    if ($group.Count -gt 1) {

        # Tri par priorité
        $sorted = $group | Sort-Object {
            $score = 100
            if ($_.n -like "* - Copie*") { $score += 50 }
            if ($_.n -like "* (1)*")     { $score += 40 }
            if ($_.p -like "*/Importations/*") { $score += 30 }
            if ($_.p -like "*/Old/*")          { $score += 20 }
            if ($_.p -like "*/bureau/*")       { $score += 10 }
            $score
        }

        $ToKeep   = $sorted[0]
        $ToDelete = $sorted | Select-Object -Skip 1

        Write-Log "Groupe $hash → KEEP: $($ToKeep.p)/$($ToKeep.n)"

        foreach ($file in $ToDelete) {

            Write-Log "DEL: $($file.p)/$($file.n)"

            try {
                $deleteUri = "https://graph.microsoft.com/v1.0/me/drive/items/$($file.id)"
                Invoke-RestMethod -Headers $Headers -Uri $deleteUri -Method DELETE
                $count++
            }
            catch {
                Write-Log "Erreur suppression: $($file.n)"
            }
        }
    }
}

Write-Log "[TERMINÉ] $count doublons supprimés de OneDrive."