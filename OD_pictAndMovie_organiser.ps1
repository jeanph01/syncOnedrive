<# 
    =====================================================================
    V14.0 - Organisateur avec Feedback détaillé, Chronométrage et Cache GPS Persistant.
    
.DESCRIPTION
    NOMENCLATURE ET ARCHITECTURE CIBLE :
    
    1. PHOTOS (.jpg, .png, .heic) -> /Images/Pellicule/Année/Mois/
       Format : yyyyMMdd_HHmmss_[Ville]_[Dossiers_Tags]_[Nom_Original]_[Appareil].ext
       
    2. VIDÉOS (.mp4, .mov) -> /Vidéos/Pellicule/Année/Mois/
       Format : yyyyMMdd_HHmmss_[Ville]_[Dossiers_Tags]_[Durée]_[Résolution].ext
       
    3. AUDIO (.mp3, .m4a, .flac) -> /Musique/Artiste/Album/
       Format : [Artiste] - [Album] - [Titre].ext

    FONCTIONNEMENT :
    - WhatIf par défaut : Analyse et génère un log sans déplacer de fichiers.
    - Cache GPS Persistant : Sauvegarde automatique à chaque découverte de lieu.
    - Tags de Chemin : Préserve le contexte hiérarchique original.

    FONCTIONNEMENT DU CACHE :
    Si une entrée GPS existe mais ne contient pas la hiérarchie complète (ex: juste "Palma"),
    le script force un rafraîchissement via l'API pour obtenir Province et Pays.
.PARAMETER Execute
    $false (DÉFAUT) : Mode simulation. Génère le fichier de log.
    $true : Applique les changements sur OneDrive.
===================================================================== 
#>

param (
    [bool]$Execute = $false,
    [string]$IndexFile = ".\onedrive_cache.json",   # fichier d'entree
    [string]$LogFile = ".\organisation_log.txt",    # log des infos envoyées a la console
    [string]$ProcessedLog = ".\processed_ids.log",  # liste des id traités (pour accelerer les traitement subsequents)
    [string]$ExecutionReport = ".\azure_sync_report.csv",
    [string]$GpsCacheFile = ".\gps_cache.json",     # cache des noms de localisations selon leur coordonnées GPS
    [bool]$VerboseMode = $true                      # equivalent de debug
)

# =====================================================================
# MODULE EXTERNE
# =====================================================================

Import-Module ".\OneDriveTools.psm1" -Force -ArgumentList "176fc7bc-42c9-4a25-82b5-0ad584d3c061", ".\graph_token.json", $LogFile

# =====================================================================
# 1. CONFIGURATION GLOBALE
# =====================================================================

# Mapping des extensions vers leur catégorie
$ExtensionMap = @{}
@(".jpg", ".jpeg", ".png", ".heic", ".bmp", ".gif", ".pcx", ".webp") | ForEach-Object { $ExtensionMap[$_] = "Images" }
@(".mp4", ".mov", ".avi", ".mpg", ".mpeg", ".wmv", ".flv", ".m4v", ".webm") | ForEach-Object { $ExtensionMap[$_] = "Videos" }
@(".mp3", ".m4a", ".flac", ".wma", ".wav") | ForEach-Object { $ExtensionMap[$_] = "Musique" }

# Configuration centrale
$Config = [PSCustomObject]@{
    RenameMarker = "--odr--"  # indique un fichier deja traité -- OneDriveRenamed --
    MaxNameLen   = 100
    # pour les connexions Azure
    ClientId     = "176fc7bc-42c9-4a25-82b5-0ad584d3c061"
    ExtensionMap = $ExtensionMap
}

# État global du script
$Global:State = @{
    Headers        = $null
    Cache          = $null
    ProcessedIds   = @{}
    PlannedActions = New-Object System.Collections.Generic.List[PSCustomObject]
    FilesToProcess = @{}
}

# =====================================================================
# 2. LOGGING
# =====================================================================

function Write-Log {
    [CmdletBinding()]
    param([string]$Message, [string]$Level = "INFO")

    # TODO - voir si Get-Date ralenti ou c'est plutot le Add-Content
    $timestamp = Get-Date -Format "HH:mm:ss"

    $color = switch ($Level) {
        "ERROR" { "Red" }
        "WARN" { "Yellow" }
        "SUCCESS" { "Green" }
        "DEBUG" { "DarkGray" }
        default { "Gray" }
    }

    if ($Level -ne "DEBUG" -or $VerboseMode) {
        Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
    }

    "[$timestamp] [$Level] $Message" | Add-Content $LogFile -ErrorAction SilentlyContinue
}

# =====================================================================
# 3. UTILITAIRES
# =====================================================================

