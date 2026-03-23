function Test-Cache {
    try {
        Write-Log "=== VALIDATION DU CACHE ===" "INFO"

        $cache = $Global:State.Cache.Files
        $total = $cache.Count

        $missingPath = $cache.GetEnumerator() | Where-Object { -not $_.Value.p }
        $missingName = $cache.GetEnumerator() | Where-Object { -not $_.Value.n }
        $badPrefix = $cache.GetEnumerator() | Where-Object { $_.Value.p -notmatch "^/drive/root:" }
        $badExt = $cache.GetEnumerator() | Where-Object {
            $ext = [IO.Path]::GetExtension($_.Value.n).ToLower()
            -not $Config.ExtensionMap.ContainsKey($ext)
        }

        Write-Log "Total entrées : $total" "INFO"
        Write-Log "Chemin manquant : $($missingPath.Count)" "WARN"
        Write-Log "Nom manquant : $($missingName.Count)" "WARN"
        Write-Log "Chemin invalide : $($badPrefix.Count)" "WARN"
        Write-Log "Extension inconnue : $($badExt.Count)" "WARN"

        Write-Log "Validation terminée." "SUCCESS"
    }
    catch {
        Write-Log "Erreur Invoke-Moves : $($_.Exception.Message)" "ERROR"
        throw
    }
    
} # Test-Cache


# =====================================================================
# REPRISE AUTOMATIQUE
# =====================================================================

# Charge un plan existant si le hash du cache est identique
function Get-ExistingPlan {
    param(
        [string]$CurrentHash  # Hash actuel du cache OneDrive
    )

    try {
        $cacheFolder = Split-Path $IndexFile -Parent
        $planFile = Join-Path $cacheFolder "plan.json"
        $hashFile = Join-Path $cacheFolder "cache_hash.txt"

        if (-not (Test-Path $planFile) -or -not (Test-Path $hashFile)) {
            return $null
        }

        $oldHash = Get-Content $hashFile -ErrorAction Stop

        if ($oldHash -eq $CurrentHash) {
            Write-Log "Plan existant valide — reprise sans analyse." "SUCCESS"
            return (Get-Content $planFile -Raw | ConvertFrom-Json)
        }

        Write-Log "Plan existant invalide (hash différent)." "WARN"
        return $null
    }
    catch {
        Write-Log "Erreur lors du chargement du plan existant : $($_.Exception.Message)" "ERROR"
        return $null
    }
} # Get-ExistingPlan


# =====================================================================
# CHARGEMENT DU CACHE
# =====================================================================

