# syncOnedrive

Solution PowerShell pour **indexer OneDrive via Microsoft Graph**, **détecter/traiter les doublons**, et **organiser automatiquement les médias** à partir d’un moteur de configuration externe.

> Objectif du projet : fournir une base **générique, partageable et industrialisable** pour une publication GitHub (sans règles métier codées en dur).

---

## 1) Ce que fait le projet

Le dépôt fournit 3 scripts principaux :

1. **`OneDrive_Sync.ps1`**
   - Construit/met à jour un cache OneDrive (`delta API`).
   - Compare les fichiers locaux avec le cloud par taille/hash.
   - Déplace les doublons locaux vers `_Doublons`.
2. **`OneDrive_PictureMovieOrganiser.ps1`**
   - Analyse le cache cloud.
   - Calcule un plan de renommage/routage (JSON) selon des règles.
   - Applique les déplacements/renommages OneDrive via Graph.
3. **`OneDrive_CloudCleaner.ps1`**
   - Regroupe les doublons cloud par hash.
   - Conserve la meilleure occurrence selon des règles de priorité.
   - Supprime les occurrences redondantes via Graph.

---

## 2) Architecture du code

### Entrypoints
- `OneDrive_Sync.ps1`
- `OneDrive_PictureMovieOrganiser.ps1`
- `OneDrive_CloudCleaner.ps1`

### Modules
- `modules/AppConfig.psm1` : lecture `config.ini` + `rules.json`.
- `modules/OneDriveTools.psm1` : logs, authentification Graph (device code), utilitaires communs.
- `modules/OneDriveOrganize.psm1` : classification média, routage, génération de noms.
- `modules/OneDriveCacheUtils.psm1` : chargement/réparation cache, planification, collisions.
- `modules/GpsTools.psm1` : résolution GPS (cache + Nominatim), normalisation localités.

### Données de travail
- `_cache/onedrive_cache.json` : index cloud.
- `_cache/plan.json` : plan des actions d’organisation.
- `_cache/processed_ids.log` : IDs déjà traités.
- `_cache/*.txt`, `_cache/*.csv` : logs/rapports opérationnels.

---

## 3) Configuration externe (nouveau modèle)

Le projet externalise désormais la configuration et les règles dans 2 fichiers :

- **`config.ini`** : paramètres d’exécution (client Graph, chemins, options globales, extensions autorisées).
- **`rules.json`** : logique métier (routing, patterns applicatifs, stopwords, scoring de suppression, mapping extension→catégorie).
- Les scripts n’acceptent plus les chemins de cache/log/rapport en paramètres : ces valeurs viennent exclusivement de `config.ini`.

### 3.1 `config.ini`
Sections principales :
- `[general]` : `verbose_mode`
- `[graph]` : `client_id`
- `[paths]` : fichiers cache/token/log/report
- `[organizer]` : `rename_marker`, `max_name_len`
- `[sync]` : `local_folder`
- `[extensions]` : liste `allowed` (CSV)

Le fichier est commenté (préfixes `;` / `#`) pour documenter chaque paramètre.

### 3.2 `rules.json`
Objets principaux :
- `extensionMap`
- `categoryRules`
- `routingRules`
- `namingRules`
- `cleanerRules`

`rules.json` n’autorise pas les commentaires natifs. Le projet utilise donc des champs `_comments` pour documenter la finalité des blocs.

> Recommandation : conservez les règles spécifiques à votre contexte **uniquement** dans `rules.json`.

---

## 4) Prérequis

- Windows + OneDrive.
- PowerShell 7 recommandé (Windows PowerShell 5.1 possible selon environnement).
- Une App Registration Azure AD / Microsoft Entra compatible Device Code.
- Accès Microsoft Graph pour les scopes nécessaires (au minimum lecture/écriture fichiers selon usage).

---

## 5) Mise en route rapide

