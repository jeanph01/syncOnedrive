Voici **un README complet, professionnel, exhaustif**, fidèle à **tout ce que ton projet fait réellement**, incluant :

- la prise en charge OneDrive Personnel **et** OneDrive Business,
- les exigences de licence SPO,
- la configuration Azure AD / Entra ID,
- l’architecture complète,
- les flux d’exécution,
- les bonnes pratiques GitHub,
- les limitations connues,
- un guide de dépannage (400, 401, delta, tokens),
- et une documentation claire pour un utilisateur externe.

Il est structuré pour être **publier tel quel** sur GitHub.

---

# 📦 **syncOnedrive — Industrial OneDrive Indexing, Deduplication & Media Organization**

PowerShell solution to **index OneDrive via Microsoft Graph**, **detect/process duplicates**, and **automatically organize media** using an external configuration engine.

The project is designed to be:

- **Generic** (no hard‑coded business rules)
- **Configurable** (`config.ini` + `rules.json`)
- **Robust** (delta API, hash caching, resume support)
- **Industrializable** (GitHub‑ready, modular, maintainable)

---
postulat : on ne traite que les fichiers medias : images/videos/audios



type_action par priorité:
confidential = conserver les 2 premiers niveaux et deplacer et renommer dans <niv1>/<niv2>/<audios/videos/images>/<annee>/<mois>/nom.ext
administrative = conserver les 3 premiers niveaux si plus que 3 niveaux et deplacer et renommer dans <niv1>/[<niv2>/<niv3>]/nom.ext
no_action = ne rien faire
default = deplacer et renommer dans <audios/videos/images>/<annee>/<mois>/nom.ext sinon laisser sur place
only_rename = renommer seulement ne pas deplacer

*.*  --> document a la racine --> default
bureau --> default
Cuisine --> administrative
Documents --> administrative
Fichiers Microsoft Copilot Chat --> default
Fichiers transcrits --> no_action
films --> no_action
Finances --> only_rename
Images  --> default
Importations --> no_action
jp --> default
JPM --> default
Livres --> no_action
Loisirs --> administrative
Légal --> administrative
Music  --> default
packages informatique --> no_action
Pièces jointes --> no_action
scan  --> only_rename
CoffreFort  --> confidential
VersCoffreFort --> confidential
Videos  --> default
Vidéos  --> default
Vie des enfants --> administrative



la regle de nommage est =
## Détail de l’ordre de construction du nom

1. `timestamp`
   - Toujours en premier.
   - Forme `yyyyMMdd_HHmmss`.
   - Garantit l’unicité temporelle et rend le nom déterministe.

2. `GPSWords`
## Règle de `Get-LocationName`

1. Entrée :
   - paramètre `$gps` sous la forme `lat,lon`
   - si `$gps` est vide, `","`, ou `0,0` → retourne `null`

2. Normalisation et cache :
   - initialise le cache GPS s’il n’existe pas
   - calcule une clé de grille par arrondi à 4 décimales (`Get-GpsGridKey`)
   - si la clé existe dans le cache → retourne le nom normalisé

3. Recherche de proximité :
   - si pas de clé exacte, cherche une clé proche dans le cache (~100 m)
   - si trouvée → retourne ce nom

4. Appel API Nominatim :
   - si pas dans le cache, interroge Nominatim avec `resolve-gpsapi`
   - si échec, retente avec une tolérance de ±0,01°

5. Extraction intelligente du lieu :
   - prend d’abord `city`, puis `town`, `village`, `hamlet`, `suburb`, `municipality`, `county`, `state`, `country`
   - construit `city-state-country`
   - normalise le résultat en ASCII et sans caractères invalides via `Convert-LocationName`

6. Cache et sauvegarde :
   - stocke le nom normalisé dans le cache à la clé de grille
   - écrit le cache sur disque (`Save-GpsCache`)

7. Résultat :
   - retourne un nom de lieu propre et stable, par exemple `Paris-IleDeFrance-France`
   - si aucune info n’a pu être résolue → retourne `null`


