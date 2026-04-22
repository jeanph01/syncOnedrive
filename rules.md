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
