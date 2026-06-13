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
    param(
        [datetime]$DateRef,
        [string]$OriginalName,
        [string]$Extension,
        [string]$GPSLocation,
        [string]$Camera,
        [string]$SourceHint
    )

    # 1) Base = date
    $base = $DateRef.ToString("yyyyMMdd_HHmmss")

    # 2) GPS (optionnel)
    if ($GPSLocation) {
        $gpsClean = ($GPSLocation -replace '[^\w]', '_').Trim('_')
        if ($gpsClean) { $base += "_$gpsClean" }
    }

    # 3) Camera (optionnel)
    if ($Camera) {
        $camClean = ($Camera -replace '[^\w]', '_').Trim('_')
        if ($camClean) { $base += "_$camClean" }
    }

    # 4) Source hint (optionnel)
    if ($SourceHint) {
        $hintClean = ($SourceHint -replace '[^\w]', '_').Trim('_')
        if ($hintClean) { $base += "_$hintClean" }
    }

    # 5) Final marker
    $base += "--odr--"

    return "$base$Extension"
}

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
        $path = $FileMeta.p -replace "^/drive/root:", ""
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
        $rootFolder = $parts[0]
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


# =====================================================================
# ROUTING BASÉ SUR rules.json
# - Utilise Global:Rules.routingRules, folderRules, extensionMap
# - Respecte les modèles destination de rules.json
# - Ne met JAMAIS les noms de dossiers parents dans le nom final
# =====================================================================

function Get-RoutingAction {
    param(
        [string]$Path,
        [string]$Extension
    )

    $rules = $Global:Rules.routingRules
    $folderRules = $Global:Rules.folderRules

    $candidates = @()

    # 1) Règles "confidential" par regex sur le path complet
    foreach ($regex in $rules.confidentialRegexList) {
        if ($Path -match $regex) {
            $candidates += 'confidential'
            break
        }
    }

    # 2) Règles basées sur les dossiers (folderRules)
    $relativePath = $Path -replace '^/drive/root:', ''
    $segments = $relativePath.Trim('/') -split '/'
    foreach ($seg in $segments) {
        if ([string]::IsNullOrWhiteSpace($seg)) { continue }
        if ($folderRules.ContainsKey($seg)) {
            $candidates += $folderRules[$seg]
        }
    }

    # 3) Règle globale "*.*" si rien trouvé
    if (-not $candidates -and $folderRules.ContainsKey('*.*')) {
        $candidates += $folderRules['*.*']
    }

    # 4) Si toujours rien, fallback "default"
    if (-not $candidates) {
        $candidates += 'default'
    }

    # 5) Appliquer la priorité définie dans rules.json
    foreach ($prio in $rules.actionPriority) {
        if ($candidates -contains $prio) {
            return $prio
        }
    }

    return 'default'
}

function Resolve-RoutingTemplate {
    param(
        [string]$Template,
        [hashtable]$Values
    )

    if ([string]::IsNullOrWhiteSpace($Template)) {
        return $null
    }

    $result = $Template

    # 1) Gérer les blocs optionnels [ ... ]
    $result = [regex]::Replace($result, '\[(.*?)\]', {
            param($m)
            $block = $m.Groups[1].Value
            $blockResolved = $block
            foreach ($key in $Values.Keys) {
                $blockResolved = $blockResolved -replace [regex]::Escape($key), [string]$Values[$key]
            }
            # Si des tokens restent non résolus -> on supprime le bloc
            if ($blockResolved -match '<[^>]+>') {
                return ''
            }
            return $blockResolved
        })

    # 2) Remplacer les tokens simples
    foreach ($key in $Values.Keys) {
        $result = $result -replace [regex]::Escape($key), [string]$Values[$key]
    }

    # 3) Nettoyage des tokens restants et des doubles slash
    $result = $result -replace '<[^>]+>', ''
    $result = $result -replace '//+', '/'
    return $result.Trim('/')
}

function Get-DestinationPath {
    param(
        [hashtable]$FileMeta,
        [string]$Extension,
        [string]$NewName,
        [datetime]$FileDate
    )

    $rules = $Global:Rules.routingRules
    $extMap = $Config.ExtensionMap

    # 1) Catégorie media (Images / Videos / Audio, etc.)
    $media = $null
    if ($extMap.ContainsKey($Extension)) {
        $media = $extMap[$Extension]
    }
    else {
        $media = "Other"
    }

    # 2) Analyse du path source
    $srcPath = $FileMeta.p
    $relativePath = $srcPath -replace '^/drive/root:', ''
    $segments = @()
    if (-not [string]::IsNullOrWhiteSpace($relativePath)) {
        $segments = $relativePath.Trim('/') -split '/'
    }

    $level1 = if ($segments.Count -ge 1) { $segments[0] } else { "" }
    $level2 = if ($segments.Count -ge 2) { $segments[1] } else { "" }
    $level3 = if ($segments.Count -ge 3) { $segments[2] } else { "" }

    # 3) Déterminer l'action (confidential, administrative, default, only_rename, no_action)
    $actionName = Get-RoutingAction -Path $srcPath -Extension $Extension

    if (-not $rules.actions.ContainsKey($actionName)) {
        $actionName = 'default'
    }

    $action = $rules.actions[$actionName]

    # 4) Cas no_action -> ignorer le fichier
    if ($actionName -eq 'no_action' -or -not $action.destination) {
        return $null
    }

    # 5) Préparation des valeurs pour le template
    $values = @{
        '<media>'  = $media
        '<year>'   = $FileDate.ToString('yyyy')
        '<month>'  = $FileDate.ToString('MM')
        '<level1>' = $level1
        '<level2>' = $level2
        '<level3>' = $level3
    }

    $template = $action.destination

    # 6) Cas spécial only_rename : même dossier, nouveau nom
    if ($actionName -eq 'only_rename' -or $template -like 'same_directory*') {
        $cleanDest = $relativePath.Trim('/')
        $fullDest = "/$($cleanDest.Trim('/'))/$NewName"
        return [PSCustomObject]@{
            Action           = $actionName
            CleanDestination = $cleanDest
            FullDestination  = $fullDest
        }
    }

    # 7) Résolution du template rules.json (sans le nom de fichier)
    #    On enlève la partie "name.ext" du template, le nom final vient EXCLUSIVEMENT de $NewName
    $templatePath = $template -replace 'name\.ext', ''
    $templatePath = $templatePath.Trim('/')

    $resolvedPath = Resolve-RoutingTemplate -Template $templatePath -Values $values
    if ([string]::IsNullOrWhiteSpace($resolvedPath)) {
        # Fallback : media/year/month
        $resolvedPath = "$media/$($FileDate.ToString('yyyy'))/$($FileDate.ToString('MM'))"
    }

    $cleanDestination = $resolvedPath.Trim('/')
    $fullDestination = "/$($cleanDestination.Trim('/'))/$NewName"

    return [PSCustomObject]@{
        Action           = $actionName
        CleanDestination = $cleanDestination
        FullDestination  = $fullDestination
    }
}

function Get-SmartCategory {
    param(
        [string]$Path,
        [string]$Extension
    )

    # Optionnel : pour logging uniquement
    return (Get-RoutingAction -Path $Path -Extension $Extension)
}

Export-ModuleMember -Function *