### Étape A — Préparer la configuration
1. Copier/adapter `config.ini`.
2. Copier/adapter `rules.json`.
3. Vérifier :
   - `client_id`
   - chemins `_cache`
   - dossier local (`local_folder`)
   - règles de routage/suppression.

### Étape B — Générer/actualiser le cache cloud
```powershell
.\OneDrive_Sync.ps1 -Mode Online
```

### Étape C — Simuler l’organisation (sans exécution)
```powershell
.\OneDrive_PictureMovieOrganiser.ps1 -Execute:$false
```

### Étape D — Exécuter les déplacements OneDrive
```powershell
.\OneDrive_PictureMovieOrganiser.ps1 -Execute:$true
```

### Étape E — Nettoyer les doublons cloud (optionnel)
```powershell
.\OneDrive_CloudCleaner.ps1
```

---

## 6) Référence CLI

### `OneDrive_Sync.ps1`
Paramètres importants :
- `-Mode Online|Offline`
- `-ForceNewScan`
- `-ResetCache`
- `-ConfigFile`

Exemples :
```powershell
# Re-scan cloud complet
.\OneDrive_Sync.ps1 -Mode Online -ForceNewScan

# Mode offline depuis le cache existant
.\OneDrive_Sync.ps1 -Mode Offline
```

### `OneDrive_PictureMovieOrganiser.ps1`
Paramètres importants :
- `-Execute`
- `-ResetCache`
- `-ConfigFile`

Exemples :
```powershell
# Dry run de validation
.\OneDrive_PictureMovieOrganiser.ps1 -Execute:$false

# Exécution réelle
.\OneDrive_PictureMovieOrganiser.ps1 -Execute:$true
```

### `OneDrive_CloudCleaner.ps1`
Paramètres importants :
- `-ConfigFile`

Exemple :
```powershell
.\OneDrive_CloudCleaner.ps1
```

---

## 7) Flux de données recommandé

1. **Sync** (`OneDrive_Sync.ps1`) pour fiabiliser le cache cloud.
2. **Organisation** (`OneDrive_PictureMovieOrganiser.ps1`) en dry-run puis exécution.
3. **Cleaner cloud** (`OneDrive_CloudCleaner.ps1`) en option, si besoin de purge doublons côté OneDrive.

Ce séquencement réduit les erreurs et facilite les reprises (`plan.json`, `processed_ids.log`, hash cache).

---

## 8) Bonnes pratiques pour publication GitHub

- Ne pas committer de secrets/token (`_cache/graph_token.json` doit être ignoré).
- Fournir des exemples :
  - `config.ini.example`
  - `rules.json.example`
- Documenter vos règles métier par commentaire JSON (`README` + historique des versions).
- Tester chaque modification de `rules.json` en dry-run avant exécution réelle.
- Garder les logs `_cache` pour audit et rollback opérationnel.

---

## 9) Limites connues / points à améliorer

- Plusieurs scripts ont encore des messages/fonctions en français + conventions mixtes : une normalisation globale aidera à la maintenance open-source.
- Les tests automatisés (Pester) ne sont pas encore fournis.
- Un packaging module + release notes faciliterait les contributions externes.

---

## 10) Roadmap suggérée

- [ ] Ajouter `config.ini.example` et `rules.json.example`.
- [ ] Ajouter `.gitignore` strict (`_cache`, tokens, rapports).
- [ ] Ajouter tests Pester unitaires (par module).
- [ ] Ajouter workflow CI (lint PowerShell + tests).
- [ ] Ajouter changelog (`CHANGELOG.md`) et versioning semver.

---

## 11) Licence

Ajoutez une licence explicite avant publication officielle (MIT recommandé pour démarrer).

---

## 12) Contribution

Les PRs sont bienvenues si elles respectent :
- la séparation **code générique** vs **règles métier externes**,
- la compatibilité de l’existant (`config.ini` / `rules.json`),
- un test manuel documenté dans la PR.