function Get-ErrorDetails {
    [CmdletBinding()]
    param($Exception)

    try {
        if ($Exception.Response) {
            $reader = New-Object System.IO.StreamReader($Exception.Response.GetResponseStream())
            return $reader.ReadToEnd()
        }
    }
    catch {}

    return $Exception.Message
}

function Convert-ToAscii {
    [CmdletBinding()]
    param([string]$Text, [bool]$IsPath = $false)

    if ([string]::IsNullOrWhiteSpace($Text)) { return "" }

    # Normalisation Unicode → ASCII
    $clean = $Text.Normalize([System.Text.NormalizationForm]::FormD) -replace '\p{M}', ''

    # Suppression GUIDs et longues séquences hex/base64
    $clean = $clean -replace "[a-fA-F0-9]{8}-([a-fA-F0-9]{4}-){3}[a-fA-F0-9]{12}", ""
    $clean = $clean -replace "[a-zA-Z0-9]{16,}", ""

    # Filtrage caractères invalides
    $pattern = if ($IsPath) { "[^a-zA-Z0-9\.\-/]" } else { "[^a-zA-Z0-9\.\-]" }

    return ($clean -replace $pattern, "_" -replace "_+", "_").Trim("_")
}

# =====================================================================
# 4. LOGIQUE MÉTIER
# =====================================================================
function Get-LocationName($gps) {
    if (!$gps -or $gps -eq "," -or $gps -match "^0,0$") { return $null }
    
    $cachedValue = $script:GpsCache[$gps]
    
    # CRITÈRES DE RAFRAÎCHISSEMENT
    $isIncomplete = $cachedValue -and ($cachedValue -split "-").Count -lt 3
    $hasSpecialChars = $cachedValue -and ($cachedValue -match "[^\x00-\x7F]") # Détecte tout ce qui n'est pas ASCII standard

    if ($cachedValue -and !$isIncomplete -and !$hasSpecialChars) { 
        return $cachedValue 
    }
    
    $reason = if ($hasSpecialChars) { "Caractères Spéciaux" } elseif ($isIncomplete) { "Incomplet" } else { "Nouveau" }
    Write-Host " [API GPS] $reason ($gps)..." -ForegroundColor DarkYellow -NoNewline
    
    try {
        $lat, $lon = $gps -split ","
        $Uri = "https://nominatim.openstreetmap.org/reverse?format=json&lat=$($lat.Trim())&lon=$($lon.Trim())&zoom=10&addressdetails=1"
        $res = Invoke-RestMethod -Uri $Uri -UserAgent "OneDriveOrganizer_JPM" -ErrorAction SilentlyContinue
        
        $addr = $res.address
        $city = if ($addr.city) { $addr.city } elseif ($addr.town) { $addr.town } else { $addr.village }
        $state = if ($addr.state) { $addr.state } else { $addr.county }
        $country = $addr.country

        if ($city -and $country) { 
            # 1. Concaténation
            $fullLoc = "$city-$state-$country" -replace " ", "-"
            
            # 2. Nettoyage strict (ASCII uniquement + tirets)
            # On normalise pour transformer les accents (é -> e) si possible, sinon on supprime le non-latin
            $normalized = $fullLoc.Normalize([System.Text.NormalizationForm]::FormD)
            $cleanBuilder = New-Object System.Text.StringBuilder
            foreach ($char in $normalized.ToCharArray()) {
                if ([System.Globalization.CharUnicodeInfo]::GetUnicodeCategory($char) -ne [System.Globalization.UnicodeCategory]::NonSpacingMark) {
                    [void]$cleanBuilder.Append($char)
                }
            }
            $fullLoc = $cleanBuilder.ToString()
            $fullLoc = [Regex]::Replace($fullLoc, "[^a-zA-Z0-9\-]", "")
            $fullLoc = ($fullLoc -replace "-+", "-").Trim("-")
            
            $script:GpsCache[$gps] = $fullLoc
            $script:GpsCache | ConvertTo-Json | Set-Content $GpsCacheFile
            Write-Host " OK: $fullLoc" -ForegroundColor Green
            Start-Sleep -Milliseconds 1100 
            return $fullLoc
        }
    }
    catch { Write-Host " Échec." -ForegroundColor Red }
    return $null
} # Get-LocationName

function Get-SmartCategory {
    param ([string]$Path, [string]$Extension)

    # 1. RÈGLES "STAY" : Dossiers où l'on renomme sans déplacer
    $stayPatterns = @("Finances", "Légal", "Documents", "Vie des enfants", "JPM", "Loisirs", "Livres", "Cuisine", "Syndicat", "Apps")
    foreach ($p in $stayPatterns) { if ($Path -match "(?i)$p") { return "Stay" } }

    # 2. RÈGLES "COFFRE-FORT" : Maintien de la racine (ex: michelle, archives)
    if ($Path -match "(?i)Pour coffre fort/([^/]+)") { return "Coffre-fort/$($Matches[1])" }
    
    # 3. STANDARDS
    $ext = $Extension.ToLower()
    if ($Config.ExtensionMap.ContainsKey($ext)) { return $Config.ExtensionMap[$ext] }

    return "Stay" # Par défaut, on ne déplace pas si inconnu
}

