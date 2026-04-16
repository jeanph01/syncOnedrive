param(
    [string]$ClientId,
    [string]$TokenFile,
    [string]$LogFile
)

# Prevent multiple imports
if ($script:ModuleLoaded) {
    return
}
$script:ModuleLoaded = $true

# Check OneDriveTools dependency
if (-not (Get-Command Get-GraphToken -ErrorAction SilentlyContinue)) {
    throw "ERROR: OneDriveTools functions are not available. Check the import in the main script."
}

# Read metadata from an Azure item (EXIF, GPS, camera, video, audio)
function Read-AzureFileInfo {
    param($item)

    try {
        if (-not ($item.file -and $item.file.hashes.sha1Hash)) {
            return $null
        }

        # GPS
        $GPS = $null
        if ($item.photo -and $item.photo.GPS) {
            $GPS = "$($item.photo.GPS.latitude),$($item.photo.GPS.longitude)"
        }
        elseif ($item.location -and $item.location.latitude) {
            $GPS = "$($item.location.latitude),$($item.location.longitude)"
        }

        # Camera
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

        # Video
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

        # EXIF date or fallback
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
            GPS = $GPS
            cam = $camera
            img = $imgInfo
            vid = $videoInfo
            aud = $audioInfo
        }
    }
    catch {
        Write-Log "Read-AzureFileInfo failure: $_" "ERROR"
    }
} # Read-AzureFileInfo


# Determine the logical category of a file based on its path and extension
function Get-SmartCategory {
    param ([string]$Path, [string]$Extension)

    try {
        # STAY rules (logical category, not final routing)
        $stayPatterns = @($Global:Rules.categoryRules.stayPatterns)
        foreach ($p in $stayPatterns) {
            if ($Path -match "(?i)$p") {
                return "Stay"
            }
        }

        # Confidential (logical category)
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
        Write-Log "Get-SmartCategory failure: $_" "ERROR"
    }
} # Get-SmartCategory


# Extract useful tags from the source path
function Get-PathTags($fullPath) {
    try {
        $parts = $fullPath -replace "^/drive/root:/?", "" -split "/" |
        Where-Object { $_ -and $_ -notmatch "Documents|Images|Videos|Musique|Pellicule|JPM" }

        return ($parts -join "_")
    }
    catch {
        Write-Log "Get-PathTags failure: $_" "ERROR"
    }
} # Get-PathTags


