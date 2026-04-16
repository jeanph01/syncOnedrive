param(
    [string]$ClientId,
    [string]$TokenFile,
    [string]$LogFile
)

# Empêche les imports multiples
if ($script:ModuleLoaded) {
    return
}
$script:ModuleLoaded = $true

# Vérifie la dépendance OneDriveTools
if (-not (Get-Command Get-GraphToken -ErrorAction SilentlyContinue)) {
    throw "ERREUR: Les fonctions de OneDriveTools ne sont pas disponibles. Vérifie l'import dans le script principal."
}

# Lit les métadonnées d’un item Azure (EXIF, GPS, caméra, vidéo, audio)
function Read-AzureFileInfo {
    param($item)

    try {
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
    catch {
        Write-Log "Échec Read-AzureFileInfo: $_" "Erreur"
    }
} # Read-AzureFileInfo


# Détermine la catégorie logique d’un fichier selon son chemin et son extension
function Get-SmartCategory {
    param ([string]$Path, [string]$Extension)

    try {
        # Règles STAY (catégorie logique, pas le routing final)
        $stayPatterns = @($Global:Rules.categoryRules.stayPatterns)
        foreach ($p in $stayPatterns) {
            if ($Path -match "(?i)$p") {
                return "Stay"
            }
        }

        # Confidential (catégorie logique)
        if ($Path -match $Global:Rules.categoryRules.confidentialRegex) {
            return "Confidential"
        }

        # Standards
        $ext = $Extension.ToLower()
        if ($Config.ExtensionMap.ContainsKey($ext)) {
            return $Config.ExtensionMap[$ext]
        }

        return "Stay"
    }
    catch {
        Write-Log "Échec Get-SmartCategory: $_" "Erreur"
    }
} # Get-SmartCategory


# Extrait les tags utiles du chemin source
function Get-PathTags($fullPath) {
    try {
        $parts = $fullPath -replace "^/drive/root:/?", "" -split "/" |
        Where-Object { $_ -and $_ -notmatch "Documents|Images|Vidéos|Musique|Pellicule|JPM" }

        return ($parts -join "_")
    }
    catch {
        Write-Log "Échec Get-PathTags: $_" "Erreur"
    }
} # Get-PathTags


# Génère un nom de fichier structuré, propre, déterministe (Style 3)
function New-SmartFileName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][DateTime]$DateRef,
        [Parameter(Mandatory)][string]$OriginalName,
        [Parameter(Mandatory)][string]$Extension,
        [string]$GpsLocation,
        [string]$PathTags,
        [string]$Camera,
        [string]$SourceHint
    )

    try {
        # FIX : Si le nom original est vide ou n'est qu'une extension, on utilise "unnamed"
        $cleanOriginal = if ([string]::IsNullOrWhiteSpace($OriginalName) -or $OriginalName -eq $Extension) { 
            "unnamed" 
        } else { 
            Convert-ToAscii $OriginalName 
        }
        $timestamp = $DateRef.ToString("yyyyMMdd_HHmmss")
        $year      = $DateRef.ToString("yyyy")
        $yearMonth = $DateRef.ToString("yyyy_MM")
        $dateRaw   = $DateRef.ToString("yyyyMMdd")

        # Normalisation ASCII
        $cleanOriginal = Convert-ToAscii $OriginalName
        $cleanTags     = Convert-ToAscii $PathTags
        $cleanGps      = Convert-ToAscii $GpsLocation
        $cleanCam      = Convert-ToAscii $Camera
        $cleanSource   = Convert-ToAscii $SourceHint

        # Découpage
        function Split-Words($txt) {
            if (-not $txt) { return @() }
            return ($txt -split "[ _\-]" | Where-Object { $_ -and $_.Trim().Length -gt 0 })
        }

        $gpsWords  = Split-Words $cleanGps
        $tagWords  = Split-Words $cleanTags
        $origWords = Split-Words $cleanOriginal
        $camWords  = Split-Words $cleanCam
        $srcWords  = Split-Words $cleanSource

        # Stopwords
        $stopWords = @($Global:Rules.namingRules.stopWords)

        function Remove-StopWords($list) {
            if (-not $list) { return @() }
            return $list | Where-Object { $stopWords -notcontains $_.ToLower() }
        }

        $gpsWords  = Remove-StopWords $gpsWords
        $tagWords  = Remove-StopWords $tagWords
        $origWords = Remove-StopWords $origWords

        # Suppression des mots déjà présents dans GPS
        $gpsSet = @{}
        foreach ($w in $gpsWords) { $gpsSet[$w.ToLower()] = $true }

        function Remove-GpsRedundancy($list) {
            if (-not $list) { return @() }
            return $list | Where-Object { -not $gpsSet.ContainsKey($_.ToLower()) }
        }

        $tagWords  = Remove-GpsRedundancy $tagWords
        $origWords = Remove-GpsRedundancy $origWords

        # Suppression des redondances de date
        function Remove-DateRedundancy($list) {
            if (-not $list) { return @() }
            return $list | Where-Object {
                $_ -notmatch $year      -and
                $_ -notmatch $yearMonth -and
                $_ -notmatch $dateRaw   -and
                $_ -notmatch $timestamp
            }
        }
        $tagWords  = Remove-DateRedundancy $tagWords
        $origWords = Remove-DateRedundancy $origWords

        # Assemblage global
        $allWords = New-Object System.Collections.Generic.List[string]
        $allWords.Add($timestamp)
        $gpsWords  | ForEach-Object { $allWords.Add($_) }
        $tagWords  | ForEach-Object { $allWords.Add($_) }
        $origWords | ForEach-Object { $allWords.Add($_) }
        $camWords  | ForEach-Object { $allWords.Add($_) }
        $srcWords  | ForEach-Object { $allWords.Add($_) }

        # Anti-doublon global
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
    }
    catch {
        Write-Log "Échec New-SmartFileName: $_" "Erreur"
    }
} # New-SmartFileName