function Get-TargetRoot {
    <#
        .SYNOPSIS
            Détermine la racine OneDrive de destination selon un moteur de règles.

        .DESCRIPTION
            Cette version utilise un système déclaratif de règles permettant :
                - De détecter les dossiers sensibles (Finance, Impôts…)
                - De préserver les dossiers de travail (Projets, Études…)
                - De gérer les sous-dossiers du coffre-fort
                - De reconnaître les dossiers d’applications (WhatsApp, Messenger…)
                - De distinguer les vidéos des images
                - De décider si un fichier doit être déplacé ou renommé sur place

            Chaque règle définit :
                - Patterns à détecter
                - Action (Move / Stay)
                - Racine cible (si Move)
                - Priorité (plus petit = plus prioritaire)

            Le système est entièrement extensible sans modifier la fonction.
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SourcePath
    )

    # ------------------------------------------------------------------
    # TABLE DES RÈGLES (déclarative, modifiable facilement)
    # ------------------------------------------------------------------
    $Rules = @(
        # 1. Coffre-fort (priorité maximale)
        @{
            Name       = "CoffreFort-Michelle"
            Patterns   = @("Pour coffre fort/Michelle")
            Action     = "Move"
            TargetRoot = "Pour coffre fort/Michelle"
            Priority   = 1
        },
        @{
            Name       = "CoffreFort-Relations"
            Patterns   = @("Pour coffre fort/relations")
            Action     = "Move"
            TargetRoot = "Pour coffre fort/relations"
            Priority   = 1
        },
        @{
            Name       = "CoffreFort-Archives"
            Patterns   = @("Pour coffre fort/archives")
            Action     = "Move"
            TargetRoot = "Pour coffre fort/archives"
            Priority   = 1
        },

        # 2. Dossiers administratifs (renommer sur place)
        @{
            Name       = "Administratif"
            Patterns   = @("Finance", "Fiscalité", "Impôts", "Banque", "Assurance", "Documents", "Contrats", "Notaire", "Municipalité", "Syndicat")
            Action     = "Stay"
            TargetRoot = $null
            Priority   = 2
        },

        # 3. Dossiers de travail / projets (renommer sur place)
        @{
            Name       = "TravailEtudes"
            Patterns   = @("Projets", "Travail", "Études", "Recherche", "Cours", "Université")
            Action     = "Stay"
            TargetRoot = $null
            Priority   = 3
        },

        # 4. Dossiers techniques (renommer sur place)
        @{
            Name       = "Technique"
            Patterns   = @("Scripts", "Dev", "GitHub", "Backups", "Exports")
            Action     = "Stay"
            TargetRoot = $null
            Priority   = 4
        },

        # 5. Dossiers d’applications (déplacer vers Pellicule)
        @{
            Name       = "Applications"
            Patterns   = @("WhatsApp", "Messenger", "Facebook", "Instagram", "Screenshots", "Camera Roll", "DCIM", "Android", "iOS")
            Action     = "Move"
            TargetRoot = "Images/Pellicule"
            Priority   = 5
        },

        # 6. Vidéos (déplacer vers Videos)
        @{
            Name       = "Videos"
            Patterns   = @("Videos")
            Action     = "Move"
            TargetRoot = "Videos"
            Priority   = 6
        }
    )

    # ------------------------------------------------------------------
    # MOTEUR DE RÈGLES
    # ------------------------------------------------------------------

    # Tri des règles par priorité
    $OrderedRules = $Rules | Sort-Object Priority

    foreach ($rule in $OrderedRules) {
        foreach ($pattern in $rule.Patterns) {
            if ($SourcePath -match [Regex]::Escape($pattern)) {

                # Si l’action est "Stay", on renomme sur place
                if ($rule.Action -eq "Stay") {
                    return @{
                        Action     = "Stay"
                        TargetRoot = $null
                        Rule       = $rule.Name
                    }
                }

                # Sinon on déplace vers la racine définie
                return @{
                    Action     = "Move"
                    TargetRoot = $rule.TargetRoot
                    Rule       = $rule.Name
                }
            }
        }
    }

    # ------------------------------------------------------------------
    # CAS PAR DÉFAUT : IMAGES / PELLICULE
    # ------------------------------------------------------------------
    return @{
        Action     = "Move"
        TargetRoot = "Images/Pellicule"
        Rule       = "Default"
    }
} # Get-TargetRoot