1. `tagWords`
   - Mots issus du chemin source (`PathTags`).
   - Représente le contexte métier ou dossier d’origine.
   - Exemple : `Vacances`, `Famille`, `WhatsApp`.

2. `origWords`
   - Mots du nom original du fichier (`OriginalName`).
   - Contient l’information directe sur le contenu du fichier.
   - Exemple : `IMG_1234`, `Anniversaire`, `Screenshot`.

3. `mediaWords`
   - Mots extraits de la marque/modèle de l’appareil photo.
   - Permet d’ajouter l’info matériel si elle existe.
   - Exemple : `iPhone`, `Canon`, `Galaxy`.
   - Durée du film si c'est le cas


---

## Pourquoi cet ordre ?

- `GPSWords` avant `tagWords` : la localisation est plus stable que le dossier source.
- `tagWords` avant `origWords` : le contexte du chemin prime sur le nom brut.
- `origWords` avant `mediaWords`/`` : l’information du fichier lui-même reste centrale.
- `mediaWords`  : ces données sont des métadonnées complémentaires, donc placées en fin de chaîne.

---

## Résultat attendu

Le nom final devient :
`yyyyMMdd_HHmmss_<GPS>_<tags>_<original>_<media>_<doublon>--odr--.ext`

Chaque segment est :
- normalisé en ASCII,
- séparé par `_`,
- sans doublons,
- sans stopwords,
- sans répétition de date.



DateRef devient le préfixe principal : format yyyyMMdd_HHmmss
ajouté en première position du nom
OriginalName est nettoyé :

si vide ou égal à l’extension, on utilise unnamed
sinon on normalise en ASCII
Tous les champs sont convertis en ASCII :

OriginalName, PathTags, GPSLocation, Media,
Chaque texte est découpé en mots sur [ _-] :

GPSWords, tagWords, origWords, mediaWords,
Élimination des mots inutiles :

suppression des stopwords définis dans Rules.namingRules.Stopwords
suppression des mots déjà présents dans GPSWords pour éviter les doublons
suppression des mots identiques à la date : année, année_mois, date brute, timestamp
Assemblage de l’ordre final :

timestamp
puis GPSWords
puis tagWords
puis origWords
puis mediaWords
Suppression des doublons globaux :

chaque mot ne peut apparaitre qu’une seule fois (comparaison insensible à la casse)
Reconstruction :

tous les éléments sont joints avec _
on retire les underscores en début/fin
Limitation de la longueur :

maxLenWithoutExt = Config.MaxNameLen - Config.RenameMarker.Length - Extension.Length
si le nom est trop long, on tronque proprement en fin
Résultat final :

en cas de doublons :
no_doublon = vide ou on ajoute un _1 ou _2 ou _n

baseName + no_doublon + Config.RenameMarker + Extension
donc le fichier devient :
yyyyMMdd_HHmmss_<gps>_<tags>_<original>_<media>_<>--odr--.ext
En résumé : le nom est déterministe, lisible, sans accents, priorise la date, retire les mots redondants et supprime les mots vides, puis ajoute le marqueur de renommage avant l’extension.

---


---

# 🚀 1. Features

### ✔ **OneDrive Cloud Indexing (Delta API)**
- Full or incremental scan using Microsoft Graph `/drive/root/delta`
- Robust retry logic with exponential backoff
- Automatic cache persistence (`onedrive_cache.json`)
- Automatic recovery from corrupted delta tokens

### ✔ **Local Duplicate Detection**
- Compares local files with cloud items by size + SHA‑1 hash
- Moves duplicates to `_Duplicates`
- Maintains a local hash cache for performance

### ✔ **Cloud Duplicate Detection**
- Groups cloud items by hash
- Identifies redundant items
- Generates a deletion plan
- Optional automatic cleanup