function Resolve-FileRouting {
    <#
    .SYNOPSIS
        Résout la stratégie de routing (Stay / Move) et la racine cible selon le chemin source et le type de média.

    .DESCRIPTION
        Cette fonction applique un moteur de règles déterministe, dans un ordre de priorité strict :

        RÈGLE 1 — FINANCES (Stay STRICT)
            Condition :
                - Le chemin source commence par /drive/root:/Finances
            Intention :
                - Stay strict : aucun déplacement, on garde le chemin exact, on renomme seulement.
            Exemple :
                /drive/root:/Finances/Maison et Logement/95 ... → /Finances/Maison_et_Logement/95_.../<NewName>

        RÈGLE 2 — COFFRE-FORT (Stay + mediaType) — SANS EXCEPTION
            Condition :
                - Le chemin source contient (insensible à la casse) :
                    "confidential", "confidential", "pour confidential", "confidential", "privatevault"
            Intention :
                - Stay dans la racine Confidential
                - Conserver le 2e niveau (Michelle, relations, archives, etc.)
                - Organiser par type média (images / videos)
                - Classer par année / mois
            Destination :
                /<racine_confidential>/<sous_dossier>/<images|videos>/<YYYY>/<MM>/<NewName>
            Exemple :
                /drive/root:/Confidential/relations/... → /Confidential/relations/videos/YYYY/MM/<NewName>
                /drive/root:/VersConfidentialVault/relations/... → /VersConfidentialVault/relations/images/YYYY/MM/<NewName>
                /drive/root:/VersConfidentialVault/archives/... → /VersConfidentialVault/archives/videos/YYYY/MM/<NewName>

        RÈGLE 3 — APPS (WhatsApp, Messenger, DCIM, etc.)
            Condition :
                - Le chemin contient : WhatsApp, Messenger, Facebook, Instagram, Camera Roll, DCIM, Android, iOS
            Intention :
                - Utiliser la même logique que la règle par défaut (Move Pellicule / Videos)
            Destination :
                /Images/Pellicule/YYYY/MM/<NewName> ou /Videos/YYYY/MM/<NewName>

        RÈGLE 4 — ADMINISTRATIF NON FINANCES (Stay simplifié)
            Condition :
                - Le chemin contient : Documents, Légal, Syndicat, Vie des enfants, Cuisine, Livres, JPM, etc.
            Intention :
                - Stay simplifié : on garde la racine, mais on limite à 3 niveaux maximum.
            Exemple :
                /Documents/Travail/ProjetA/Phase1/Notes → /Documents/Travail/ProjetA/<NewName>

        RÈGLE 5 — DEFAULT (Move Pellicule / Videos)
            Condition :
                - Aucune des règles précédentes ne s’applique.
            Intention :
                - Move selon type média.
            Destination :
                /Images/Pellicule/YYYY/MM/<NewName> ou /Videos/YYYY/MM/<NewName>

    .OUTPUTS
        Hashtable avec :
            Mode  = "StayStrict" | "ConfidentialVault" | "AppsOrDefaultMove" | "StaySimplified"
            Root  = racine logique (pour ConfidentialVault) ou $null pour les autres
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$FileMeta,
        [Parameter(Mandatory)][string]$Extension
    )

    try {
        $srcDirClean = $FileMeta.p -replace "^/drive/root:", ""
        #$ext = $Extension.ToLower()

        # RÈGLE 1 — FINANCES (Stay STRICT)
        if ($srcDirClean -match $Global:Rules.routingRules.financeRegex) {
            return @{
                Mode = "StayStrict"
                Root = $srcDirClean
            }
        }

        # RÈGLE 2 — COFFRE-FORT (Stay + mediaType) — SANS EXCEPTION
        $confidentialRegexList = @($Global:Rules.routingRules.confidentialRegexList)
        $isConfidential = $false
        foreach ($regex in $confidentialRegexList) {
            if ($srcDirClean -match $regex) {
                $isConfidential = $true
                break
            }
        }
        if ($isConfidential) {
            $parts = $srcDirClean.Trim('/').Split('/')
            $idx = -1
            for ($i = 0; $i -lt $parts.Count; $i++) {
                foreach ($regex in $confidentialRegexList) {
                    if ($parts[$i] -match $regex) {
                        $idx = $i
                        break
                    }
                }
                if ($idx -ge 0) { break }
            }
            if ($idx -lt 0) { $idx = 0 }

            $rootParts = @()
            $rootParts += $parts[$idx]
            if ($parts.Count -gt ($idx + 1)) {
                $rootParts += $parts[$idx + 1]
            }
            $baseRoot = "/" + ($rootParts -join "/")

            return @{
                Mode = "ConfidentialVault"
                Root = $baseRoot
            }
        }

        # RÈGLE 3 — APPS (WhatsApp, Messenger, DCIM, etc.) → même logique que Default
        $appsPatterns = @($Global:Rules.routingRules.appsPatterns)
        foreach ($p in $appsPatterns) {
            if ($srcDirClean -match [Regex]::Escape($p)) {
                return @{
                    Mode = "AppsOrDefaultMove"
                    Root = $null
                }
            }
        }

        # RÈGLE 4 — ADMINISTRATIF NON FINANCES (Stay simplifié)
        $adminPatterns = @($Global:Rules.routingRules.adminPatterns)
        foreach ($p in $adminPatterns) {
            if ($srcDirClean -match "(?i)$p") {
                return @{
                    Mode = "StaySimplified"
                    Root = $srcDirClean
                }
            }
        }

        # RÈGLE 5 — DEFAULT (Move Pellicule / Videos)
        return @{
            Mode = "AppsOrDefaultMove"
            Root = $null
        }
    }
    catch {
        Write-Log "Échec Resolve-FileRouting: $_" "Erreur"
    }
} # Resolve-FileRouting