function Get-PathTags($fullPath) {
    $parts = $fullPath -replace "^/drive/root:/?", "" -split "/" | 
    Where-Object { $_ -and $_ -notmatch "Documents|Images|Vidéos|Musique|Pellicule|JPM" }
    return ($parts -join "_")
}

<#
    =====================================================================
    New-SmartFileName — Style 3 Complet (V15)
    =====================================================================

    OBJECTIF :
        Générer un nom de fichier propre, court, structuré et déterministe
        basé sur :
            - la date (timestamp)
            - la localisation GPS (si disponible)
            - les tags de chemin (hiérarchie utile)
            - le nom original
            - l’appareil photo (caméra)
            - la source (WhatsApp, Messenger, etc.)
            - un marqueur de traitement (--odr--)
            - une limite stricte de longueur

    ---------------------------------------------------------------------
    RÈGLES DÉTAILLÉES
    ---------------------------------------------------------------------

    1. NORMALISATION ASCII
        - Tous les blocs (nom original, tags, GPS, caméra, source)
          passent par Convert-ToAscii :
              • accents supprimés (é → e)
              • caractères spéciaux remplacés par "_"
              • séquences multiples "_" compressées
              • résultat 100 % ASCII

    2. DÉCOUPAGE EN MOTS
        - Chaque bloc est découpé en mots selon les séparateurs :
              "_", "-", espace
        - Les mots vides sont ignorés
        - Tout est mis en minuscules pour les comparaisons internes

    3. SUPPRESSION DES MOTS VIDES (STOPWORDS)
        - Les mots suivants sont supprimés car non informatifs :
              de, du, des, la, le, les,
              avec, pour, sur, dans, et, en,
              a, au, aux
        - Cela évite des noms trop longs et peu lisibles

    4. SUPPRESSION DES MOTS DÉJÀ PRÉSENTS DANS LE GPS
        - Si GPS = "Paris_France", alors :
              paris, france
          sont supprimés des tags et du nom original
        - Le GPS est prioritaire dans Style 3

    5. SUPPRESSION DES DOUBLONS GLOBAUX
        - Tous les mots sont assemblés dans l’ordre Style 3 :
              timestamp → GPS → tags → nom original → caméra → source
        - On garde le premier mot rencontré
        - Toute répétition ultérieure est supprimée
        - Exemple :
              vacances famille famille parc famille
          devient :
              vacances famille parc

    6. RECONSTRUCTION STYLE 3
        - Ordre final :
              1. timestamp (obligatoire)
              2. GPS (si disponible)
              3. tags de chemin
              4. nom original filtré
              5. appareil photo
              6. source (WhatsApp, etc.)
        - Les mots sont joints par "_"
        - Aucun "_" en début ou fin

    7. LIMITE DE LONGUEUR
        - Longueur maximale = Config.MaxNameLen
        - On réserve l’espace pour :
              • le marqueur (--odr--)
              • l’extension (.jpg, .mp4, etc.)
        - Si trop long :
              • on coupe proprement
              • sans casser un mot
              • sans laisser "_" final

    8. MARQUEUR DE TRAITEMENT
        - Le nom final se termine toujours par :
              --odr--
          avant l’extension
        - Permet d’identifier les fichiers déjà traités

    ---------------------------------------------------------------------
    EXEMPLE RÉEL
    ---------------------------------------------------------------------

        Nom original : IMG_20230814_142233.jpg
        PathTags     : Vacances_famille_parc national
        GPS          : Paris-France

        Résultat :
            20230814_142233_Paris_France_Vacances_famille_parc_national--odr--.jpg


    ---------------------------------------------------------------------
