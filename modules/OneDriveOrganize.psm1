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

function Get-SmartCategory {
    <#
        1. Only media files (extensions defined in rules.json) are processed.
        2. Non-media files immediately return "no_action".
        3. Media files use folderRules to determine the action
          (confidential, administrative, default, etc.).
    #>

    param (
        [string]$Path,
        [string]$Extension
    )

    try {
        # Validate input
        if (-not $Path) {
            Write-Log "Get-SmartCategory: Invalid path" "ERROR"
            return "no_action"
        }

        # 1. Determine media type from extension
        $ext = $Extension.ToLower()
        # Determine media type (Images / Videos / Audio)
        if ($global:Config.ExtensionMap.ContainsKey($ext)) {
            $mediaType = $global:Config.ExtensionMap[$ext]
        }

        # If mediaType was not assigned → not a media file
        if (-not $mediaType) {
            return "no_action"
        }

        # 2. Extract top-level folder name
        $cleanPath = $Path -replace "^/drive/root:/", ""
        if (-not $cleanPath) {
            Write-Log "Get-SmartCategory: Empty clean path" "ERROR"
            return "no_action"
        }
        $parts = $cleanPath.Trim("/").Split("/")
        if (-not $parts -or $parts.Count -eq 0) {
            Write-Log "Get-SmartCategory: Invalid path structure" "ERROR"
            return "no_action"
        }
        $rootFolder = $parts[0]

        # 3. Folder-based rule lookup
        $folderRules = $global:Rules.folderRules

        if ($folderRules.ContainsKey($rootFolder)) {
            return $folderRules[$rootFolder]   # confidential / administrative / no_action / only_rename / default
        }

        # 4. Fallback: default rule for media files
        return "default"
    }
    catch {
        Write-Log "Get-SmartCategory failure: $_" "ERROR"
    }
} # Get-SmartCategory