# Generate structured, clean, deterministic filename (Style 3)
function New-SmartFileName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][DateTime]$DateRef,
        [Parameter(Mandatory)][string]$OriginalName,
        [Parameter(Mandatory)][string]$Extension,
        [string]$GPSLocation,
        [string]$PathTags,
        [string]$Camera,
        [string]$SourceHint
    )

    try {
        # FIX: If original name is empty or just extension, use 'unnamed'
        $cleanOriginal = if ([string]::IsNullOrWhiteSpace($OriginalName) -or $OriginalName -eq $Extension) { 
            "unnamed" 
        } else { 
            Convert-ToAscii $OriginalName 
        }
        $timestamp = $DateRef.ToString("yyyyMMdd_HHmmss")
        $year      = $DateRef.ToString("yyyy")
        $yearMonth = $DateRef.ToString("yyyy_MM")
        $dateRaw   = $DateRef.ToString("yyyyMMdd")

        # ASCII normalization
        $cleanOriginal = Convert-ToAscii $OriginalName
        $cleanTags     = Convert-ToAscii $PathTags
        $cleanGPS      = Convert-ToAscii $GPSLocation
        $cleanCam      = Convert-ToAscii $Camera
        $cleanSource   = Convert-ToAscii $SourceHint

        # Splitting
        function Split-Words($txt) {
            if (-not $txt) { return @() }
            return ($txt -split "[ _\-]" | Where-Object { $_ -and $_.Trim().Length -gt 0 })
        }

        $GPSWords  = Split-Words $cleanGPS
        $tagWords  = Split-Words $cleanTags
        $origWords = Split-Words $cleanOriginal
        $camWords  = Split-Words $cleanCam
        $srcWords  = Split-Words $cleanSource

        # Stopwords
        $Stopwords = @($Global:Rules.namingRules.Stopwords)

        function Remove-Stopwords($list) {
            if (-not $list) { return @() }
            return $list | Where-Object { $Stopwords -notcontains $_.ToLower() }
        }

        $GPSWords  = Remove-Stopwords $GPSWords
        $tagWords  = Remove-Stopwords $tagWords
        $origWords = Remove-Stopwords $origWords

        # Remove words already present in GPS
        $GPSSet = @{}
        foreach ($w in $GPSWords) { $GPSSet[$w.ToLower()] = $true }

        function Remove-GPSRedundancy($list) {
            if (-not $list) { return @() }
            return $list | Where-Object { -not $GPSSet.ContainsKey($_.ToLower()) }
        }

        $tagWords  = Remove-GPSRedundancy $tagWords
        $origWords = Remove-GPSRedundancy $origWords

        # Remove date redundancies
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

        # Global assembly
        $allWords = New-Object System.Collections.Generic.List[string]
        $allWords.Add($timestamp)
        $GPSWords  | ForEach-Object { $allWords.Add($_) }
        $tagWords  | ForEach-Object { $allWords.Add($_) }
        $origWords | ForEach-Object { $allWords.Add($_) }
        $camWords  | ForEach-Object { $allWords.Add($_) }
        $srcWords  | ForEach-Object { $allWords.Add($_) }

        # Global anti-duplicate
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

        # Length limit
        $maxLenWithoutExt = $Config.MaxNameLen - $Config.RenameMarker.Length - $Extension.Length
        if ($baseName.Length -gt $maxLenWithoutExt) {
            $baseName = $baseName.Substring(0, $maxLenWithoutExt).Trim("_")
        }

        return ($baseName + $Config.RenameMarker + $Extension)
    }
    catch {
        Write-Log "New-SmartFileName failure: $_" "ERROR"
    }
} # New-SmartFileName