#>
function New-SmartFileName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [DateTime]$DateRef,
        [Parameter(Mandatory)] [string]  $OriginalName,
        [Parameter(Mandatory)] [string]  $Extension,
        [string]$GpsLocation,
        [string]$PathTags,
        [string]$Camera,
        [string]$SourceHint
    )

    $timestamp = $DateRef.ToString("yyyyMMdd_HHmmss")

    # --- Normalisation ASCII ---
    $cleanOriginal = Convert-ToAscii $OriginalName
    $cleanTags = Convert-ToAscii $PathTags
    $cleanGps = Convert-ToAscii $GpsLocation
    $cleanCam = Convert-ToAscii $Camera
    $cleanSource = Convert-ToAscii $SourceHint

    # --- Découpage en mots ---
    function Split-Words($txt) {
        if (-not $txt) { return @() }
        return ($txt -split "[ _\-]" | Where-Object { $_ -and $_.Trim().Length -gt 0 })
    }

    $gpsWords = Split-Words $cleanGps
    $tagWords = Split-Words $cleanTags
    $origWords = Split-Words $cleanOriginal
    $camWords = Split-Words $cleanCam
    $srcWords = Split-Words $cleanSource

    # --- Liste des mots vides ---
    $stopWords = @("de", "du", "des", "la", "le", "les", "avec", "pour", "sur", "dans", "et", "en", "a", "au", "aux")

    # --- Filtre stopwords (version robuste) ---
    function Remove-StopWords($list) {
        if (-not $list) { return @() }
        return $list | Where-Object { $stopWords -notcontains $_.ToLower() }
    }

    $gpsWords = Remove-StopWords $gpsWords
    $tagWords = Remove-StopWords $tagWords
    $origWords = Remove-StopWords $origWords

    # --- Suppression des mots déjà présents dans GPS ---
    $gpsSet = @{}
    foreach ($w in $gpsWords) { $gpsSet[$w.ToLower()] = $true }

    function Remove-GpsRedundancy($list) {
        if (-not $list) { return @() }
        return $list | Where-Object { -not $gpsSet.ContainsKey($_.ToLower()) }
    }

    $tagWords = Remove-GpsRedundancy $tagWords
    $origWords = Remove-GpsRedundancy $origWords

    # --- Assemblage global ---
    $allWords = New-Object System.Collections.Generic.List[string]
    $allWords.Add($timestamp)
    $gpsWords    | ForEach-Object { $allWords.Add($_) }
    $tagWords    | ForEach-Object { $allWords.Add($_) }
    $origWords   | ForEach-Object { $allWords.Add($_) }
    $camWords    | ForEach-Object { $allWords.Add($_) }
    $srcWords    | ForEach-Object { $allWords.Add($_) }

    # --- Anti-doublon global ---
    $seen = @{}
    $filtered = foreach ($w in $allWords) {
        $key = $w.ToLower()
        if (-not $seen.ContainsKey($key)) {
            $seen[$key] = $true
            $w
        }
    }

    # Reconstruction
    $baseName = ($filtered -join "_").Trim("_")

    # Limite de longueur
    $maxLenWithoutExt = $Config.MaxNameLen - $Config.RenameMarker.Length - $Extension.Length
    if ($baseName.Length -gt $maxLenWithoutExt) {
        $baseName = $baseName.Substring(0, $maxLenWithoutExt).Trim("_")
    }

    return ($baseName + $Config.RenameMarker + $Extension)
} # New-SmartFileName

# =====================================================================
# 5. AUTHENTIFICATION
# =====================================================================

function Connect-AzureGraph {
    Write-Log "Obtention du token Graph via module..."
    $auth = Get-GraphToken

    if (-not $auth.access_token) {
        Write-Log "Échec token Graph" "ERROR"
        throw "Impossible d'obtenir un token Graph."
    }

    $Global:State.Headers = @{
        Authorization  = "Bearer $($auth.access_token)"
        "Content-Type" = "application/json"
    }

    Write-Log "Token Graph chargé." "SUCCESS"
}

# =====================================================================
# 6. PRÉ-CRÉATION DES DOSSIERS
# =====================================================================

