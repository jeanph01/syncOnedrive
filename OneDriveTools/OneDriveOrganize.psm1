param(
    [string]$ClientId,
    [string]$TokenFile,
    [string]$LogFile
)

# Empêche le module d'être réimporté avec de mauvais paramètres
if ($script:ModuleLoaded) {
    return
}
$script:ModuleLoaded = $true

if (-not (Get-Command Get-GraphToken -ErrorAction SilentlyContinue)) {
    throw "ERREUR: Les fonctions de OneDriveTools ne sont pas disponibles. Vérifie l'import dans le script principal."
}


function Read-AzureFileInfo {
    param($item)

    if (-not ($item.file -and $item.file.hashes.sha1Hash)) {
        return $null
    }

    # GPS
    $gps = $null
    if ($item.photo -and $item.photo.gps) {
        $gps = "$($item.photo.gps.latitude),$($item.photo.gps.longitude)"
    }
    elseif ($item.location -and $item.location.latitude) {
        $gps = "$($item.location.latitude),$($item.location.longitude)"
    }

    # Caméra
    $camera = $null
    if ($item.photo) {
        $camera = "$($item.photo.cameraMake) $($item.photo.cameraModel)".Trim()
    }

    # Image
    $imgInfo = $null
    if ($item.image) {
        $imgInfo = @{
            width  = $item.image.width
            height = $item.image.height
        }
    }

    # Vidéo
    $videoInfo = $null
    if ($item.video) {
        $videoInfo = @{
            duration = $item.video.duration
            width    = $item.video.width
            height   = $item.video.height
        }
    }

    # Audio
    $audioInfo = $null
    if ($item.audio) {
        $audioInfo = @{
            title  = $item.audio.title
            album  = $item.audio.album
            artist = $item.audio.artist
        }
    }

    # Date EXIF ou fallback
    $refDate = $null
    if ($item.photo -and $item.photo.takenDateTime) {
        $refDate = [DateTime]$item.photo.takenDateTime
    }
    if (-not $refDate) {
        $refDate = [DateTime]$item.fileSystemInfo.lastModifiedDateTime
    }

    return @{
        n   = $item.name
        s   = $item.size
        h   = $item.file.hashes.sha1Hash.ToLower()
        d   = $refDate
        p   = $item.parentReference.path
        gps = $gps
        cam = $camera
        img = $imgInfo
        vid = $videoInfo
        aud = $audioInfo
    }
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


function Get-DestinationPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Category,

        [Parameter(Mandatory)]
        [hashtable]$FileMeta,

        [Parameter(Mandatory)]
        [string]$Extension,

        [Parameter(Mandatory)]
        [hashtable]$ExtensionMap,

        [Parameter(Mandatory)]
        [string]$NewName,

        [Parameter(Mandatory)]
        [datetime]$FileDate
    )

    # Nettoyage du chemin source
    $srcDirClean = $FileMeta.p -replace "^/drive/root:", ""

    # Type média
    $mediaType = if ($ExtensionMap.ContainsKey($Extension)) {
        $ExtensionMap[$Extension]
    } else {
        "Autres"
    }

    # Règles de destination
    if ($Category -eq "Stay") {
        # On garde le dossier actuel
        $rawDestination = $srcDirClean
    }
    elseif ($Category -match "Coffre-fort/(.+)") {
        # Coffre-fort : /Pour coffre fort/Racine/Type/Année/Mois
        $vaultRoot = $Matches[1]
        $rawDestination = "/Pour coffre fort/$vaultRoot/$mediaType/$($FileDate.Year)/$($FileDate.ToString('MM'))"
    }
    else {
        # Standard : /Images/Pellicule/Année/Mois
        $rawDestination = "/$Category/Pellicule/$($FileDate.Year)/$($FileDate.ToString('MM'))"
    }

    # Nettoyage ASCII
    $cleanDestination = Convert-ToAscii $rawDestination -IsPath $true

    # Destination finale
    $fullDestination = "/$($cleanDestination.Trim('/'))/$NewName"

    return [PSCustomObject]@{
        RawDestination   = $rawDestination
        CleanDestination = $cleanDestination
        FullDestination  = $fullDestination
    }
}


Export-ModuleMember -Function * -Alias *