### ✔ **Media Organization Engine**
- Reads `rules.json` to classify photos/videos
- Generates a routing plan (JSON)
- Applies renames/moves via Graph
- Supports dry‑run and execution modes
- **Intelligent Media Classification**:
    - **Actually Animated Images**: Only GIFs, WebPs, or APNGs containing multi-frame data (detected via the Graph `video` facet) are routed to the `Videos` folder structure. Static versions remain in the `Images` structure.
    - **Short Camera Videos**: Videos taken by a camera (identified by `video` and `photo` metadata) with a duration below a configurable threshold (e.g., 60 seconds) are treated as `Images` and remain within the `Images` folder structure. This prevents short clips from being separated from their associated photos.



### ✔ **External Configuration**
- `config.ini` controls:
  - Graph client ID
  - Cache/log paths
  - Allowed extensions
  - Local folder
  - Verbose mode
- `rules.json` controls:
  - Routing rules
  - Naming rules
  - Category mapping
  - Stopwords
  - Deletion scoring

### ✔ **Modular Architecture**
- `OneDriveTools.psm1` → logging, authentication, utilities
- `AppConfig.psm1` → config + rules loader
- `OneDriveOrganize.psm1` → media classification
- `OneDriveCacheUtils.psm1` → cache repair, planning
- `GpsTools.psm1` → GPS extraction + Nominatim caching

---

# 🧩 2. Architecture Overview

```
syncOnedrive/
│
├── OneDrive_Sync.ps1                # Cloud index + local duplicate cleanup
├── OneDrive_PictureMovieOrganiser.ps1
├── OneDrive_CloudCleaner.ps1
│
├── modules/
│   ├── AppConfig.psm1               # config.ini + rules.json loader
│   ├── OneDriveTools.psm1           # logging + Graph auth + utilities
│   ├── OneDriveOrganize.psm1        # media classification + routing
│   ├── OneDriveCacheUtils.psm1      # cache repair + planning
│   └── GpsTools.psm1                # GPS extraction + geocoding
│
├── _cache/
│   ├── onedrive_cache.json
│   ├── plan.json
│   ├── graph_token.json
│   ├── processed_ids.log
│   └── *.txt / *.csv (logs)
│
├── config.ini
└── rules.json
```

---

# 🔐 3. Authentication & Account Compatibility

## ✔ Supported account types

### **OneDrive Personnel (Outlook.com / Hotmail / Live / Gmail‑linked)**
Use:

```
tenant = "consumers"
```

in `OneDriveTools.psm1`.

No SharePoint Online license required.

### **OneDrive Business / Enterprise (Azure AD / Entra ID)**
Requires:

- A valid **SharePoint Online (SPO)** license
- A provisioned OneDrive site
- A tenant‑specific endpoint:

```
tenant = "<yourtenant>.onmicrosoft.com"
```

Without SPO, Graph returns:

```
Tenant does not have a SPO license.
```

---

# 📄 4. Requirements

### ✔ PowerShell
- PowerShell 7 recommended
- Windows PowerShell 5.1 supported

### ✔ Azure AD / Entra App Registration
- Public client flow enabled
- Device Code Flow enabled
- Supported account types:
  - **Multitenant + Personal Microsoft accounts** (recommended)
- Required scopes:
  - `Files.ReadWrite.All`
  - `User.Read`
  - `offline_access`

### ✔ OneDrive Account
- **Personal** → no license required
- **Business** → requires **SharePoint Online**

---

# ⚙️ 5. Configuration Files

## `config.ini`

Controls:

- Graph client ID
- Cache/log paths
- Local folder
- Allowed extensions
- Verbose mode

Example:

```ini
[general]
verbose_mode = true

[graph]
client_id = 00000000-0000-0000-0000-000000000000

[paths]
cache_dir = _cache
token_file = _cache/graph_token.json
log_file = _cache/sync.log
index_file = _cache/onedrive_cache.json

[sync]
local_folder = D:\recup

[extensions]
allowed = jpg,jpeg,png,mp4,mov,avi
```

---

## `rules.json`

Controls:

