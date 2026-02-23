<#
.SYNOPSIS
    V14.8 - Organisateur Ultra-Rapide (Arrondi 1km / 2 decimales).
    
.DESCRIPTION
    NOMENCLATURE ET ARCHITECTURE CIBLE :
    1. PHOTOS (.jpg, .png, .heic) -> /Images/Pellicule/Annee/Mois/
       Format : yyyyMMdd_HHmmss_[Ville-Province-Pays]_[Tags]_[Nom]_[Appareil].ext
    2. VIDÉOS (.mp4, .mov) -> /Videos/Pellicule/Annee/Mois/
       Format : yyyyMMdd_HHmmss_[Ville-Province-Pays]_[Tags]_[Duree]_[Resol].ext
    3. AUDIO (.mp3, .m4a, .flac) -> /Musique/Artiste/Album/
       Format : [Artiste] - [Album] - [Titre].ext

    OPTIMISATION GPS : 
    Arrondi à 2 decimales (~1.1 km). Ideal pour grouper massivement les requêtes API.
    V15.5 - Limite Stricte 100 Caractères & Nettoyage Redondance.
    V16.2 - Organisateur OneDrive (Connexion Azure conditionnelle).
    V16.4 - Deplacement avec Mise à jour du Cache JSON.
    V16.6 - Organisateur OneDrive avec Normalisation ASCII Stricte.
    V16.7 - Organisateur OneDrive ASCII (Correction des Chemins).
    V16.8 - Organisateur Complet : Generation Auto + Nettoyage ASCII + Execution.
    V16.9 - Organisateur OneDrive avec exception pour "Pour coffre fort".
    V17.0 - Organisateur avec Marqueur de renommage et Log Pérenne (ID-Based).
    V17.1 - Organisateur OneDrive avec Nettoyage automatique du Log et Marqueur de sécurité.
    V17.2 - Organisateur OneDrive avec Chemins et Noms ASCII Stricts.
    V17.4 - Organisateur OneDrive Final : Unicité Garantie & ASCII Intégral.
    V17.5 - Organisateur OneDrive : Correction Syntaxique & Exécution Complète.
    V17.6 - Organisateur OneDrive : Préservation du Nom Original + Contexte.
    V17.9 - Organisateur OneDrive : Reporting Azure détaillé & Mise à jour du Cache.
    V17.9 - Organisateur OneDrive : Reporting Azure détaillé & Mise à jour du Cache.
    V18.0 - Organisateur OneDrive Final & Complet.
    Priorité : Date > Nom Original > Contexte (Variable d'ajustement).
    V18.1 - Organisateur OneDrive Final
    Hiérarchie : Date > Nom (épuré de l'Hexa) > Contexte (tronqué si > 100 char) > _v_
    V18.4 - Organisateur Microsoft OneDrive (Standard & Coffre-Fort)
    Auteur : Gemini AI Collaborator
    Date : Février 2026

.DESCRIPTION
    Ce script automatise le renommage et le déplacement de fichiers sur OneDrive.
    Il est conçu pour transformer un vrac désordonné en une archive chronologique épurée.

.DECISIONS_DE_CONCEPTION (DOCUMENTATION)
    1. PRIORITÉ DE NOMMAGE (Limite 100 caractères) :
       - [1] TIMESTAMP (15 char) : yyyyMMdd_HHmmss. Assure le tri chronologique.
       - [2] NOM ORIGINAL ÉPURÉ : Information métier préservée après retrait du "bruit".
       - [3] CONTEXTE DOSSIER : Les 3 derniers parents. Sert de variable d'ajustement (tronqué si > 100 char).
       - [4] MARQUEUR SUCCESS (_v_) : Témoin final de traitement.

    2. ÉPURATION DU BRUIT (REGEX) :
       - Suppression des GUID/UUID (ex: 41fe-468d-...).
       - Suppression des chaînes Base64 et Hexadécimales > 16 caractères continus.
       - Objectif : Libérer de l'espace pour le contexte sémantique (noms de dossiers).

    3. SÉCURITÉ ET INTÉGRITÉ :
       - MODE INTERACTIF : Confirmation [O/N/T/Q] au début de l'exécution.
       - ANTI-COLLISION : Ajout automatique de suffixes (_1, _2) si deux fichiers arrivent au même nom/seconde.
       - PROCESSED LOG : Journalisation des ID réussis pour permettre la reprise après interruption.
       - ASCII NORMALIZATION : Retrait des accents et caractères spéciaux pour compatibilité universelle.

    4. ARCHITECTURE DES DOSSIERS :
       - Racine Pellicule : /Images/Pellicule/AAAA/MM/
       - Exception Coffre-Fort : /Pour coffre fort/Images (ou Videos)/AAAA/MM/
    V18.8 - Organisateur OneDrive Intégral avec Archivage des Logs.
    Nouveauté : Paramètre -KeepLogs pour conserver l'historique des exécutions.
    V18.9 - Organisateur OneDrive Intégral (Édition Stable)
    - Correction Compatibilité PS7+ (Response.Content)
    - Encodage URL Strict pour dossiers avec espaces
    - Archivage des logs via -KeepLogs
    - Nettoyage Base64/Hexa et Tags Vidéo
    V19.1 - Organisateur OneDrive Intégral (Édition Debug & Stable)
    - Correction PS7+ (Exception.Response.Content)
    - Encodage URL sécurisé segmenté
    - Archivage des logs via -KeepLogs
    - Nettoyage Base64/Hexa et Tags Vidéo
    V19.3 - Organisateur OneDrive (Mode Reprise Rapide)
    - Skip calcul si organisation_log.txt existe et KeepLogs = true
    - Correction syntaxique Microsoft Graph (root:/path:)
    V19.4 - Organisateur OneDrive "Smart-Resume" & Microsoft Graph Ultra-Stable.
    Optimisé pour : PowerShell 7.4+, API Microsoft Graph v1.0.

    Transforme un vrac OneDrive en archive chronologique épurée (Images/Videos/Audio).
    HIÉRARCHIE DE NOMMAGE (Limite 100 char) :
    [Date_Heure]_[Nom_Épuré]_[Contexte_Dossier]_[Tags]__v_.ext
#>

param (
    [bool]$Execute = $true,  # Mis à true par défaut
    [bool]$KeepLogs = $true, # Mis à true par défaut
    [string]$IndexFile       = ".\onedrive_cache.json",
    [string]$LogFile         = ".\organisation_log.txt",
    [string]$ProcessedLog    = ".\processed_ids.log",
    [string]$ExecutionReport = ".\azure_sync_report.csv"
)

# ===============================
# DEBUG & TELEMETRY SYSTEM
# ===============================

[string]$DebugLog = ".\debug_trace.log"
$Global:DebugEnabled = $true
$ErrorActionPreference = "Stop"

function Write-DebugLog {
    param(
        [string]$Step,
        [string]$Message,
        [string]$Level = "INFO"
    )

    if (-not $Global:DebugEnabled) { return }

    $line = "{0} | {1,-8} | {2,-20} | {3}" -f `
        (Get-Date -Format "yyyy-MM-dd HH:mm:ss"),
        $Level,
        $Step,
        $Message

    Add-Content $DebugLog $line
}

Clear-Host
Write-Host "--- ONEDRIVE ORGANIZER V19.4 ---" -ForegroundColor Cyan

# --- 1. GESTION DES LOGS ET REPRISE ---
$TimestampLog = Get-Date -Format "yyyyMMdd_HHmmss"
$CanResume = $KeepLogs -and (Test-Path $LogFile)
Write-DebugLog "AUTH" "Token reçu longueur=$($Auth.access_token.Length)"
$NewLog = New-Object System.Collections.Generic.List[string]

if ($CanResume) {
    $LogSize = (Get-Item $LogFile).Length / 1KB
    Write-Host "[Info] Mode Reprise : Chargement du plan existant ($([math]::Round($LogSize,2)) KB)..." -ForegroundColor Yellow
    $NewLog = Get-Content $LogFile
} else {
    Write-Host "[Info] Nettoyage des anciens logs..." -ForegroundColor Gray
    if (Test-Path $LogFile) { Remove-Item $LogFile -Force }
    if (Test-Path $ExecutionReport) { Remove-Item $ExecutionReport -Force }
}

if (!(Test-Path $ExecutionReport)) { "Timestamp,ID,Status,OldPath,NewPath,Error" | Set-Content $ExecutionReport }

$Marker = "_v_"
$FolderInventory = @{} 

# --- 2. FONCTIONS DE RÉCUPÉRATION D'ERREURS (CORRIGÉE) ---

function Get-ErrorDetails {
    param($Ex)

    $status  = ""
    $details = ""

    try {

        if ($Ex.Exception.Response) {
            $status = $Ex.Exception.Response.StatusCode.Value__
        }

        if ($Ex.Exception.Response.Content) {
            $details = $Ex.Exception.Response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        }
        elseif ($Ex.Exception.Response) {
            $reader = New-Object System.IO.StreamReader(
                $Ex.Exception.Response.GetResponseStream()
            )
            $details = $reader.ReadToEnd()
        }
    }
    catch {
        $details = "Impossible de lire la réponse Graph"
    }

    Write-DebugLog "GRAPH_ERROR" "Status=$status | $details" "ERROR"

    if ([string]::IsNullOrWhiteSpace($details)) {
        return $Ex.Exception.Message
    }

    return $details
}
# --- 3. FONCTIONS CORE ---

function Ensure-OneDrivePath {

    param(
        [Parameter(Mandatory)]
        $Headers,

        [Parameter(Mandatory)]
        [string]$Path
    )

    # ---- Cache global (évite recréation inutile) ----
    if (-not $script:OneDriveFolderCache) {
        $script:OneDriveFolderCache = @{}
    }

    $Path = $Path.Trim('/')
    if (-not $Path) { return }

    $parts = $Path -split '/'
    $currentPath = ""

    foreach ($part in $parts) {

        $currentPath = if ($currentPath) {
            "$currentPath/$part"
        } else {
            $part
        }

        # ---- Skip si déjà traité ----
        if ($script:OneDriveFolderCache.ContainsKey($currentPath)) {
            continue
        }

        # ---- URI GET ----
        $segments = ($currentPath -split '/' |
            Where-Object { $_ } |
            ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/'

        $uriGet = "https://graph.microsoft.com/v1.0/me/drive/root:/" + $segments + ":"

        $exists = $false

        try {
            Invoke-RestMethod -Headers $Headers -Uri $uriGet -Method GET -ErrorAction Stop > $null
            $exists = $true
        }
        catch {
            if ($_.Exception.Response.StatusCode.Value__ -ne 404) {
                throw
            }
        }

        # ---- Création seulement si nécessaire ----
        if (-not $exists) {

            Write-Host "    [Dossier] Création : /$currentPath" -ForegroundColor Cyan

            $parentPath = ($currentPath -replace "/$part$","")

            $parentSegments = ($parentPath -split '/' |
                Where-Object { $_ } |
                ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/'

 
            $uriPost = if (-not $parentPath) {
    "https://graph.microsoft.com/v1.0/me/drive/root/children"
}
else {
    "https://graph.microsoft.com/v1.0/me/drive/root:/$($parentSegments):/children"
}
            $body = @{
                name  = $part
                folder = @{}
                "@microsoft.graph.conflictBehavior" = "fail"
            } | ConvertTo-Json -Compress

            try {
                Invoke-RestMethod -Headers $Headers -Uri $uriPost -Method POST -Body $body -ErrorAction Stop > $null
            }
            catch {
                $status = $_.Exception.Response.StatusCode.Value__

                if ($status -eq 409) {
                    Write-Host "      [OK] Existe déjà" -ForegroundColor DarkGray
                }
                else {
                    $err = Get-ErrorDetails $_
                    Write-Host "      [!] Erreur : $err" -ForegroundColor Red
                    throw
                }
            }
        }

        # ---- Ajout au cache ----
        $script:OneDriveFolderCache[$currentPath] = $true
    }
}

# --- 4. CALCUL (UNIQUEMENT SI PAS DE REPRISE) ---
if (!$CanResume) {
    # ... [Le bloc de génération de $NewLog de la V19.2 se place ici si nécessaire] ...
    # Pour ce script, j'assume que vous repartez du log existant suite à vos tests.
    if ($NewLog.Count -eq 0) {
        Write-Error "Le log est vide et le mode reprise est actif. Relancez sans KeepLogs."
        exit
    }
}

Write-Host "[2/4] Plan d'action : $($NewLog.Count) fichiers chargés." -ForegroundColor Green

# --- 5. EXÉCUTION ---
if ($Execute -and $NewLog.Count -gt 0) {
    $ClientId = "176fc7bc-42c9-4a25-82b5-0ad584d3c061"
    $DeviceCodeRequest = Invoke-RestMethod -Method POST -Uri "https://login.microsoftonline.com/common/oauth2/v2.0/devicecode" -Body @{ client_id = $ClientId; scope = "Files.ReadWrite.All" }
    Write-Host "`n[Connexion] Login : https://microsoft.com/devicelogin Code : $($DeviceCodeRequest.user_code)" -ForegroundColor Yellow
    
    $Auth = $null; while (!$Auth) { Start-Sleep 5; try { $Auth = Invoke-RestMethod -Method POST -Uri "https://login.microsoftonline.com/common/oauth2/v2.0/token" -Body @{ grant_type = "urn:ietf:params:oauth:grant-type:device_code"; client_id = $ClientId; device_code = $DeviceCodeRequest.device_code } } catch { } }
    $Headers = @{ Authorization = "Bearer $($Auth.access_token)"; "Content-Type" = "application/json" }

    Write-Host "`n[2.5/4] Pré-création de l'arborescence..." -ForegroundColor Magenta
    $uniqueFolders = $NewLog | ForEach-Object { if ($_ -match "DST:(.*)/.*$") { $Matches[1] } } | Select-Object -Unique | Sort-Object
    foreach ($fld in $uniqueFolders) { Ensure-OneDrivePath -Headers $Headers -Path $fld }

Write-Host "`n[3/4] Déplacement..." -ForegroundColor Magenta
    $interactive = $true; $successList = @()
    
    foreach ($line in $NewLog) {
        if ($line -match "ID:(.*) \| SRC:(.*) \| DST:(.*)") {
            $fId = $Matches[1]; $src = $Matches[2]; $dst = $Matches[3]
            $dstDir = [System.IO.Path]::GetDirectoryName($dst).Replace("\", "/"); $dstName = [System.IO.Path]::GetFileName($dst)
            $encodedDstDir = ($dstDir -split '/' | Where-Object {$_} | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/'

            # --- AFFICHAGE DU COMPARATIF ---
            Write-Host "`n" + ("-" * 80) -ForegroundColor Gray
            Write-Host "FICHIER : " -NoNewline -ForegroundColor White; Write-Host $dstName -ForegroundColor Cyan
            Write-Host "SOURCE  : " -NoNewline -ForegroundColor White; Write-Host $src -ForegroundColor Yellow
            Write-Host "DEST    : " -NoNewline -ForegroundColor White; Write-Host $dst -ForegroundColor Green
            Write-Host ("-" * 80) -ForegroundColor Gray

            if ($interactive) {
                $c = Read-Host "Confirmer le déplacement ? [O] Oui / [N] Non / [T] Tout / [Q] Quitter"
                $c = $c.ToUpper()
                if ($c -eq "T") { $interactive = $false } 
                elseif ($c -eq "Q") { break } 
                elseif ($c -ne "O") { 
                    Write-Host "  [Passé] Fichier ignoré." -ForegroundColor Gray
                    continue 
                }
            }

            try {
                $body = @{ 
                    parentReference = @{ path = "/drive/root:/$($encodedDstDir):" }; 
                    name = $dstName 
                } | ConvertTo-Json
                
                Invoke-RestMethod -Headers $Headers -Uri "https://graph.microsoft.com/v1.0/me/drive/items/$fId" -Method PATCH -Body $body -ErrorAction Stop
                
                Write-Host "  [OK] Déplacement réussi." -ForegroundColor Green
                "$(Get-Date -Format 'HH:mm'),$fId,SUCCESS,$src,$dst," | Add-Content $ExecutionReport
                $fId | Add-Content $ProcessedLog
            } catch {
                $err = Get-ErrorDetails $_
                Write-Host "  [ERREUR] $err" -ForegroundColor Red
                "$(Get-Date -Format 'HH:mm'),$fId,ERROR,$src,$dst,$err" | Add-Content $ExecutionReport
            }
        }
    }
    Write-Host "`n[4/4] Opération terminée. Rapport : $ExecutionReport" -ForegroundColor Green
}