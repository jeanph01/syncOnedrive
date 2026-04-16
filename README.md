# syncOnedrive

PowerShell solution to **index OneDrive via Microsoft Graph**, **detect/process duplicates**, and **automatically organize media** using an external configuration engine.

> Project goal: provide a **generic, shareable, and industrializable** foundation for a GitHub release (without hard-coded business rules).

---

## 1) What this project does

The repository provides 3 main scripts:

1. **`OneDrive_Sync.ps1`**
   - Builds/updates a OneDrive cache (`delta API`).
   - Compares local files with cloud items by size/hash.
   - Moves local duplicates to `_Doublons`.
2. **`OneDrive_PictureMovieOrganiser.ps1`**
   - Analyzes the cloud cache.
   - Calculates a renaming/routing plan (JSON) according to rules.
   - Applies OneDrive moves/renames via Graph.
3. **`OneDrive_CloudCleaner.ps1`**
   - Groups cloud duplicates by hash.
   - Keeps the best occurrence according to priority rules.
   - Deletes redundant occurrences via Graph.

---

## 2) Code architecture

### Entrypoints
- `OneDrive_Sync.ps1`
- `OneDrive_PictureMovieOrganiser.ps1`
- `OneDrive_CloudCleaner.ps1`

### Modules
- `modules/AppConfig.psm1` : reads `config.ini` + `rules.json`.
- `modules/OneDriveTools.psm1` : logs, Graph authentication (device code), common utilities.
- `modules/OneDriveOrganize.psm1` : media classification, routing, name generation.
- `modules/OneDriveCacheUtils.psm1` : cache loading/repair, planning, collisions.
- `modules/GpsTools.psm1` : GPS resolution (cache + Nominatim), location normalization.

### Working data
- `_cache/onedrive_cache.json` : cloud index.
- `_cache/plan.json` : organization action plan.
- `_cache/processed_ids.log` : already processed IDs.
- `_cache/*.txt`, `_cache/*.csv` : operational logs/reports.

---

## 3) External configuration (new model)

The project now externalizes configuration and rules in two files:

- **`config.ini`** : runtime settings (Graph client, paths, global options, allowed extensions).
- **`rules.json`** : business logic (routing, application patterns, stopwords, deletion scoring, extension→category mapping).
- Scripts no longer accept cache/log/report paths as parameters: these values come exclusively from `config.ini`.

### 3.1 `config.ini`
Main sections:
- `[general]` : `verbose_mode`
- `[graph]` : `client_id`
- `[paths]` : cache/token/log/report files
- `[organizer]` : `rename_marker`, `max_name_len`
- `[sync]` : `local_folder`
- `[extensions]` : `allowed` list (CSV)

The file is documented with comments (`;` / `#`).

### 3.2 `rules.json`
Main objects:
- `extensionMap`
- `categoryRules`
- `routingRules`
- `namingRules`
- `cleanerRules`

`rules.json` does not allow native comments. The project therefore uses `_comments` fields to document the purpose of blocks.

> Recommendation: keep context-specific rules only in `rules.json`.

---

## 4) Requirements

- Windows + OneDrive.
- PowerShell 7 recommended (Windows PowerShell 5.1 possible depending on environment).
- An Azure AD / Microsoft Entra App Registration compatible with Device Code.
- Microsoft Graph access for required scopes (at minimum file read/write for intended usage).

---

## 5) Quick start

### Step A — Prepare configuration
1. Copy/adapt `config.ini`.
2. Copy/adapt `rules.json`.
3. Verify:
   - `client_id`
   - `_cache` paths
   - local folder (`local_folder`)
   - routing/deletion rules.

### Step B — Generate/update the cloud cache
```powershell
.\OneDrive_Sync.ps1 -Mode Online
```

### Step C — Simulate organization (no execution)
```powershell
.\OneDrive_PictureMovieOrganiser.ps1 -Execute:$false
```

### Step D — Execute OneDrive moves
```powershell
.\OneDrive_PictureMovieOrganiser.ps1 -Execute:$true
```

### Step E — Clean cloud duplicates (optional)
```powershell
.\OneDrive_CloudCleaner.ps1
```

---

## 6) CLI Reference

### `OneDrive_Sync.ps1`
Important parameters:
- `-Mode Online|Offline`
- `-ForceNewScan`
- `-ResetCache`
- `-ConfigFile`

Examples:
```powershell
# Complete cloud re-scan
.\OneDrive_Sync.ps1 -Mode Online -ForceNewScan

# Offline mode from existing cache
.\OneDrive_Sync.ps1 -Mode Offline
```

### `OneDrive_PictureMovieOrganiser.ps1`
Important parameters:
- `-Execute`
- `-ResetCache`
- `-ConfigFile`

Examples:
```powershell
# Validation dry run
.\OneDrive_PictureMovieOrganiser.ps1 -Execute:$false

# Real execution
.\OneDrive_PictureMovieOrganiser.ps1 -Execute:$true
```

### `OneDrive_CloudCleaner.ps1`
Important parameters:
- `-ConfigFile`

Example:
```powershell
.\OneDrive_CloudCleaner.ps1
```

---

## 7) Recommended data flow

1. **Sync** (`OneDrive_Sync.ps1`) to stabilize the cloud cache.
2. **Organization** (`OneDrive_PictureMovieOrganiser.ps1`) in dry-run then execution.
3. **Cloud cleaner** (`OneDrive_CloudCleaner.ps1`) optional, if OneDrive side duplicate purging is needed.

This sequencing reduces errors and facilitates resumes (`plan.json`, `processed_ids.log`, hash cache).

---

## 8) Best practices for GitHub publication

- Do not commit secrets/tokens (`_cache/graph_token.json` must be ignored).
- Provide examples:
  - `config.ini.example`
  - `rules.json.example`
- Document your business rules with JSON comments (`README` + version history).
- Test each `rules.json` modification in dry-run before real execution.
- Keep `_cache` logs for audit and operational rollback.

---

## 9) Known limitations / improvement opportunities

- Several scripts still have messages/functions in French + mixed conventions: a global normalization will help open-source maintenance.
- Automated tests (Pester) are not yet provided.
- Packaging the project as a module with release notes would improve external contributions.

---

## 10) Suggested roadmap

- [ ] Add `config.ini.example` and `rules.json.example`.
- [ ] Add a strict `.gitignore` (`_cache`, tokens, reports).
- [ ] Add Pester unit tests (per module).
- [ ] Add CI workflow (PowerShell lint + tests).
- [ ] Add changelog (`CHANGELOG.md`) and semver versioning.

---

## 11) License

Add an explicit license before official publication (MIT recommended to start).

---

## 12) Contribution

PRs are welcome if they respect:
- the separation **generic code** vs **external business rules**,
- compatibility with existing (`config.ini` / `rules.json`),
- a documented manual test in the PR.