# Extract useful tags from the source path
function Get-PathTags($fullPath) {
    try {
        $parts = $fullPath -replace "^/drive/root:/?", "" -split "/"
        #| Where-Object { $_ -and $_ -notmatch "Documents|Images|Videos|Musique|Pellicule|JPM" }

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
        }
        else {
            Convert-ToAscii $OriginalName
        }
        $timestamp = $DateRef.ToString("yyyyMMdd_HHmmss")
        $year = $DateRef.ToString("yyyy")
        $yearMonth = $DateRef.ToString("yyyy_MM")
        $dateRaw = $DateRef.ToString("yyyyMMdd")

        # ASCII normalization of other fields
        $cleanTags = Convert-ToAscii $PathTags
        $cleanGPS = Convert-ToAscii $GPSLocation
        $cleanCam = Convert-ToAscii $Camera
        $cleanSource = Convert-ToAscii $SourceHint

        # Splitting
        function Split-Words($txt) {
            if (-not $txt) { return @() }
            return ($txt -split "[ _\-]" | Where-Object { $_ -and $_.Trim().Length -gt 0 })
        }

        $GPSWords = Split-Words $cleanGPS
        $tagWords = Split-Words $cleanTags
        $origWords = Split-Words $cleanOriginal
        $camWords = Split-Words $cleanCam
        $srcWords = Split-Words $cleanSource

        # Stopwords
        $Stopwords = @($Global:Rules.namingRules.Stopwords)

        function Remove-Stopwords($list) {
            if (-not $list) { return @() }
            return $list | Where-Object { $Stopwords -notcontains $_.ToLower() }
        }

        $GPSWords = Remove-Stopwords $GPSWords
        $tagWords = Remove-Stopwords $tagWords
        $origWords = Remove-Stopwords $origWords

        # Remove words already present in GPS
        $GPSSet = @{}
        foreach ($w in $GPSWords) { $GPSSet[$w.ToLower()] = $true }

        function Remove-GPSRedundancy($list) {
            if (-not $list) { return @() }
            return $list | Where-Object { -not $GPSSet.ContainsKey($_.ToLower()) }
        }

        $tagWords = Remove-GPSRedundancy $tagWords
        $origWords = Remove-GPSRedundancy $origWords

        function Remove-DateRedundancy($list, $year, $yearMonth, $dateRaw, $timestamp) {
            if (-not $list) { return @() }
            return $list | Where-Object {
                $_ -notmatch $year -and
                $_ -notmatch $yearMonth -and
                $_ -notmatch $dateRaw -and
                $_ -notmatch $timestamp
            }
        }
        $tagWords  = Remove-DateRedundancy $tagWords  $year $yearMonth $dateRaw $timestamp
        $origWords = Remove-DateRedundancy $origWords $year $yearMonth $dateRaw $timestamp

        # Global assembly
        $allWords = New-Object System.Collections.Generic.List[string]
        $allWords.Add($timestamp)
        $GPSWords | ForEach-Object { $allWords.Add($_) }
        $tagWords | ForEach-Object { $allWords.Add($_) }
        $origWords | ForEach-Object { $allWords.Add($_) }
        $camWords | ForEach-Object { $allWords.Add($_) }
        $srcWords | ForEach-Object { $allWords.Add($_) }

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

function Get-MediaType {
    param([string]$Extension)

    $ext = $Extension.ToLower()
    if ($Global:Config.ExtensionMap.ContainsKey($ext)) {
        return $Global:Config.ExtensionMap[$ext]   # Images / Videos / Audio
    }

    return $null
} # Get-MediaType

function Resolve-RoutingAction {
    param(
        [hashtable]$FileMeta,
        [string]$MediaType
    )

    try {
        $path  = $FileMeta.p -replace "^/drive/root:", ""
        $parts = $path.Trim('/').Split('/')

        # 1. Confidential (regex)
        foreach ($regex in $Global:Rules.routingRules.confidentialRegexList) {
            if ($path -match $regex) {
                # root = first 2 levels (if available)
                if ($parts.Count -ge 2) {
                    $root = "/" + ($parts[0..1] -join "/")
                }
                else {
                    $root = "/" + $parts[0]
                }

                return @{
                    Action = "confidential"
                    Root   = $root
                }
            }
        }

        # 2. FolderRules
        $rootFolder  = $parts[0]
        $folderRules = $Global:Rules.folderRules

        if ($folderRules.ContainsKey($rootFolder)) {
            $action = $folderRules[$rootFolder]

            return @{
                Action = $action
                Root   = "/" + $path.Trim("/")
            }
        }

        # 3. Default
        return @{
            Action = "default"
            Root   = $null
        }
    }
    catch {
        Write-Log "Resolve-RoutingAction failure: $_" "ERROR"
        return @{
            Action = "default"
            Root   = $null
        }
    }
} # Resolve-RoutingAction

function Get-DestinationPath {
    <#
        Construit le chemin final (dossier + nom) selon les règles JSON :

        routingRules.actions:
          - confidential   : <level1>/<level2>/<media>/<year>/<month>/name.ext
          - administrative : <level1>/[<level2>/<level3>]/name.ext
          - no_action      : null
          - only_rename    : same_directory/name.ext
          - default        : <media>/<year>/<month>/name.ext
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$FileMeta,
        [Parameter(Mandatory)][string]$Extension,
        [Parameter(Mandatory)][string]$NewName,
        [Parameter(Mandatory)][datetime]$FileDate
    )

    try {
        $mediaType = Get-MediaType $Extension
        if (-not $mediaType) {
            return $null
        }

        $year  = $FileDate.ToString("yyyy")
        $month = $FileDate.ToString("MM")

        $routing = Resolve-RoutingAction -FileMeta $FileMeta -MediaType $mediaType
        $action  = $routing.Action
        $root    = $routing.Root

        $srcDirClean = $FileMeta.p -replace "^/drive/root:", ""
        $rawDestination = $null

        switch ($action) {

            "no_action" {
                return $null
            }

            "only_rename" {
                $rawDestination = "/$($srcDirClean.Trim('/'))"
            }

            "administrative" {
                $parts = $srcDirClean.Trim('/').Split('/')
                if ($parts.Count -gt 3) {
                    $base = $parts[0..2] -join "/"
                }
                else {
                    $base = $parts -join "/"
                }
                $rawDestination = "/$base"
            }

            "confidential" {
                $mediaFolder = switch ($mediaType) {
                    "Images" { "images" }
                    "Videos" { "videos" }
                    "Audio"  { "audios" }
                    default  { "autres" }
                }
                $rawDestination = "$root/$mediaFolder/$year/$month"
            }

            "default" {
                $mediaFolder = switch ($mediaType) {
                    "Images" { "Images" }
                    "Videos" { "Videos" }
                    "Audio"  { "Audio" }
                    default  { "Images" }
                }
                $rawDestination = "/$mediaFolder/$year/$month"
            }

            default {
                $mediaFolder = switch ($mediaType) {
                    "Images" { "Images" }
                    "Videos" { "Videos" }
                    "Audio"  { "Audio" }
                    default  { "Images" }
                }
                $rawDestination = "/$mediaFolder/$year/$month"
            }
        }

        $cleanDestination = Convert-ToAscii $rawDestination -IsPath $true
        $fullDestination  = "/$($cleanDestination.Trim('/'))/$NewName"

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