function Get-DestinationPath {
    <#
    .SYNOPSIS
        Détermine le chemin de destination final d’un fichier (dossier cible + nouveau nom).

    .DESCRIPTION
        Cette fonction applique les règles de routing suivantes, via Resolve-FileRouting :

        PRIORITÉ 1 — FINANCES (Stay STRICT)
            - Condition :
                Le chemin source commence par /drive/root:/Finances
            - Comportement :
                Aucun déplacement, on garde le chemin exact (nettoyé ASCII), on renomme seulement.
            - Exemple :
                /drive/root:/Finances/Maison ... → /Finances/Maison_.../<NewName>

        PRIORITÉ 2 — COFFRE-FORT (Stay + mediaType) — SANS EXCEPTION
            - Condition :
                Le chemin source contient "confidential", "confidential", "pour confidential", "confidential", "privatevault"
            - Comportement :
                On reste dans la racine Confidential, on conserve le 2e niveau (Michelle, relations, archives, etc.),
                on crée un sous-dossier images/ ou videos/ selon le type média, puis on classe par année / mois.
            - Destination :
                /<racine_confidential>/<sous_dossier>/<images|videos>/<YYYY>/<MM>/<NewName>

        PRIORITÉ 3 — APPS (WhatsApp, Messenger, DCIM, etc.)
            - Condition :
                Le chemin contient : WhatsApp, Messenger, Facebook, Instagram, Camera Roll, DCIM, Android, iOS
            - Comportement :
                Utilise la même logique que la règle par défaut (Move Pellicule / Videos).

        PRIORITÉ 4 — ADMINISTRATIF NON FINANCES (Stay simplifié)
            - Condition :
                Le chemin contient : Documents, Légal, Syndicat, Vie des enfants, Cuisine, Livres, JPM, etc.
            - Comportement :
                Stay simplifié : on garde la racine, mais on limite à 3 niveaux maximum.
            - Exemple :
                /Documents/Travail/ProjetA/Phase1/Notes → /Documents/Travail/ProjetA/<NewName>

        PRIORITÉ 5 — DEFAULT (Move Pellicule / Videos)
            - Condition :
                Aucune des règles précédentes ne s’applique.
            - Comportement :
                Move selon type média :
                    - Images → /Images/Pellicule/YYYY/MM/<NewName>
                    - Videos → /Videos/YYYY/MM/<NewName>
                    - Autres → /Images/Pellicule/YYYY/MM/<NewName> (par défaut)

    .PARAMETER Category
        Catégorie logique (Images, Videos, Stay, Confidential, etc.). Utilisée pour certains cas historiques,
        mais la logique principale repose sur Resolve-FileRouting et le type média.

    .PARAMETER FileMeta
        Hashtable retournée par Read-AzureFileInfo, contenant notamment :
            - p : chemin parent (/drive/root:/...).

    .PARAMETER Extension
        Extension du fichier, incluant le point (.jpg, .mp4, etc.).

    .PARAMETER ExtensionMap
        Hashtable de mapping extension → type média (Images, Videos, Autres, etc.).

    .PARAMETER NewName
        Nouveau nom de fichier généré par New-SmartFileName.

    .PARAMETER FileDate
        Date de référence (EXIF ou fallback) utilisée pour YYYY/MM.

    .OUTPUTS
        PSCustomObject avec :
            - RawDestination   : chemin logique brut (avant normalisation ASCII)
            - CleanDestination : chemin normalisé ASCII
            - FullDestination  : chemin complet incluant le nouveau nom
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][hashtable]$FileMeta,
        [Parameter(Mandatory)][string]$Extension,
        [Parameter(Mandatory)][hashtable]$ExtensionMap,
        [Parameter(Mandatory)][string]$NewName,
        [Parameter(Mandatory)][datetime]$FileDate
    )

    try {
        # Nettoyage du chemin source
        $srcDirClean = $FileMeta.p -replace "^/drive/root:", ""

        # Type média
        $mediaType = if ($ExtensionMap.ContainsKey($Extension)) {
            $ExtensionMap[$Extension]
        }
        else {
            "Autres"
        }

        # Résolution de la stratégie de routing
        $routing = Resolve-FileRouting -FileMeta $FileMeta -Extension $Extension
        $mode = $routing.Mode
        $root = $routing.Root

        $year  = $FileDate.Year
        $month = $FileDate.ToString('MM')

        $rawDestination = $null

        switch ($mode) {

            "StayStrict" {
                # FINANCES : aucun déplacement, on garde le chemin exact
                $rawDestination = $srcDirClean
            }

            "ConfidentialVault" {
                # COFFRE-FORT : racine + 2e niveau + images/videos + YYYY/MM
                $baseRoot = $root
                $mediaFolder = switch ($mediaType) {
                    "Videos" { "videos" }
                    "Images" { "images" }
                    default  { "autres" }
                }
                $rawDestination = "$baseRoot/$mediaFolder/$year/$month"
            }

            "StaySimplified" {
                # ADMIN NON FINANCES : Stay simplifié (3 niveaux max)
                $parts = $srcDirClean.Trim('/').Split('/')
                if ($parts.Count -gt 3) {
                    $basePath = ($parts[0..2] -join '/')
                }
                else {
                    $basePath = $srcDirClean.Trim('/')
                }
                $rawDestination = "/$basePath"
            }

            "AppsOrDefaultMove" {
                # APPS + DEFAULT : Move Pellicule / Videos
                if ($mediaType -eq "Videos") {
                    $rawDestination = "/Videos/$year/$month"
                }
                else {
                    $rawDestination = "/Images/Pellicule/$year/$month"
                }
            }

            default {
                # Fallback ultime : même logique que Default
                if ($mediaType -eq "Videos") {
                    $rawDestination = "/Videos/$year/$month"
                }
                else {
                    $rawDestination = "/Images/Pellicule/$year/$month"
                }
            }
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
    catch {
        Write-Log "Échec Get-DestinationPath: $_" "Erreur"
    }
} # Get-DestinationPath


Export-ModuleMember -Function * 