- Category mapping
- Routing rules
- Naming rules
- Stopwords
- Deletion scoring

Example:

```json
{
  "extensionMap": {
    "jpg": "photo",
    "mp4": "video"
  },
  "routingRules": [
    { "category": "photo", "target": "Photos/{year}/{month}" }
  ]
}
```

---

# 🧪 6. Usage

## A — Build/update cloud cache

```powershell
.\OneDrive_Sync.ps1 -Mode Online
```

## B — Simulate media organization

```powershell
.\OneDrive_PictureMovieOrganiser.ps1 -Execute:$false
```

## C — Apply media organization

```powershell
.\OneDrive_PictureMovieOrganiser.ps1 -Execute:$true
```

## D — Clean cloud duplicates

```powershell
.\OneDrive_CloudCleaner.ps1
```

## E — Advanced Parameters

### Process Range Filtering (Debugging)

To process only a subset of files during organization (useful for debugging):

```powershell
# Process only the first file
.\OneDrive_PictureMovieOrganiser.ps1 -ProcessRange "1"

# Process files 1 to 10
.\OneDrive_PictureMovieOrganiser.ps1 -ProcessRange "1..10"

# Process from file 10 to the end
.\OneDrive_PictureMovieOrganiser.ps1 -ProcessRange "10+"
```

**Note:** File numbering starts at 1, not 0. Invalid ranges will process all files with a warning.

---

# 🔄 7. Recommended Workflow

1. **Sync** → build stable cloud cache
2. **Organize (dry‑run)** → validate routing
3. **Organize (execute)** → apply moves
4. **Cloud cleanup** → optional deduplication

This ensures:

- predictable results
- resumable operations
- minimal API calls

---

# 🛠 8. Troubleshooting

### ❌ **400 Bad Request — Tenant does not have a SPO license**
Cause: OneDrive Business without SharePoint Online license
Fix:
- Use a personal account (`tenant = consumers`)
- OR assign a SPO license

---

