function Read-IniFile {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path $Path)) {
        throw "INI file not found: $Path"
    }

    $result = @{}
    $section = "global"
    $result[$section] = @{}

    foreach ($line in Get-Content -Path $Path) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }
        if ($trimmed.StartsWith(';') -or $trimmed.StartsWith('#')) { continue }

        if ($trimmed -match '^\[(.+)\]$') {
            $section = $Matches[1].Trim()
            if (-not $result.ContainsKey($section)) {
                $result[$section] = @{}
            }
            continue
        }

        $separatorIndex = $trimmed.IndexOf('=')
        if ($separatorIndex -lt 1) { continue }

        $key = $trimmed.Substring(0, $separatorIndex).Trim()
        $value = $trimmed.Substring($separatorIndex + 1).Trim()
        $result[$section][$key] = $value
    }

    return $result
}

function Get-IniValue {
    param(
        [Parameter(Mandatory)][hashtable]$Ini,
        [Parameter(Mandatory)][string]$Section,
        [Parameter(Mandatory)][string]$Key,
        [object]$Default = $null
    )

    if ($Ini.ContainsKey($Section) -and $Ini[$Section].ContainsKey($Key)) {
        return $Ini[$Section][$Key]
    }

    return $Default
}

function Convert-ToBoolean {
    param([object]$Value, [bool]$Default = $false)

    if ($null -eq $Value) { return $Default }
    $txt = "$Value".Trim().ToLowerInvariant()
    switch ($txt) {
        '1' { return $true }
        'true' { return $true }
        'yes' { return $true }
        'y' { return $true }
        'on' { return $true }
        '0' { return $false }
        'false' { return $false }
        'no' { return $false }
        'n' { return $false }
        'off' { return $false }
        default { return $Default }
    }
}

function Resolve-ConfigPath {
    param(
        [Parameter(Mandatory)][string]$BaseDir,
        [Parameter(Mandatory)][string]$PathValue
    )

    if ([string]::IsNullOrWhiteSpace($PathValue)) {
        return $PathValue
    }

    if ([System.IO.Path]::IsPathRooted($PathValue)) {
        return $PathValue
    }

    return Join-Path $BaseDir $PathValue
}

function Resolve-CacheFilePath {
    param(
        [Parameter(Mandatory)][string]$CacheDir,
        [Parameter(Mandatory)][string]$FileName
    )

    if ([string]::IsNullOrWhiteSpace($FileName)) {
        return $null
    }

    if ([System.IO.Path]::IsPathRooted($FileName)) {
        return $FileName
    }

    return Join-Path $CacheDir $FileName
}

function Get-AppConfiguration {
    param(
        [Parameter(Mandatory)][string]$ConfigFile
    )

    $configFullPath = (Resolve-Path $ConfigFile).Path
    $configDir = Split-Path -Parent $configFullPath

    $ini = Read-IniFile -Path $configFullPath

    $cacheDir = Resolve-ConfigPath -BaseDir $configDir -PathValue (Get-IniValue -Ini $ini -Section 'paths' -Key 'cache_dir' -Default '.\_cache')
    $rulesFile = Resolve-ConfigPath -BaseDir $configDir -PathValue (Get-IniValue -Ini $ini -Section 'paths' -Key 'rules_file' -Default '.\rules.json')

    if (-not (Test-Path $rulesFile)) {
        throw "Rules file not found: $rulesFile"
    }
    $rules = Get-Content -Path $rulesFile -Raw | ConvertFrom-Json -AsHashtable

    $allowedExt = @()
    $allowedExtRaw = Get-IniValue -Ini $ini -Section 'extensions' -Key 'allowed' -Default ''
    if (-not [string]::IsNullOrWhiteSpace($allowedExtRaw)) {
        $allowedExt = $allowedExtRaw.Split(',') | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ }
    }

    $extensionMap = @{}
    if ($rules.ContainsKey('extensionMap')) {
        foreach ($k in $rules.extensionMap.Keys) {
            $extensionMap[$k.ToLowerInvariant()] = $rules.extensionMap[$k]
        }
    }

    return [PSCustomObject]@{
        ConfigFile         = $configFullPath
        RulesFile          = $rulesFile
        CacheDir           = $cacheDir
        ClientId           = Get-IniValue -Ini $ini -Section 'graph' -Key 'client_id' -Default ''
        TokenFile          = Resolve-CacheFilePath -CacheDir $cacheDir -FileName (Get-IniValue -Ini $ini -Section 'paths' -Key 'token_file' -Default 'graph_token.json')
        IndexFile          = Resolve-CacheFilePath -CacheDir $cacheDir -FileName (Get-IniValue -Ini $ini -Section 'paths' -Key 'index_file' -Default 'onedrive_cache.json')
        ProcessedLog       = Resolve-CacheFilePath -CacheDir $cacheDir -FileName (Get-IniValue -Ini $ini -Section 'paths' -Key 'processed_log_file' -Default 'processed_ids.log')
        ExecutionReport    = Resolve-CacheFilePath -CacheDir $cacheDir -FileName (Get-IniValue -Ini $ini -Section 'paths' -Key 'execution_report_file' -Default 'azure_sync_report.csv')
        GpsCacheFile       = Resolve-CacheFilePath -CacheDir $cacheDir -FileName (Get-IniValue -Ini $ini -Section 'paths' -Key 'gps_cache_file' -Default 'gps_cache.json')
        OrganizerLogFile   = Resolve-CacheFilePath -CacheDir $cacheDir -FileName (Get-IniValue -Ini $ini -Section 'paths' -Key 'organizer_log_file' -Default 'organisation_log.txt')
        SyncLogFile        = Resolve-CacheFilePath -CacheDir $cacheDir -FileName (Get-IniValue -Ini $ini -Section 'paths' -Key 'sync_log_file' -Default 'onedrive_indexer_log.txt')
        SyncReportFile     = Resolve-CacheFilePath -CacheDir $cacheDir -FileName (Get-IniValue -Ini $ini -Section 'paths' -Key 'sync_report_file' -Default 'onedrive_duplicates_report.txt')
        LocalHashCacheFile = Resolve-CacheFilePath -CacheDir $cacheDir -FileName (Get-IniValue -Ini $ini -Section 'paths' -Key 'local_hash_cache_file' -Default 'local_hash_cache.json')
        CloudCleanerLogFile= Resolve-CacheFilePath -CacheDir $cacheDir -FileName (Get-IniValue -Ini $ini -Section 'paths' -Key 'cloud_cleaner_log_file' -Default 'onedrive_cleaner_log.txt')
        LocalFolder        = Get-IniValue -Ini $ini -Section 'sync' -Key 'local_folder' -Default 'D:\recup'
        RenameMarker       = Get-IniValue -Ini $ini -Section 'organizer' -Key 'rename_marker' -Default '--odr--'
        MaxNameLen         = [int](Get-IniValue -Ini $ini -Section 'organizer' -Key 'max_name_len' -Default '80')
        VerboseMode        = Convert-ToBoolean (Get-IniValue -Ini $ini -Section 'general' -Key 'verbose_mode' -Default 'true') $true
        AllowedExt         = $allowedExt
        ExtensionMap       = $extensionMap
        Rules              = $rules
    }
}

Export-ModuleMember -Function Read-IniFile, Get-IniValue, Convert-ToBoolean, Resolve-ConfigPath, Resolve-CacheFilePath, Get-AppConfiguration
