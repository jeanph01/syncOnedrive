# =====================================================================
# Organisateur OneDrive — Pipeline moderne fusionné
# - Analyse, classification, renommage intelligent, planification
# - Barre de progression intégrée
# - Logging harmonisé
# - GPS, tags, caméra, source, destination
# - Version optimisée et cohérente
# =====================================================================

param (
    [bool]$Execute = $true,                          # Exécute réellement les déplacements
    [bool]$ResetCache = $false,                          # Réinitialise les fichiers internes sauf GPS et cache OneDrive
    [string]$IndexFile = ".\_cache\onedrive_cache.json",  # Cache OneDrive (fichier source)
    [string]$LogFile = ".\_cache\organisation_log.txt", # Log des opérations
    [string]$ProcessedLog = ".\_cache\processed_ids.log", # IDs déjà traités
    [string]$ExecutionReport = ".\_cache\azure_sync_report.csv", # Rapport CSV des opérations
    [string]$GpsCacheFile = ".\_cache\gps_cache.json",   # Cache GPS
    [bool]$VerboseMode = $true,                            # Active les logs DEBUG
        # === NOUVEAUX PARAMÈTRES ===
    [bool]$Analyze = $false,          # Analyse du plan.json
    [bool]$DryRun = $false,           # Mode dry-run détaillé
    [bool]$Validate = $false,         # Validation du cache OneDrive
    [string]$DebugId = "",            # Debug d’un fichier précis
    [bool]$ReportIgnored = $false     # Générer rapport fichiers ignorés
)

# --- Forcer l'affichage de Write-Progress (au cas où un autre script l'a désactivé)
$ProgressPreference = 'Continue'


# =====================================================================
# CONFIGURATION GLOBALE (PLACÉE AVANT LES MODULES)
# =====================================================================

$Config = [PSCustomObject]@{
    RenameMarker = "--odr--"      # Marqueur de renommage
    MaxNameLen   = 80             # Longueur max des noms de fichiers
    ClientId     = "176fc7bc-42c9-4a25-82b5-0ad584d3c061" # ClientId Graph
    ExtensionMap = $ExtensionMap  # Table de mapping des extensions
}

# =====================================================================
# MODULES EXTERNES
# =====================================================================

Import-Module "$PSScriptRoot\modules\OneDriveTools.psm1" -ArgumentList $Config.ClientId, $TokenFile, $LogFile, $VerboseMode -Force
Import-Module "$PSScriptRoot\modules\OneDriveOrganize.psm1" -Force
Import-Module "$PSScriptRoot\modules\OneDriveCacheUtils.psm1" -Force -DisableNameChecking
Import-Module "$PSScriptRoot\modules\GpsTools.psm1" -ArgumentList $GpsCacheFile -Force
# =====================================================================
# CRÉATION DU DOSSIER _cache SI NÉCESSAIRE
# =====================================================================
try {
    $cacheFolder = Split-Path $IndexFile -Parent
    if ($cacheFolder -and -not (Test-Path $cacheFolder)) {
        New-Item -ItemType Directory -Path $cacheFolder -Force | Out-Null
    }
}
catch {
    Write-Log "Erreur lors de la création du dossier cache : $($_.Exception.Message)" "ERROR"
}

# =====================================================================
# ÉTAT GLOBAL
# =====================================================================

# État global du script
$Global:State = @{
    Headers        = $null
    Cache          = $null
    ProcessedIds   = @{}
    PlannedActions = New-Object System.Collections.Generic.List[PSCustomObject]
    FilesToProcess = @{}
}


# =====================================================================
# RESET CACHE (strict minimum)
# =====================================================================

if ($ResetCache) {
    try {
        Write-Log "Reset du cache interne..." "WARN"

        $cacheFolder = Split-Path $IndexFile -Parent
        $planFile = Join-Path $cacheFolder "plan.json"
        $hashFile = Join-Path $cacheFolder "cache_hash.txt"
        $filesToDelete = @(
            $ProcessedLog,
            $ExecutionReport,
            $LogFile,
            $planFile,
            $hashFile
        )

        foreach ($f in $filesToDelete) {
            if ($f -and (Test-Path $f)) {
                Remove-Item $f -Force
            }
        }

        Write-Log "Reset terminé (GPS + onedrive_cache.json conservés)." "SUCCESS"
    }
    catch {
        Write-Log "Erreur lors du reset du cache : $($_.Exception.Message)" "ERROR"
    }
}


