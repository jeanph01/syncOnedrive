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
#>
<#
.SYNOPSIS
    V18.8 - Organisateur OneDrive Intégral avec Archivage des Logs.
    Nouveauté : Paramètre -KeepLogs pour conserver l'historique des exécutions.
#>
<#
.SYNOPSIS
    V18.9 - Organisateur OneDrive Intégral (Édition Stable)
    - Correction Compatibilité PS7+ (Response.Content)
    - Encodage URL Strict pour dossiers avec espaces
    - Archivage des logs via -KeepLogs
    - Nettoyage Base64/Hexa et Tags Vidéo
#>
<#
.SYNOPSIS
    V19.1 - Organisateur OneDrive Intégral (Édition Debug & Stable)
    - Correction PS7+ (Exception.Response.Content)
    - Encodage URL sécurisé segmenté
    - Archivage des logs via -KeepLogs
    - Nettoyage Base64/Hexa et Tags Vidéo
#>

param (
    [bool]$Execute = $true,
    [bool]$KeepLogs = $true,
    [string]$IndexFile = ".\onedrive_cache.json",
    [string]$LogFile = ".\organisation_log.txt",
    [string]$ProcessedLog = ".\processed_ids.log",
    [string]$ExecutionReport = ".\azure_sync_report.csv"
)

Clear-Host
Write-Host "--- ONEDRIVE ORGANIZER V19.1 ---" -ForegroundColor Cyan

# --- 1. GESTION DES LOGS ---
$TimestampLog = Get-Date -Format "yyyyMMdd_HHmmss"
if ($KeepLogs) {
    Write-Host "[Info] Archivage des logs activé." -ForegroundColor Gray
    if (Test-Path $LogFile) { Rename-Item $LogFile "organisation_log_$TimestampLog.txt" }
    if (Test-Path $ExecutionReport) { Rename-Item $ExecutionReport "azure_sync_report_$TimestampLog.csv" }
} else {
    if (Test-Path $LogFile) { Remove-Item $LogFile -Force }
}
"Timestamp,ID,Status,OldPath,NewPath,Error" | Set-Content $ExecutionReport

$Marker = "_v_"
$FolderInventory = @{} 

# --- 2. FONCTIONS DE RÉCUPÉRATION D'ERREURS ---

function Get-ErrorDetails {
    param($Ex)
    $details = ""
    try {
        # Si PowerShell 7 (utilise HttpResponseMessage)
        if ($Ex.Response.Content) {
            $details = $Ex.Response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        } 
        # Si PowerShell 5.1 (utilise WebResponse)
        elseif ($Ex.Response) {
            $reader = New-Object System.IO.StreamReader($Ex.Response.GetResponseStream())
            $details = $reader.ReadToEnd()
        }
    } catch {
        $details = "Flux d'erreur illisible."
    }
    
    if ([string]::IsNullOrWhiteSpace($details)) { $details = $Ex.Message }
    return $details
}

# --- 3. FONCTIONS DE NETTOYAGE ET DOSSIERS ---

function Get-CleanAscii {
    param([string]$text, [bool]$isPath = $false)
    if ([string]::IsNullOrWhiteSpace($text)) { return "" }
    $normalized = $text.Normalize([System.Text.NormalizationForm]::FormD)
    $sb = New-Object System.Collections.Generic.List[char]
    foreach ($c in $normalized.ToCharArray()) {
        if ([System.Globalization.CharUnicodeInfo]::GetUnicodeCategory($c) -ne [System.Globalization.UnicodeCategory]::NonSpacingMark) {
            $sb.Add($c)
        }
    }
    $clean = (-join $sb) -replace "[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}", ""
    $clean = $clean -replace "[a-zA-Z0-9]{16,}", ""
    $pattern = if ($isPath) { "[^a-zA-Z0-9\.\-/]" } else { "[^a-zA-Z0-9\.\-]" }
    return ($clean -replace $pattern, "_" -replace "_+", "_").Trim("_")
}