function Resolve-FileRouting {
    <#
    .SYNOPSIS
        Resout la strategie de routing (Stay / Move) et la racine cible selon le Path source et le type de media.

    .DESCRIPTION
        Cette fonction applique un moteur de regles deterministe, dans un ordre de priorite strict :

        RÃˆGLE 1 - FINANCES (Stay STRICT)
            Condition:
                - Le Path source commence par /drive/root:/Finances
            Intention :
                - Stay strict : aucun deplacement, on garde le Path exact, on renomme seulement.
            Example:
                /drive/root:/Finances/Maison et Logement/95 ... => /Finances/Maison_et_Logement/95_.../<NewName>

        RÃˆGLE 2 - COFFRE-FORT (Stay + mediaType) - SANS EXCEPTION
            Condition:
                - Le Path source contient (insensible a la casse) :
                    "confidential", "confidential", "pour confidential", "confidential", "privatevault"
            Intention :
                - Stay dans la racine Confidential
                - Conserver le 2e niveau (Michelle, relations, archives, etc.)
                - Organiser par Media type (images / videos)
                - Classer par annee / mois
            Destination:
                /<confidential_root>/<sub_folder>/<images|videos>/<YYYY>/<MM>/<NewName>
            Example:
                /drive/root:/Confidential/relations/... => /Confidential/relations/videos/YYYY/MM/<NewName>
                /drive/root:/VersConfidentialVault/relations/... => /VersConfidentialVault/relations/images/YYYY/MM/<NewName>
                /drive/root:/VersConfidentialVault/archives/... => /VersConfidentialVault/archives/videos/YYYY/MM/<NewName>

        RÃˆGLE 3 - APPS (WhatsApp, Messenger, DCIM, etc.)
            Condition:
                - Le Path contient : WhatsApp, Messenger, Facebook, Instagram, Camera Roll, DCIM, Android, iOS
            Intention :
                - Utiliser la meme logique que la regle par defaut (Move Pellicule / Videos)
            Destination:
                /Images/Pellicule/YYYY/MM/<NewName> ou /Videos/YYYY/MM/<NewName>

        RÃˆGLE 4 - ADMINISTRATIF NON FINANCES (Stay simplifie)
            Condition:
                - Le Path contient : Documents, Legal, Syndicat, Vie des enfants, Cuisine, Livres, JPM, etc.
            Intention :
                - Simplified Stay: keep root, but limit to 3 levels max.
            Example:
                /Documents/Work/ProjectA/Phase1/Notes => /Documents/Work/ProjectA/<NewName>

        RÃˆGLE 5 - DEFAULT (Move Pellicule / Videos)
            Condition:
                - Aucune des regles precedentes ne sâ€™applique.
            Intention :
                - Move selon Media type.
            Destination:
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

        # RÃˆGLE 1 - FINANCES (Stay STRICT)
        if ($srcDirClean -match $Global:Rules.routingRules.financeRegex) {
            return @{
                Mode = "StayStrict"
                Root = $srcDirClean
            }
        }

        # RÃˆGLE 2 - COFFRE-FORT (Stay + mediaType) - SANS EXCEPTION
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

        # RÃˆGLE 3 - APPS (WhatsApp, Messenger, DCIM, etc.) => meme logique que Default
        $appsPatterns = @($Global:Rules.routingRules.appsPatterns)
        foreach ($p in $appsPatterns) {
            if ($srcDirClean -match [Regex]::Escape($p)) {
                return @{
                    Mode = "AppsOrDefaultMove"
                    Root = $null
                }
            }
        }

        # RÃˆGLE 4 - ADMINISTRATIF NON FINANCES (Stay simplifie)
        $adminPatterns = @($Global:Rules.routingRules.adminPatterns)
        foreach ($p in $adminPatterns) {
            if ($srcDirClean -match "(?i)$p") {
                return @{
                    Mode = "StaySimplified"
                    Root = $srcDirClean
                }
            }
        }

        # RÃˆGLE 5 - DEFAULT (Move Pellicule / Videos)
        return @{
            Mode = "AppsOrDefaultMove"
            Root = $null
        }
    }
    catch {
        Write-Log "Resolve-FileRouting failure: $_" "ERROR"
    }
} # Resolve-FileRouting