# =====================================================================
# PRÉ-CRÉATION DES DOSSIERS
# =====================================================================

# =====================================================================
# FONCTION : Test-OneDrivePath
# RÔLE      : Vérifie et crée récursivement une arborescence sur OneDrive
# =====================================================================
function Test-OneDrivePath {
    param(
        [Parameter(Mandatory=$true)]
        [string]$RelativePath
    )

    # 1. Initialisation de sécurité pour éviter les erreurs de variables inexistantes
    $uriGet = "Non générée"
    $uriPost = "Non générée"
    $currentPathRaw = ""
    $currentPathEncoded = ""
    $part = "Racine"

    try {
        # Nettoyage du chemin (supprime les slashs de début et fin)
        $cleanPath = $RelativePath.Trim('/')
        if ([string]::IsNullOrWhiteSpace($cleanPath)) { return }

        # Découpage et nettoyage des espaces invisibles
        $pathParts = $cleanPath -split '/' | ForEach-Object { $_.Trim() }

        foreach ($part in $pathParts) {
            if ([string]::IsNullOrWhiteSpace($part)) { continue }

            $parentPathEncoded = $currentPathEncoded
            $encodedPart = [Uri]::EscapeDataString($part)
            
            # Construction des chemins
            if ($currentPathRaw -eq "") {
                $currentPathRaw = $part
                $currentPathEncoded = $encodedPart
            } else {
                $currentPathRaw += "/$part"
                $currentPathEncoded += "/$encodedPart"
            }

            # --- VÉRIFICATION (GET) ---
            # Syntaxe Graph : root:/chemin/vers/dossier
            $uriGet = "https://graph.microsoft.com/v1.0/me/drive/root:/$currentPathEncoded"

            try {
                Invoke-RestMethod -Headers $Global:State.Headers -Uri $uriGet -Method Get -ErrorAction Stop > $null
            }
            catch {
                # --- CRÉATION (POST) ---
                # Si le GET échoue, on tente de créer le dossier
                if ($parentPathEncoded -eq "") {
                    # Dossier à la racine
                    $uriPost = "https://graph.microsoft.com/v1.0/me/drive/root/children"
                } else {
                    # Dossier dans un parent (Notez les ':' autour du chemin parent)
                    $uriPost = "https://graph.microsoft.com/v1.0/me/drive/root:/$($parentPathEncoded):/children"
                }

                $body = @{ 
                    name = $part
                    folder = @{} 
                    "@microsoft.graph.conflictBehavior" = "ignore" 
                } | ConvertTo-Json -Compress

                Invoke-RestMethod -Headers $Global:State.Headers -Uri $uriPost -Method POST -Body $body -ContentType "application/json" -ErrorAction Stop > $null
                
                Write-Log "Dossier créé : /$currentPathRaw" "DEBUG"
                $uriPost = "Non générée" # Reset après succès
            }
        }
    }
    catch {
        # --- BLOC D'ERREUR ULTRA-SIMPLIFIÉ ---
        $errorMsg = $_.Exception.Message
        $graphError = "Aucun détail"

        # Tentative sécurisée de lire la réponse du serveur
        if ($_.Exception.InnerException -and $_.Exception.InnerException.Response) {
            try {
                $stream = $_.Exception.InnerException.Response.GetResponseStream()
                $reader = New-Object System.IO.StreamReader($stream)
                $graphError = $reader.ReadToEnd()
            } catch { $graphError = "Impossible de lire la réponse" }
        }

        Write-Log "!!! ERREUR FATALE DANS TEST-ONEDRIVEPATH !!!" "ERROR"
        Write-Log "Segment Fautif : [$part]" "ERROR"
        Write-Log "Chemin Brut    : /$currentPathRaw" "ERROR"
        Write-Log "URI utilisée   : $(if ($uriPost -ne 'Non générée') { $uriPost } else { $uriGet })" "ERROR"
        Write-Log "Message PS     : $errorMsg" "ERROR"
        Write-Log "Réponse Graph  : $graphError" "ERROR"
        
        throw $_ # Arrête proprement le script
    }
}
# =====================================================================
# DÉPLACEMENT
# =====================================================================

