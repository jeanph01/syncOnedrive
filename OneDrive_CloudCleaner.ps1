# ============================================================
# ONEDRIVE CLOUD CLEANER - SUPPRESSION DES DOUBLONS GRAPH
# ============================================================

param(
    [string]$ConfigFile = ".\config.ini"
)

Clear-Host

Import-Module "$PSScriptRoot\modules\AppConfig.psm1" -Force
$app = Get-AppConfiguration -ConfigFile $ConfigFile
$Global:Rules = $app.Rules
$IndexFile = $app.IndexFile
$ClientId = $app.ClientId
$TokenFile = $app.TokenFile
$LogFile = $app.CloudCleanerLogFile

# --- Charger le module utilitaire ---
Import-Module ".\modules\OneDriveTools.psm1" -ArgumentList $ClientId, $TokenFile, $LogFile -Force

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

    # --- SKIP si entrée invalide ---
    if ($null -eq $item) { continue }
    if (-not $item.ContainsKey("h")) { continue }
    if ([string]::IsNullOrWhiteSpace($item.h)) { continue }

    # --- Ajout ID dans l'objet ---
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
            foreach ($rule in $Global:Rules.cleanerRules.priorityRules) {
                if ($rule.field -eq "name" -and $_.n -like $rule.pattern) {
                    $score += [int]$rule.score
                }
                elseif ($rule.field -eq "path" -and $_.p -like $rule.pattern) {
                    $score += [int]$rule.score
                }
            }
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