function Get-DestinationPath {
    <#
    .SYNOPSIS
        Determines the final destination path for a file (target folder + new name).

    .DESCRIPTION
        This function applies the following routing rules, via Resolve-FileRouting:

        PRIORITE 1 - FINANCES (Stay STRICT)
            - Condition:
                Le Path source commence par /drive/root:/Finances
            - Behavior:
                Aucun deplacement, on garde le Path exact (nettoye ASCII), on renomme seulement.
            - Example:
                /drive/root:/Finances/House ... => /Finances/House_.../<NewName>

        PRIORITE 2 - COFFRE-FORT (Stay + mediaType) - SANS EXCEPTION
            - Condition:
                Le Path source contient "confidential", "confidential", "pour confidential", "confidential", "privatevault"
            - Behavior:
                Stay in Confidential root, keep 2nd level (Michelle, relations, archives, etc.),
                create subfolder images/ or videos/ based on media type, then sort by year / month.
            - Destination:
                /<confidential_root>/<sub_folder>/<images|videos>/<YYYY>/<MM>/<NewName>

        PRIORITE 3 - APPS (WhatsApp, Messenger, DCIM, etc.)
            - Condition:
                Le Path contient : WhatsApp, Messenger, Facebook, Instagram, Camera Roll, DCIM, Android, iOS
            - Behavior:
                Use same logic as default rule (Move Pellicule / Videos).

        PRIORITE 4 - ADMINISTRATIF NON FINANCES (Stay simplifie)
            - Condition:
                Le Path contient : Documents, Legal, Syndicat, Vie des enfants, Cuisine, Livres, JPM, etc.
            - Behavior:
                Simplified Stay: keep root, but limit to 3 levels max.
            - Example:
                /Documents/Work/ProjectA/Phase1/Notes => /Documents/Work/ProjectA/<NewName>

        PRIORITE 5 - DEFAULT (Move Pellicule / Videos)
            - Condition:
                Aucune des regles precedentes ne sâ€™applique.
            - Behavior:
                Move based on media type:
                    - Images => /Images/Pellicule/YYYY/MM/<NewName>
                    - Videos => /Videos/YYYY/MM/<NewName>
                    - Others => /Images/Pellicule/YYYY/MM/<NewName> (default)

    .PARAMETER Category
        logical category (Images, Videos, Stay, Confidential, etc.). Utilisee pour certains cas historiques,
        but main logic relies on Resolve-FileRouting and media type.

    .PARAMETER FileMeta
        Hashtable returned by Read-AzureFileInfo, containing notably:
            - p : Path parent (/drive/root:/...).

    .PARAMETER Extension
        File extension, including dot (.jpg, .mp4, etc.).

    .PARAMETER ExtensionMap
        Hashtable mapping extension => media type (Images, Videos, Others, etc.).

    .PARAMETER NewName
        New filename generated by New-SmartFileName.

    .PARAMETER FileDate
        Reference date (EXIF or fallback) used for YYYY/MM.

    .OUTPUTS
        PSCustomObject with:
            - RawDestination   : Path logique brut (avant ASCII normalization)
            - CleanDestination: Path normalise ASCII
            - FullDestination  : Path complet incluant le nouveau nom
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
        # Clean source path
        $srcDirClean = $FileMeta.p -replace "^/drive/root:", ""

        # Media type
        $mediaType = if ($ExtensionMap.ContainsKey($Extension)) {
            $ExtensionMap[$Extension]
        }
        else {
            "Autres"
        }

        # Routing strategy resolution
        $routing = Resolve-FileRouting -FileMeta $FileMeta -Extension $Extension
        $mode = $routing.Mode
        $root = $routing.Root

        $year  = $FileDate.Year
        $month = $FileDate.ToString('MM')

        $rawDestination = $null

        switch ($mode) {

            "StayStrict" {
                # FINANCES : aucun deplacement, on garde le Path exact
                $rawDestination = $srcDirClean
            }

            "ConfidentialVault" {
                # SAFE: root + 2nd level + images/videos + YYYY/MM
                $baseRoot = $root
                $mediaFolder = switch ($mediaType) {
                    "Videos" { "videos" }
                    "Images" { "images" }
                    default  { "autres" }
                }
                $rawDestination = "$baseRoot/$mediaFolder/$year/$month"
            }

            "StaySimplified" {
                # NON-FINANCIAL ADMIN: Simplified Stay (3 levels max)
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
                # APPS + DEFAULT: Move Pellicule / Videos
                if ($mediaType -eq "Videos") {
                    $rawDestination = "/Videos/$year/$month"
                }
                else {
                    $rawDestination = "/Images/Pellicule/$year/$month"
                }
            }

            default {
                # Ultimate fallback: same logic as Default
                if ($mediaType -eq "Videos") {
                    $rawDestination = "/Videos/$year/$month"
                }
                else {
                    $rawDestination = "/Images/Pellicule/$year/$month"
                }
            }
        }

        # ASCII cleaning
        $cleanDestination = Convert-ToAscii $rawDestination -IsPath $true

        # Final destination
        $fullDestination = "/$($cleanDestination.Trim('/'))/$NewName"

        return [PSCustomObject]@{
            RawDestination   = $rawDestination
            CleanDestination = $cleanDestination
            FullDestination  = $fullDestination
        }
    }
    catch {
        Write-Log "Get-DestinationPath failure: $_" "ERROR"
    }
} # Get-DestinationPath


Export-ModuleMember -Function * 