function Get-SmartMergedName {
    param($ts, $context, $oldName, $marker, $ext, $vTags)
    $cleanOld = Get-CleanAscii $oldName $false
    $cleanCtx = Get-CleanAscii $context $false
    $filteredWords = ($cleanOld -split "_" | Where-Object { $ts -notmatch $_ -and $_.Length -gt 1 }) -join "_"
    $fixedLen = $ts.Length + $filteredWords.Length + $marker.Length + $vTags.Length + $ext.Length + 4
    $avail = 100 - $fixedLen
    $finalCtx = ""
    if ($avail -gt 5 -and $cleanCtx) {
        $finalCtx = if ($cleanCtx.Length -gt $avail) { $cleanCtx.Substring($cleanCtx.Length - $avail).Trim("_") } else { $cleanCtx }
    }
    $parts = New-Object System.Collections.Generic.List[string]
    $parts.Add($ts); if ($filteredWords) { $parts.Add($filteredWords) }; if ($finalCtx) { $parts.Add($finalCtx) }; if ($vTags) { $parts.Add($vTags) }
    return "$(($parts -join "_").Trim('_'))$marker$ext"
}

function Ensure-OneDrivePath {
    param($Headers, $Path)
    $Path = $Path.Trim('/')
    $parts = $Path -split '/'
    $currentPath = ""
    
    foreach ($part in $parts) {
        $parentPath = $currentPath
        $currentPath += if ($currentPath -eq "") { $part } else { "/$part" }
        
        # Encodage sécurisé de chaque segment
        $segments = ($currentPath -split '/' | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/'
        
        # AJOUT DU ":" FINAL pour fermer le segment "path"
        $uriGet = "https://graph.microsoft.com/v1.0/me/drive/root:/$($segments):"

        try {
            write-Host "  Vérification : /$currentPath" -ForegroundColor Gray
            write-Host "    Segments encodés : $segments" -ForegroundColor DarkGray
            write-Host "    URI GET : $uriGet" -ForegroundColor DarkGray
            write-Host "    Headers : $($Headers | Out-String)" -ForegroundColor DarkGray            

            Invoke-RestMethod -Headers $Headers -Uri $uriGet -Method Get -ErrorAction Stop > $null
        } catch {
            Write-Host "    [Dossier] Création : /$currentPath" -ForegroundColor Cyan
            
            $parentSegments = ($parentPath -split '/' | Where-Object {$_} | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/'
            
            # Pour la création (POST), la syntaxe est root:/chemin:/children
            $uriPost = if ($parentPath -eq "") { 
                "https://graph.microsoft.com/v1.0/me/drive/root/children" 
            } else { 
                "https://graph.microsoft.com/v1.0/me/drive/root:/$($parentSegments):/children" 
            }

            $body = @{ 
                name = $part; 
                folder = @{}; 
                "@microsoft.graph.conflictBehavior" = "ignore" 
            } | ConvertTo-Json -Compress

            try {
                write-host "headers = $Headers"
                write-host "URI POST = $uriPost"
                write-host "Body = $body"

                $resp = Invoke-RestMethod -Headers $Headers -Uri $uriPost -Method POST -Body $body -ErrorAction Stop > $null
            } catch {
                $err = Get-ErrorDetails $_
                Write-Host "      [!] Détail : $err, resp = $resp" -ForegroundColor Yellow
            }
        }
    }
}

function Get-TargetRoot {
    param([string]$SourcePath) 
    # Détection des racines spécifiques selon vos dossiers de départ 
    if ($SourcePath -like "*Pour coffre fort/Michelle*") { return "Pour coffre fort/Michelle" } 
    if ($SourcePath -like "*Pour coffre fort/relations*") { return "Pour coffre fort/relations" } 
    if ($SourcePath -like "*Pour coffre fort/archives*") { return "Pour coffre fort/archives" } 
    if ($SourcePath -like "*Videos*") { return "Videos" } 
    return "Images/Pellicule" # Par défaut pour les photos 
}

# --- 4. ANALYSE ET CALCULS ---
if (!(Test-Path $IndexFile)) { Write-Error "Cache introuvable."; exit }
$Cache = Get-Content $IndexFile | ConvertFrom-Json -AsHashtable
$DoneIds = @{}; if (Test-Path $ProcessedLog) { Get-Content $ProcessedLog | ForEach-Object { $DoneIds[$_] = $true } }

Write-Host "[1/4] Analyse des fichiers..." -ForegroundColor Gray
$NewLog = New-Object System.Collections.Generic.List[string]

foreach ($id in $Cache.Files.Keys) {
    if ($DoneIds.ContainsKey($id)) { continue }
    $f = $Cache.Files[$id]
    if ($f.n -match $Marker) { continue }
    $ext = [System.IO.Path]::GetExtension($f.n).ToLower()
    if ($ext -notmatch ".jpg|.jpeg|.png|.heic|.mp4|.mov") { continue }

    $ts = ([DateTime]$f.d).ToString("yyyyMMdd_HHmmss")
    $vTags = if ($f.dur -or $f.res) { (($f.dur, $f.res | Where-Object {$_}) -join "_") } else { "" }
    $pathParts = $f.p -split "/" | Where-Object { $_ -and $_ -notmatch "drive|root|Images|Videos|Pellicule" }
    $context = if ($pathParts.Length -gt 0) { ($pathParts[[Math]::Max(0, $pathParts.Length-3)..($pathParts.Length-1)]) -join "_" } else { "" }

    $newName = Get-SmartMergedName $ts $context ([System.IO.Path]::GetFileNameWithoutExtension($f.n)) $Marker $ext $vTags
    $subType = if ($ext -match "mp4|mov") { "Videos" } else { "Images" }
    $rawDest = if ($f.p -match "Pour coffre fort") { "Pour coffre fort/$subType/$(([DateTime]$f.d).Year)/$(([DateTime]$f.d).ToString('MM'))" }
               else { "$subType/Pellicule/$(([DateTime]$f.d).Year)/$(([DateTime]$f.d).ToString('MM'))" }
    

    # Appel correct de la fonction
    $targetRoot = Get-TargetRoot -SourcePath $f.p

    # Utilisation de la racine déterminée pour construire le chemin final
    $rawDest = if ($targetRoot -like "Pour coffre fort*") { 
        "$targetRoot/$subType/$(([DateTime]$f.d).Year)/$(([DateTime]$f.d).ToString('MM'))" 
    } else { 
        "$targetRoot/$(([DateTime]$f.d).Year)/$(([DateTime]$f.d).ToString('MM'))" 
    }

    $cleanDest = Get-CleanAscii $rawDest $true
    $targetKey = "/$cleanDest/$newName"
    $suffix = 1
    while ($FolderInventory.ContainsKey($targetKey)) {
        $newName = $newName -replace "$Marker", "_$suffix$Marker"
        $targetKey = "/$cleanDest/$newName"; $suffix++
    }
    $FolderInventory[$targetKey] = $true
    $NewLog.Add("ID:$id | SRC:$($f.p)/$($f.n) | DST:$targetKey")
}
$NewLog | Set-Content $LogFile
Write-Host "[2/4] Plan d'action : $($NewLog.Count) fichiers." -ForegroundColor Green

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

            Write-Host "`nFichier : $dstName" -ForegroundColor Gray
            if ($interactive) {
                $c = Read-Host "Confirmer ? [O] Oui / [N] Non / [T] Tout / [Q] Quitter"
                if ($c -eq "T") { $interactive = $false } elseif ($c -eq "Q") { break } elseif ($c -ne "O") { continue }
            }
            try {
                $body = @{ parentReference = @{ path = "/drive/root:$dstDir" }; name = $dstName } | ConvertTo-Json
                Invoke-RestMethod -Headers $Headers -Uri "https://graph.microsoft.com/v1.0/me/drive/items/$fId" -Method PATCH -Body $body -ErrorAction Stop
                "$(Get-Date -Format 'HH:mm'),$fId,SUCCESS,$src,$dst," | Add-Content $ExecutionReport
                $fId | Add-Content $ProcessedLog
                $successList += [PSCustomObject]@{ Id = $fId; NewPath = $dstDir; NewName = $dstName }
            } catch {
                $err = Get-ErrorDetails $_
                Write-Host "  [ERREUR] $err" -ForegroundColor Red
                "$(Get-Date -Format 'HH:mm'),$fId,ERROR,$src,$dst,$err" | Add-Content $ExecutionReport
            }
        }
    }
    foreach ($item in $successList) { $Cache.Files[$item.Id].p = "/drive/root:$($item.NewPath)"; $Cache.Files[$item.Id].n = $item.NewName }
    $Cache | ConvertTo-Json -Depth 10 | Set-Content $IndexFile
} else { Write-Host "`n[Aperçu] Première action : $($NewLog[0])" -ForegroundColor Yellow }