function Test-OneDrivePath {
    [CmdletBinding()]
    param([string]$RelativePath)

    $RelativePath = $RelativePath.Trim('/')
    $pathParts = $RelativePath -split '/'
    $currentPath = ""

    foreach ($part in $pathParts) {

        $parentPath = $currentPath
        $currentPath += if ($currentPath -eq "") { $part } else { "/$part" }

        $encodedSegments = ($currentPath -split '/' | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/'

        # Vérification de l’existence du dossier
        try {
            Invoke-RestMethod -Headers $Global:State.Headers `
                -Uri "https://graph.microsoft.com/v1.0/me/drive/root:/${encodedSegments}:" `
                -Method Get -ErrorAction Stop > $null
        }
        catch {
            Write-Log "Création du dossier : /$currentPath" "DEBUG"

            $encodedParent = ($parentPath -split '/' | Where-Object { $_ } | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/'

            $uriPost = if ($parentPath -eq "") {
                "https://graph.microsoft.com/v1.0/me/drive/root/children"
            }
            else {
                "https://graph.microsoft.com/v1.0/me/drive/root:/${encodedParent}:/children"
            }

            $body = @{ name = $part; folder = @{}; "@microsoft.graph.conflictBehavior" = "ignore" } | ConvertTo-Json

            Invoke-RestMethod -Headers $Global:State.Headers `
                -Uri $uriPost -Method POST -Body $body -ErrorAction Stop > $null
        }
    }
}

# =====================================================================
# 7. CHARGEMENT DU CACHE
# =====================================================================

function Import-Set-Cache {
    [CmdletBinding()]
    param()

    Write-Log "Nettoyage du vieux log d'exécution $LogFile si present "
    if (Test-Path $LogFile) {
        Remove-Item $LogFile -Force
    }

    Write-Log "Chargement du cache OneDrive $IndexFile ... "
    if (!(Test-Path $IndexFile)) {
        Write-Log "Cache introuvable : $IndexFile" "ERROR"
        exit 1
    }
    $Global:State.Cache = Get-Content $IndexFile -Raw | ConvertFrom-Json -AsHashtable

    if (-not $Global:State.Cache.Files) {
        Write-Log "Aucun fichier dans le cache (section Files vide)." "ERROR"
        exit 1
    }

    # 3. Chargement des IDs déjà traités
    Write-Log "Chargement de la liste des ids/fichiers déjà traités ($ProcessedLog) ... "
    $Global:State.ProcessedIds = @{}
    $Global:State.FilesToProcess = @{}

    if (Test-Path $ProcessedLog) {
        Get-Content $ProcessedLog | ForEach-Object {
            $id = $_.Trim()
            if ($id) {
                $Global:State.ProcessedIds[$id] = $true
            }
        }
        Write-Log "Fichiers déjà traités chargés : $($Global:State.ProcessedIds.Count)"
    }
    else {
        Write-Log "Aucun fichier traité précédemment (fichier $ProcessedLog absent)."
    }

    Write-Log "Découverte des fichiers déjà traités ayant le marqueur '$($Config.RenameMarker)' ..."
    $index = 0
    $total = $Global:State.Cache.Files.Count
    foreach ($id in $Global:State.Cache.Files.Keys) {

        $index++
        Write-Progress -Activity "Analyse des fichiers" `
            -Status "$index / $total" `
            -PercentComplete (($index / $total) * 100)

        $fileMeta = $Global:State.Cache.Files[$id]

        # a) Si déjà dans ProcessedIds → ignorer
        if ($Global:State.ProcessedIds.ContainsKey($id)) {
            Write-Log "Ignoré (déjà traité) : $id" "DEBUG"
            continue
        }

        # b) Si le nom contient le marqueur → l'ajouter à ProcessedIds
        if ($fileMeta.n -like "*$($Config.RenameMarker)*") {
            Write-Log "Ajouté à ProcessedIds (déjà renommé) : $($fileMeta.p)/$($fileMeta.n)" "DEBUG"
            $Global:State.ProcessedIds[$id] = $true
            continue
        }

        # c) Sinon → fichier à traiter
        $Global:State.FilesToProcess[$id] = $fileMeta
    }

    Write-Progress -Activity "Analyse terminée" -Completed
    Write-Log "Indexation terminée. Fichiers à traiter : $($Global:State.FilesToProcess.Count)"

    "Timestamp,ID,Status,OldPath,NewPath,Error" | Set-Content $ExecutionReport
} # Import-Set-Cache

# =====================================================================
# 8. PLANIFICATION
# =====================================================================


function New-Plan {
    [CmdletBinding()]
    param()

    Write-Log "Analyse des fichiers..."
    Write-Log "Début de New-Plan" "DEBUG"

    
    foreach ($fileId in $Global:State.FilesToProcess.Keys) {

        $fileMeta = $Global:State.Cache.Files[$fileId]
        $extension = [System.IO.Path]::GetExtension($fileMeta.n).ToLower()

        #Write-Log "----------------------------------------------" "DEBUG"
        Write-Log "Analyse du fichier" "DEBUG"
        Write-Log "ID             : $fileId" "DEBUG"
        Write-Log "Nom original   : $($fileMeta.n)" "DEBUG"
        Write-Log "Chemin source  : $($fileMeta.p)" "DEBUG"
        Write-Log "Extension      : $extension" "DEBUG"
        Write-Log "Date fichier   : $($fileMeta.d)" "DEBUG"

        # 1. Classification intelligente
        $category = Get-SmartCategory -Path $fileMeta.p -Extension $extension
        Write-Log "Classification intelligente = ($category)" "DEBUG"

        # On prépare les données de base
        if (-not $Config.ExtensionMap.ContainsKey($extension)) {
            Write-Log "Ignoré : extension non supportée ($extension)" "DEBUG"
            continue
        }

        $fileDate = [DateTime]$fileMeta.d

        # GPS → ville/province/pays (si dispo dans le cache OneDrive)
        $gpsLocation = $null
        if ($fileMeta.gps) {
            $gpsLocation = Get-LocationName $fileMeta.gps
            Write-Log "Localisation GPS : $gpsLocation" "DEBUG"
        }

        # Tags de chemin (hiérarchie utile)
        $pathTags = Get-PathTags $fileMeta.p
        Write-Log "Tags de chemin : $pathTags" "DEBUG"

        # Appareil / source (si dispo dans le cache)
        $camera = $null
        if ($fileMeta.cam) { $camera = $fileMeta.cam }

        # Hint de source (WhatsApp, etc.) basé sur le chemin
        $sourceHint = ""
        if ($fileMeta.p -match "WhatsApp") { $sourceHint = "WhatsApp" }
        elseif ($fileMeta.p -match "Messenger") { $sourceHint = "Messenger" }
        elseif ($fileMeta.p -match "Instagram") { $sourceHint = "Instagram" }

        $originalNameNoExt = [System.IO.Path]::GetFileNameWithoutExtension($fileMeta.n)

        $newName = New-SmartFileName `
            -DateRef      $fileDate `
            -OriginalName $originalNameNoExt `
            -Extension    $extension `
            -GpsLocation  $gpsLocation `
            -PathTags     $pathTags `
            -Camera       $camera `
            -SourceHint   $sourceHint

        Write-Log "Nouveau nom généré : $newName" "DEBUG"

        # # Règle de destination
        # $rule = Get-TargetRoot $fileMeta.p

        # Write-Log "Règle appliquée   : $($rule.Rule)" "DEBUG"
        # Write-Log "Action           : $($rule.Action)" "DEBUG"
        # Write-Log "Racine cible     : $($rule.TargetRoot)" "DEBUG"

        # $root = $rule.TargetRoot

        # $rawDestination = if ($root -like "Pour coffre fort*") {
        #     "$root/$($Config.ExtensionMap[$extension])/$($fileDate.Year)/$($fileDate.ToString('MM'))"
        # } else {
        #     "$root/$($fileDate.Year)/$($fileDate.ToString('MM'))"
        # }

        # $cleanDestination = Convert-ToAscii $rawDestination -IsPath $true
        # $fullDestination  = "/$cleanDestination/$newName"

        # Write-Log "Destination finale : $fullDestination" "DEBUG"

        # $Global:State.PlannedActions.Add([PSCustomObject]@{
        #     Id        = $fileId
        #     SrcPath   = $fileMeta.p
        #     SrcName   = $fileMeta.n
        #     DstDir    = $cleanDestination
        #     DstName   = $newName
        #     FullDst   = $fullDestination
        # })

        # 3. Calcul de la destination (Le cœur de l'adaptation)
        $srcDirClean = $fileMeta.p -replace "^/drive/root:", ""
        $mediaType = if ($Config.ExtensionMap.ContainsKey($extension)) { $Config.ExtensionMap[$extension] } else { "Autres" }

        if ($category -eq "Stay") {
            # Règle STAY : On garde le dossier actuel, on change juste le nom
            $rawDestination = $srcDirClean
        } 
        elseif ($category -match "Coffre-fort/(.+)") {
            # Règle COFFRE-FORT : /Pour coffre fort/Racine/Type/Année/Mois
            $vaultRoot = $Matches[1]
            $rawDestination = "/Pour coffre fort/$vaultRoot/$mediaType/$($fileDate.Year)/$($fileDate.ToString('MM'))"
        } 
        else {
            # Règle STANDARD : /Images/Pellicule/Année/Mois
            $rawDestination = "/$category/Pellicule/$($fileDate.Year)/$($fileDate.ToString('MM'))"
        }

        $cleanDestination = Convert-ToAscii $rawDestination -IsPath $true
        Write-Log "Chemin destination = ($cleanDestination)" "DEBUG"

        $fullDestination = "/$($cleanDestination.Trim('/'))/$newName"

        # 4. Vérification si un changement est nécessaire (évite les actions inutiles)
        $currentPath = "$($srcDirClean.Trim('/'))/$($fileMeta.n)"
        if ($currentPath -eq $fullDestination.Trim('/')) {
            Write-Log "Déjà à la bonne place : $($fileMeta.n)" "DEBUG"
            continue
        }

        # 5. Ajout à la liste des actions
        $Global:State.PlannedActions.Add([PSCustomObject]@{
                Id      = $fileId
                SrcPath = $fileMeta.p
                SrcName = $fileMeta.n
                DstDir  = "/$($cleanDestination.Trim('/'))"
                DstName = $newName
                FullDst = $fullDestination
            })


        #Write-Log "Fin analyse fichier : ($newName)" "DEBUG"
        Write-Log "----------------------------------------------" "DEBUG"
    }

    Write-Log "Plan généré : $($Global:State.PlannedActions.Count) fichiers." "SUCCESS"
    Write-Log "Fin de New-Plan" "DEBUG"
}
function traitement {
    $Log = New-Object System.Collections.Generic.List[string]
    $Log.Add("=== RAPPORT V14.5 - $(Get-Date) ===")

    Write-Host "`n--- DÉMARRAGE DE L'ANALYSE ($TotalFiles fichiers) ---" -ForegroundColor Cyan

    $count = 0
    foreach ($id in $FileIds) {
        $count++
        $fileMeta = $Cache.Files[$id]
        
        # Progression
        $elapsed = (Get-Date) - $StartTime
        $avgTime = $elapsed.TotalSeconds / $count
        $remainingStr = "{0:hh\:mm\:ss}" -f [TimeSpan]::FromSeconds($avgTime * ($TotalFiles - $count))

        if ($count % 10 -eq 0) {
            Write-Progress -Activity "Analyse $([Math]::Round(($count/$TotalFiles)*100,1))%" `
                -Status "Fichiers: $count/$TotalFiles | Restant: $remainingStr" `
                -PercentComplete (($count / $TotalFiles) * 100)
        }

        if (!$fileMeta.d) { continue }
        $ext = [System.IO.Path]::GetExtension($fileMeta.n).ToLower()
        $dateRef = [DateTime]$fileMeta.d
        
        $villeStr = Get-LocationName $fileMeta.gps
        $tags = Get-PathTags $fileMeta.p
        $name = ([System.IO.Path]::GetFileNameWithoutExtension($fileMeta.n) -replace "\(Copie.*\)|- Copie|\(1\)", "").Trim()
        
        $newName = ""
        $targetDir = ""

        # NOMENCLATURE PHOTOS / VIDÉOS
        if ($ext -match ".jpg|.jpeg|.png|.heic|.mp4|.mov") {
            $parts = New-Object System.Collections.Generic.List[string]
            $parts.Add($dateRef.ToString("yyyyMMdd_HHmmss"))
            if ($villeStr) { $parts.Add($villeStr) }
            if ($tags) { $parts.Add($tags) }
            
            if ($ext -match ".mp4|.mov") {
                if ($fileMeta.dur) { $parts.Add($fileMeta.dur) }; if ($fileMeta.res) { $parts.Add($fileMeta.res) }
                $targetDir = "/Vidéos/Pellicule/$($dateRef.Year)/$($dateRef.ToString('MM'))"
            }
            else {
                if ($name -and $tags -notlike "*$name*" -and $name -notmatch "^\d+$") { $parts.Add($name) }
                if ($fileMeta.cam) { $parts.Add($fileMeta.cam) }
                $targetDir = "/Images/Pellicule/$($dateRef.Year)/$($dateRef.ToString('MM'))"
            }
            $newName = ($parts -join "_") + $ext
        }
        # NOMENCLATURE AUDIO
        elseif ($ext -match ".mp3|.m4a|.flac") {
            $artiste = if ($fileMeta.art) { $fileMeta.art }else { "Inconnu" }
            $album = if ($fileMeta.alb) { $fileMeta.alb }else { "Inconnu" }
            $newName = "$artiste - $album - $name$ext"
            $targetDir = "/Musique/$artiste/$album"
        }

        if ($newName) {
            $newName = ($newName -replace '[\\\/:*?"<>|]', '-') -replace '_+', '_'
            $Log.Add("SRC : $($fileMeta.p)/$($fileMeta.n)")
            $Log.Add("DST : $targetDir/$newName")
        }
    }

    $Log | Set-Content $LogFile
    Write-Host "`nTERMINÉ. Log généré : $LogFile" -ForegroundColor Green

}

# =====================================================================
# 9. EXÉCUTION
# =====================================================================

function Invoke-Moves {
    [CmdletBinding()]
    param()

    Write-Log "Début du déplacement..." "WARN"

    $total = $Global:State.PlannedActions.Count
    $index = 0

    foreach ($action in $Global:State.PlannedActions) {

        $index++
        Write-Progress -Activity "Déplacement OneDrive" `
            -Status "Fichier $index / $total" `
            -PercentComplete (($index / $total) * 100)

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



# =====================================================================
# 10. MAIN
# =====================================================================

function Start-OneDriveOrganizer {
    [CmdletBinding()]
    param()

    Clear-Host
    Write-Log "Démarrage de l'organisateur..."

    Import-Set-Cache

    #traitement

    New-Plan

    if ($Global:State.PlannedActions.Count -eq 0) {
        Write-Log "Aucun fichier à traiter." "WARN"
        return
    }

    # le temps qu'on stabilise le code
    exit

    if (-not $Execute) {
        Write-Log "MODE APERÇU  Utilisez -Execute `$true pour appliquer les changements." "WARN"
        $Global:State.PlannedActions[0] | Format-List
        return
    }

    Connect-AzureGraph

    # Pré-création des dossiers
    $uniqueDirs = $Global:State.PlannedActions.DstDir | Select-Object -Unique | Sort-Object
    foreach ($dir in $uniqueDirs) { Test-OneDrivePath $dir }

    Invoke-Moves
} # Start-OneDriveOrganizer

Start-OneDriveOrganizer