# Applique les déplacements planifiés via Graph
function Invoke-Moves {
    Write-Log "Début du déplacement..." "WARN"

    try {
        $total = $Global:State.PlannedActions.Count
        $index = 0

        foreach ($action in $Global:State.PlannedActions) {

            $index++
            if ($index % 200 -eq 0) {
                Write-Progress -Activity "Déplacement OneDrive" `
                    -Status "Fichier $index / $total" `
                    -PercentComplete (($index / $total) * 100)
            }

            try {
                $body = @{
                    parentReference = @{ path = "/drive/root:${($action.DstDir)}" }
                    name            = $action.DstName
                } | ConvertTo-Json

                Invoke-RestMethod -Headers $Global:State.Headers `
                    -Uri "https://graph.microsoft.com/v1.0/me/drive/items/$($action.Id)" `
                    -Method PATCH -Body $body -ErrorAction Stop > $null

                "$(Get-Date -Format 'HH:mm'),$($action.Id),SUCCESS,$($action.SrcPath),$($action.FullDst)," |
                Add-Content $ExecutionReport

                $action.Id | Add-Content $ProcessedLog

                $Global:State.Cache.Files[$action.Id].p = "/drive/root:${($action.DstDir)}"
                $Global:State.Cache.Files[$action.Id].n = $action.DstName
            }
            catch {
                $errorDetails = Get-ErrorDetails $_
                Write-Log "Erreur sur $($action.Id) : $errorDetails" "ERROR"

                "$(Get-Date -Format 'HH:mm'),$($action.Id),ERROR,$($action.SrcPath),$($action.FullDst),$errorDetails" |
                Add-Content $ExecutionReport
            }
        }

        $Global:State.Cache | ConvertTo-Json -Depth 10 | Set-Content $IndexFile
        Write-Log "Déplacement terminé." "SUCCESS"
    }
    catch {
        Write-Log "Erreur Invoke-Moves : $($_.Exception.Message)" "ERROR"
        throw
    }
} # Invoke-Moves



# =====================================================================
# RAPPORT HTML (structure prête)
# =====================================================================