### ❌ **400 Bad Request — Unsupported segment: root**
Cause: OneDrive not provisioned
Fix:
- Log into [https://onedrive.live.com](https://onedrive.live.com) or [https://portal.office.com](https://portal.office.com) once

---

### ❌ **401 Unauthorized**
Cause: Token expired or invalid
Fix:
- Delete `_cache/graph_token.json`
- Re‑authenticate

---

### ❌ **Delta token corrupted**
Fix: delete:

```
_cache/onedrive_cache.json
_cache/delta*.*
```

---

### ❌ **ErrorDetails empty**
Cause: HttpResponseMessage stream disposed
Fix: use `ErrorDetails.Message` (already implemented)

---

# 🧹 9. GitHub Best Practices

- Add `.gitignore`:
  - `_cache/`
  - `graph_token.json`
  - logs/reports
- Provide:
  - `config.ini.example`
  - `rules.json.example`
- Add:
  - CHANGELOG.md
  - versioning (semver)
  - CI (lint + Pester tests)

---

# 🧭 10. Roadmap

- [ ] Auto‑detect account type (MSA vs AAD)
- [ ] Add Pester tests
- [ ] Add CI workflow
- [ ] Add full documentation website
- [ ] Add parallel delta scanning
- [ ] Add OneDrive upload support

---

# 📜 11. License

MIT recommended.

---

# 🤝 12. Contribution

PRs welcome if they respect:

- separation between **generic code** and **business rules**
- compatibility with `config.ini` / `rules.json`
- documented manual tests


C'est une excellente initiative. Documenter le **Manifeste Azure** est crucial car c'est là que se cachent les "vérités" techniques qui font que ton script fonctionne (ou échoue). Ton [Manifeste Azure](https://portal.azure.com/#view/Microsoft_AAD_RegisteredApps/ApplicationMenuBlade/~/Manifest/appId/176fc7bc-42c9-4a25-82b5-0ad584d3c061/defaultBlade/Branding) montre des choix précis qu'il faut refléter dans le [README.md](https://www.google.com/search?q=file:///C:/Users/jeanp/github/syncOnedrive/README.md).

Voici les sections à ajouter ou compléter pour que ton README soit un miroir fidèle de la réalité technique :

-----

## 🛠️ Configuration Technique (Basée sur le Manifeste)

Il est important de documenter ces paramètres spécifiques du JSON pour la pérennité du projet :

### 1\. Type d'Application et Flux

  * **`isFallbackPublicClient: true`** : C'est ce paramètre (ligne 15 du manifeste) qui autorise ton script PowerShell à utiliser le flux de code d'appareil (*Device Code Flow*). Sans cela, l'authentification interactive échouerait.
  * **`accessTokenAcceptedVersion: 2`** : Tu utilises la version 2.0 des jetons Azure AD, ce qui est indispensable pour supporter à la fois les comptes professionnels et personnels (Outlook/Gmail).

### 2\. Audience et Multi-location (*Tenancy*)

  * **`signInAudience: "AzureADandPersonalMicrosoftAccount"`** : Ton application est configurée pour être **Multitenant + Personal**. Cela signifie que le script n'est pas limité à ton domaine `onmicrosoft.com` ; il peut techniquement fonctionner pour n'importe quel utilisateur OneDrive dans le monde.

### 3\. Permissions API (OAuth2 Scopes)

Ton manifeste (section `requiredResourceAccess`) doit lister les scopes que tu as activés. Assure-toi de mentionner dans le README :

  * `Files.ReadWrite.All` : Pour scanner et gérer les doublons.
  * `User.Read` : Pour identifier le profil utilisateur.
  * `offline_access` : **Crucial** pour obtenir un `refresh_token` et éviter de se reconnecter toutes les heures.

-----

## 💡 Choix Conceptuels et Retours d'Expérience

Ajoute une section **"Troubleshooting & Lessons Learned"** pour documenter les pièges que nous avons évités :

### 4\. La gestion du "SPO License Error"

C'est le point le plus important de tes tests récents.

> **Note Conceptuelle :** Pour les comptes de type "Organisation" (ex: `.onmicrosoft.com`), l'API Microsoft Graph exige une licence **SharePoint Online (SPO)** active. Sans cette licence, l'accès au `drive` renvoie une erreur `400 Bad Request`. Pour un usage personnel sans frais, il est préférable d'utiliser un compte Microsoft standard via l'endpoint `common` ou `consumers`.

### 5\. Stratégie de Scan Delta

  * **Pourquoi `/delta` ?** : Explique que tu as choisi l'endpoint `.../drive/root/delta` car il permet de récupérer uniquement les changements depuis le dernier passage, ce qui économise de la bande passante et évite les limitations (*throttling*) de Microsoft.
  * **Le choix du `$select`** : Documente que tu restreins les champs (name, id, size, hashes) pour optimiser la vitesse de traitement et la mémoire du script.

-----

## 📝 Structure suggérée pour ton README.md

```markdown
## ⚙️ Azure Configuration (Manifest Details)
The application is configured as a **Public Client** with the following manifest specifics:
- **Allow Public Flows**: `isFallbackPublicClient` set to `true`.
- **Supported Accounts**: `AzureADandPersonalMicrosoftAccount` (Multitenant + Consumers).
- **OAuth2 Version**: `v2.0` (`accessTokenAcceptedVersion: 2`).

## 🔑 Permissions & Scopes
The script requires a one-time admin consent for:
- `Files.ReadWrite.All`: Full access to scan and manage duplicates.
- `offline_access`: Enables persistent sessions via refresh tokens.

## ⚠️ Important Note on Licensing
If using a Business/Organization tenant (e.g., `.onmicrosoft.com`), the account **MUST** have a valid **SharePoint Online (SPO)** license assigned. Otherwise, the API will return a `Tenant does not have a SPO license` error. For personal usage, login with a standard Microsoft Account (Outlook/Live/Hotmail).
```