# Charge le cache OneDrive et prépare FilesToProcess / ProcessedIds
function Import-Set-Cache {
    try {
        # Write-Log "Nettoyage du vieux log $LogFile"
        # if (Test-Path $LogFile) { Remove-Item $LogFile -Force }

        Write-Log "Chargement du cache OneDrive $IndexFile ..."
        if (!(Test-Path $IndexFile)) {
            Write-Log "Cache introuvable : $IndexFile" "ERROR"
            exit 1
        }

        $Global:State.Cache = Get-Content $IndexFile -Raw | ConvertFrom-Json -AsHashtable

        if (-not $Global:State.Cache.Files) {
            Write-Log "Aucun fichier dans le cache." "ERROR"
            exit 1
        }

        Write-Log "Chargement des IDs déjà traités ($ProcessedLog) ..."
        $Global:State.ProcessedIds = @{}
        $Global:State.FilesToProcess = @{}

        if (Test-Path $ProcessedLog) {
            Get-Content $ProcessedLog | ForEach-Object {
                $id = $_.Trim()
                if ($id) { $Global:State.ProcessedIds[$id] = $true }
            }
            Write-Log "Fichiers déjà traités : $($Global:State.ProcessedIds.Count)"
        }
        else {
            Write-Log "Aucun fichier traité précédemment (fichier $ProcessedLog absent)."
        }

        Write-Log "Découverte des fichiers déjà traités ayant le marqueur '$($Config.RenameMarker)' ..."
        $index = 0
        $total = $Global:State.Cache.Files.Count
        foreach ($id in $Global:State.Cache.Files.Keys) {
            $index++
            if ($index % 500 -eq 0) {
                Write-Progress -Activity "Analyse des fichiers" `
                    -Status "$index / $total" `
                    -PercentComplete (($index / $total) * 100)
            }
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
    }
    catch {
        Write-Log "Erreur Import-Set-Cache : $($_.Exception.Message)" "ERROR"
        throw
    }
} # Import-Set-Cache

# =====================================================================
# PIPELINE FUSIONNÉ : ANALYSE + BARRE DE PROGRESSION + PLAN
# =====================================================================

# Analyse les fichiers et construit le plan de déplacement
function New-Plan {
    Write-Log "Analyse des fichiers (pipeline fusionné)..."

    try {
        $FileIds = $Global:State.FilesToProcess.Keys
        $TotalFiles = $FileIds.Count
        $StartTime = Get-Date
        $count = 0

        foreach ($fileId in $FileIds) {

            $count++
            $fileMeta = $Global:State.Cache.Files[$fileId]
            $extension = [System.IO.Path]::GetExtension($fileMeta.n).ToLower()

            if ($count % 2000 -eq 0) {

                $elapsed = (Get-Date) - $StartTime
                $avgTime = $elapsed.TotalSeconds / [math]::Max($count, 1)
                $remainingStr = "{0:hh\:mm\:ss}" -f [TimeSpan]::FromSeconds($avgTime * ($TotalFiles - $count))

                Write-Progress -Activity "Analyse OneDrive" `
                    -Status "$count / $TotalFiles | Restant: $remainingStr" `
                    -PercentComplete (($count / $TotalFiles) * 100)

                try {
                    $cacheFolder = Split-Path $IndexFile -Parent
                    $planFile = Join-Path $cacheFolder "plan.json"
                    $Global:State.PlannedActions |
                    ConvertTo-Json -Depth 10 |
                    Set-Content $planFile
                }
                catch {
                    Write-Log "Erreur sauvegarde progression : $($_.Exception.Message)" "ERROR"
                }
            }

            Write-Log "----------------------------------------------" "DEBUG"
            Write-Log "Analyse du fichier" "DEBUG"
            Write-Log "ID             : $fileId" "DEBUG"
            Write-Log "Nom original   : $($fileMeta.n)" "DEBUG"
            Write-Log "Chemin source  : $($fileMeta.p)" "DEBUG"
            Write-Log "Extension      : $extension" "DEBUG"
            Write-Log "Date fichier   : $($fileMeta.d)" "DEBUG"
            Write-Log "GPS            : $($fileMeta.gps)" "DEBUG"

            # Classification
            $category = Get-SmartCategory -Path $fileMeta.p -Extension $extension
            Write-Log "Classification intelligente = ($category)" "DEBUG"

            if (-not $Config.ExtensionMap.ContainsKey($extension)) {
                Write-Log "Ignoré : extension non supportée ($extension)" "DEBUG"
                continue
            }

            $fileDate = [DateTime]$fileMeta.d

            # GPS
            $gpsLocation = $null
            if ($fileMeta.gps) {
                $gpsLocation = Get-LocationName $fileMeta.gps
                Write-Log "Localisation GPS : $gpsLocation" "DEBUG"
            }

            # Tags
            $pathTags = Get-PathTags $fileMeta.p
            Write-Log "Tags de chemin : $pathTags" "DEBUG"

            # Caméra
            $camera = $fileMeta.cam

            # Source hint
            $sourceHint = ""
            if ($fileMeta.p -match "WhatsApp") { $sourceHint = "WhatsApp" }
            elseif ($fileMeta.p -match "Messenger") { $sourceHint = "Messenger" }
            elseif ($fileMeta.p -match "Instagram") { $sourceHint = "Instagram" }

            # Nouveau nom
            $originalNameNoExt = [System.IO.Path]::GetFileNameWithoutExtension($fileMeta.n)
            if ([string]::IsNullOrWhiteSpace($originalNameNoExt)) {
                Write-Log "Nom de fichier vide, fichier ignoré : $($fileMeta.p)/$($fileMeta.n)" "WARN"
                continue
            }

            $newName = New-SmartFileName `
                -DateRef      $fileDate `
                -OriginalName $originalNameNoExt `
                -Extension    $extension `
                -GpsLocation  $gpsLocation `
                -PathTags     $pathTags `
                -Camera       $camera `
                -SourceHint   $sourceHint

            Write-Log "Nouveau nom généré : $newName" "DEBUG"
            # Destination
            $dest = Get-DestinationPath `
                -Category     $category `
                -FileMeta     $fileMeta `
                -Extension    $extension `
                -ExtensionMap $Config.ExtensionMap `
                -NewName      $newName `
                -FileDate     $fileDate

            Write-Log "Chemin destination = ($($dest.CleanDestination))" "DEBUG"
            $cleanDestination = $dest.CleanDestination
            $fullDestination = $dest.FullDestination

            # Vérification si déjà à la bonne place
            $srcDirClean = $fileMeta.p -replace "^/drive/root:", ""
            $currentPath = "$($srcDirClean.Trim('/'))/$($fileMeta.n)"

            if ($currentPath -eq $fullDestination.Trim('/')) {
                Write-Log "Déjà à la bonne place : $($fileMeta.n)" "DEBUG"
                continue
            }

            # Ajout au plan
            $Global:State.PlannedActions.Add([PSCustomObject]@{
                    Id      = $fileId
                    SrcPath = $fileMeta.p
                    SrcName = $fileMeta.n
                    DstDir  = "/$($cleanDestination.Trim('/'))"
                    DstName = $newName
                    FullDst = $fullDestination
                })
        }

        Write-Log "Plan généré : $($Global:State.PlannedActions.Count) fichiers." "SUCCESS"
        # Sauvegarde du plan JSON
        try {
            $cacheFolder = Split-Path $IndexFile -Parent
            $planFile = Join-Path $cacheFolder "plan.json"
            $Global:State.PlannedActions | ConvertTo-Json -Depth 10 | Set-Content $planFile
            Write-Log "Plan sauvegardé dans $planFile" "SUCCESS"
        }
        catch {
            Write-Log "Erreur lors de la sauvegarde du plan : $($_.Exception.Message)" "ERROR"
        }
    }
    catch {
        Write-Log "Erreur New-Plan : $($_.Exception.Message)" "ERROR"
        throw
    }
} # New-Plan



function Test-Plan {
    try {
        # Analyse de l'état en mémoire au lieu de recharger le fichier JSON
        $plan = $Global:State.PlannedActions

        if (-not $plan -or $plan.Count -eq 0) {
            Write-Log "Aucun plan chargé pour analyse." "WARN"
            return
        }

        Write-Log "=== ANALYSE DU PLAN ===" "INFO"
        Write-Log "Total actions : $($plan.Count)" "INFO"

        # 1. Vérifier les collisions de noms
        $duplicates = $plan.FullDst | Group-Object | Where-Object { $_.Count -gt 1 }
        if ($duplicates) {
            Write-Log "Collisions détectées :" "ERROR"
            foreach ($d in $duplicates) {
                Write-Log " - $($d.Name) ($($d.Count) occurrences)" "ERROR"
            }
        }
        else {
            Write-Log "Aucune collision détectée." "SUCCESS"
        }

        # 2. Vérifier les chemins trop longs
        $tooLong = $plan | Where-Object { $_.FullDst.Length -gt 250 }
        if ($tooLong) { Write-Log "Chemins > 250 caractères : $($tooLong.Count)" "INFO" }

        Write-Log "Analyse terminée." "SUCCESS"
    }
    catch {
        Write-Log "Erreur Test-Plan : $($_.Exception.Message)" "ERROR"
    }
} # Test-Plan


function Debug-File {
    param(
        [string]$Id
    )
    try {
        if (-not $Global:State.Cache) {
            Write-Log "Cache non chargé." "ERROR"
            return
        }

        if (-not $Global:State.Cache.Files.ContainsKey($Id)) {
            Write-Log "ID introuvable dans le cache." "ERROR"
            return
        }

        $f = $Global:State.Cache.Files[$Id]

        Write-Log "=== DEBUG FILE $Id ===" "INFO"
        Write-Log "Chemin : $($f.p)" "INFO"
        Write-Log "Nom    : $($f.n)" "INFO"
        Write-Log "Date   : $($f.d)" "INFO"
        Write-Log "GPS    : $($f.gps)" "INFO"
        Write-Log "Caméra : $($f.cam)" "INFO"
        Write-Log "========================" "INFO"

    }
    catch {
        Write-Log "Erreur Invoke-Moves : $($_.Exception.Message)" "ERROR"
        throw
    }

} # Debug-File

function Start-DryRun {
    try {
        Write-Log "=== MODE DRY-RUN ===" "INFO"

        Test-Plan

        Write-Log "Aucun déplacement ne sera effectué." "WARN"
        Write-Log "Vous pouvez maintenant exécuter : -Execute `$true" "INFO"

    }
    catch {
        Write-Log "Erreur Invoke-Moves : $($_.Exception.Message)" "ERROR"
        throw
    }
} # Start-DryRun

function Repair-Cache {
    try {
        Write-Log "=== FIX CACHE : Nettoyage automatique du cache OneDrive ===" "WARN"

        $cache = $Global:State.Cache.Files
        $removed = 0
        $fixedExt = 0

        # On extrait les clés dans un tableau fixe pour éviter l'erreur d'énumération
        $keys = @($cache.Keys)

        foreach ($id in $keys) {
            $f = $cache[$id]

            # Supprimer les entrées sans chemin ou nom
            if (-not $f.p -or -not $f.n) {
                $cache.Remove($id)
                $removed++
                continue
            }

            # Supprimer les chemins invalides
            if ($f.p -notmatch "^/drive/root:") {
                $cache.Remove($id)
                $removed++
                continue
            }

            # Corriger les extensions polluées (ex: .jpg?width=...)
            $ext = [IO.Path]::GetExtension($f.n).ToLower()
            $cleanExt = $ext -replace "\?.*$","" -replace "\&.*$",""

            if ($ext -ne $cleanExt) {
                $f.n = $f.n.Replace($ext, $cleanExt)
                $fixedExt++
            }

            # Supprimer les extensions inconnues
            if (-not $Config.ExtensionMap.ContainsKey($cleanExt)) {
                $cache.Remove($id)
                $removed++
                continue
            }
        }

        Write-Log "Fix terminé : $removed entrées supprimées, $fixedExt extensions corrigées." "SUCCESS"
        $Global:State.Cache | ConvertTo-Json -Depth 10 | Set-Content $IndexFile
    }
    catch {
        Write-Log "Erreur Repair-Cache : $($_.Exception.Message)" "ERROR"
    }
}

function Repair-Collisions {
    try {
        Write-Log "=== FIX COLLISIONS : Résolution proactive ===" "WARN"
        
        # On travaille directement sur la liste en mémoire
        $groups = $Global:State.PlannedActions | Group-Object FullDst | Where-Object { $_.Count -gt 1 }

        if (-not $groups) {
            Write-Log "Aucune collision détectée." "SUCCESS"
            return
        }

        foreach ($g in $groups) {
            # Le premier fichier garde son nom, les suivants sont indexés
            for ($i = 1; $i -lt $g.Count; $i++) {
                $item = $g.Group[$i]
                $ext = [System.IO.Path]::GetExtension($item.DstName)
                $nameOnly = [System.IO.Path]::GetFileNameWithoutExtension($item.DstName)
                
                # Mise à jour du nom et du chemin complet de destination
                $item.DstName = "$nameOnly`_$i$ext"
                $item.FullDst = "$($item.DstDir.TrimEnd('/'))/$($item.DstName)"
            }
        }

        # On sauvegarde le plan modifié sur le disque immédiatement
        $planFile = Join-Path (Split-Path $IndexFile -Parent) "plan.json"
        $Global:State.PlannedActions | ConvertTo-Json -Depth 10 | Set-Content $planFile

        Write-Log "Collisions résolues et plan synchronisé sur disque." "SUCCESS"
    }
    catch {
        Write-Log "Erreur Repair-Collisions : $($_.Exception.Message)" "ERROR"
    }
}


function Repair-Paths {
    # Normalise les chemins OneDrive (double slash, espaces, caractères invalides).
    try {
        Write-Log "=== FIX PATHS : Normalisation des chemins ===" "WARN"

        foreach ($entry in $Global:State.Cache.Files.GetEnumerator()) {
            $f = $entry.Value

            if ($f.p) {
                $clean = $f.p -replace "//+", "/" -replace "\s+", "_"
                if ($clean -ne $f.p) {
                    $f.p = $clean
                }
            }
        }

        Write-Log "Normalisation des chemins terminée." "SUCCESS"
    }
    catch {
        Write-Log "Erreur Repair-Paths : $($_.Exception.Message)" "ERROR"
    }
} # Repair-Paths

function Repair-Names {
    # Corrige les noms invalides (espaces, caractères interdits, noms trop longs).
    try {
        Write-Log "=== FIX NAMES : Normalisation des noms ===" "WARN"

        foreach ($entry in $Global:State.Cache.Files.GetEnumerator()) {
            $f = $entry.Value

            if ($f.n) {
                $clean = $f.n -replace "[^\w\.\-]", "_" -replace "_+", "_"

                if ($clean.Length -gt $Config.MaxNameLen) {
                    $clean = $clean.Substring(0, $Config.MaxNameLen)
                }

                $f.n = $clean
            }
        }

        Write-Log "Normalisation des noms terminée." "SUCCESS"
    }
    catch {
        Write-Log "Erreur Repair-Names : $($_.Exception.Message)" "ERROR"
    }
} # Repair-Names


function Repair-GPS {
    # Supprime les coordonnées GPS invalides ou corrompues.
    try {
        Write-Log "=== FIX GPS : Nettoyage des GPS invalides ===" "WARN"

        foreach ($entry in $Global:State.Cache.Files.GetEnumerator()) {
            $f = $entry.Value

            if ($f.gps) {
                $lat = $f.gps.lat
                $lon = $f.gps.lon

                if ($lat -lt -90 -or $lat -gt 90 -or $lon -lt -180 -or $lon -gt 180) {
                    $f.gps = $null
                }
            }
        }

        Write-Log "Nettoyage GPS terminé." "SUCCESS"
    }
    catch {
        Write-Log "Erreur Repair-GPS : $($_.Exception.Message)" "ERROR"
    }
} # Repair-GPS

# ============================================================
# INITIALISATION
# ============================================================
function main {
    try {      
        if ($script:ModuleLoaded) {
            Write-Log "OneDriveCacheUtils.psm1 déjà chargé → import ignoré" "DEBUG"
            return
        }
        $script:ModuleLoaded = $true

        Write-Log "OneDriveCacheUtils.psm1 chargé"

    }
    catch {
        Write-Log "Échec : $_" "ERREUR"
    }
} # main


main
# ============================================================
# EXPORT
# ============================================================
Export-ModuleMember -Function *