# Génère un rapport HTML simple à partir du plan
function Export-ReportHtml {
    param(
        [string]$OutputFile = ".\onedrive_report.html"  # Fichier HTML de sortie
    )

    try {
        Write-Log "Génération du rapport HTML..." "INFO"

        $html = @"
<html>
<head>
<title>Rapport OneDrive</title>
<style>
body { font-family: Arial; margin: 20px; }
h1 { color: #444; }
table { border-collapse: collapse; width: 100%; margin-top: 20px; }
th, td { border: 1px solid #ccc; padding: 6px; }
th { background: #eee; }
</style>
</head>
<body>
<h1>Rapport OneDrive</h1>
<p>Généré le $(Get-Date)</p>

<h2>Résumé</h2>
<ul>
<li>Total fichiers analysés : $($Global:State.FilesToProcess.Count)</li>
<li>Total actions planifiées : $($Global:State.PlannedActions.Count)</li>
</ul>

<h2>Actions planifiées</h2>
<table>
<tr><th>ID</th><th>Source</th><th>Destination</th></tr>
"@

        foreach ($a in $Global:State.PlannedActions) {
            $html += "<tr><td>$($a.Id)</td><td>$($a.SrcPath)/$($a.SrcName)</td><td>$($a.FullDst)</td></tr>"
        }

        $html += @"
</table>
</body>
</html>
"@

        $html | Set-Content $OutputFile
        Write-Log "Rapport HTML généré : $OutputFile" "SUCCESS"
    }
    catch {
        Write-Log "Erreur Export-ReportHtml : $($_.Exception.Message)" "ERROR"
    }
} # Export-ReportHtml

# =====================================================================
# MAIN
# =====================================================================

# Point d'entrée principal du script
function Start-OneDriveOrganizer {
    <#
    .SYNOPSIS
        Point d'entrée principal de l'organisateur OneDrive.
        Gère le cycle de vie : Nettoyage -> Planification -> Correction -> Exécution.
    #>
    
    # 1. NETTOYAGE DU LOG (Une seule fois au début strict)
    if (Test-Path $LogFile) { 
        try {
            Remove-Item $LogFile -Force -ErrorAction SilentlyContinue
            # On recrée un fichier vide pour que Write-Log puisse écrire immédiatement
            New-Item -Path $LogFile -ItemType File -Force | Out-Null
        } catch {
            Write-Host "Impossible de réinitialiser le log : $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }

    Write-Log "=== DÉMARRAGE DE LA SESSION : $(Get-Date -Format 'dd/MM/yyyy HH:mm:ss') ===" "INFO"

    try {
        # 2. CHARGEMENT ET RÉPARATION DES DONNÉES EN MÉMOIRE
        # Note : On n'appelle Import-Set-Cache qu'UNE SEULE FOIS.
        Import-Set-Cache
        
        # On répare le cache en mémoire (suppression entrées invalides, etc.)
        Repair-Cache       
        
        # On normalise les métadonnées (Chemins, Noms, GPS)
        Repair-Paths
        Repair-Names
        Repair-GPS

        # 3. GESTION DU PLAN (Reprise ou Nouveau)
        # On vérifie si un plan existe déjà pour ce fichier de cache précis (via Hash)
        $hash = Get-CacheHash
        $plan = if ($hash) { Get-ExistingPlan -CurrentHash $hash } else { $null }

        if ($null -eq $plan) {
            Write-Log "Aucun plan valide trouvé. Lancement de l'analyse complète..." "INFO"
            New-Plan
            
            # Après New-Plan, on sauvegarde le hash actuel pour la prochaine fois
            if ($hash) { 
                $hashFile = Join-Path (Split-Path $IndexFile -Parent) "cache_hash.txt"
                $hash | Set-Content $hashFile 
            }
        } 
        else {
            Write-Log "Reprise du plan existant détectée (Hash SHA256 identique)." "SUCCESS"
            $Global:State.PlannedActions = [System.Collections.Generic.List[PSCustomObject]]$plan
        }

        # 4. RÉSOLUTION DES CONFLITS ET VALIDATION
        # On vérifie s'il y a des doublons de noms dans les destinations cibles
        Repair-Collisions
        
        # Analyse finale du plan (doublons restants, chemins trop longs)
        Test-Plan

        # 5. VÉRIFICATION DU MODE D'EXÉCUTION
        if (-not $Execute) {
            Write-Log "----------------------------------------------------------------" "WARN"
            Write-Log "MODE APERÇU (DRY-RUN) : Aucune modification n'a été faite sur le Cloud." "WARN"
            Write-Log "Vérifiez le fichier 'plan.json' dans le dossier _cache." "INFO"
            Write-Log "Relancez le script avec le paramètre -Execute `$true pour appliquer." "INFO"
            Write-Log "----------------------------------------------------------------" "WARN"
            return
        }

        # 6. EXÉCUTION RÉELLE (GRAPH API)
        Write-Log "PASSAGE EN MODE EXÉCUTION RÉELLE..." "WARN"
        Connect-AzureGraph
        
        # Création proactive des dossiers de destination pour éviter les erreurs 404
        Write-Log "Vérification de l'arborescence des dossiers sur OneDrive..." "INFO"
        $uniqueDirs = $Global:State.PlannedActions.DstDir | Select-Object -Unique
        foreach ($dir in $uniqueDirs) { 
            Test-OneDrivePath $dir 
        }

        # Déplacement effectif des fichiers
        Invoke-Moves
        
        Write-Log "Processus d'organisation terminé avec succès." "SUCCESS"
    }
    catch {
        Write-Log "ERREUR FATALE dans Start-OneDriveOrganizer : $($_.Exception.Message)" "ERROR"
        Write-Log "Détails : $($_.ScriptStackTrace)" "DEBUG"
    }
}

Start-OneDriveOrganizer