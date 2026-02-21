# 🚀 syncOnedrive (V10.4)
Outil PowerShell haute performance pour la détection de doublons locaux et le nettoyage de données via Microsoft Graph API.

## 🌟 Points Forts
- **Deep Scan Récursif** : Contourne les limitations d'indexation (plafond des 64k) en explorant chaque dossier.
- **Gestion intelligente du Token** : Refresh token chiffré via DPAPI stocké dans `%LOCALAPPDATA%`.
- **Zéro Pollution** : Désactivation des barres de progression système pour un affichage propre.
- **Sécurité** : Détection automatique et exclusion du Coffre-fort (Personal Vault).

## 📋 Prérequis
- **PowerShell 7+** recommandé (ou Windows PowerShell).
- **Compte Azure** : Une App Registration configurée (voir section Manifeste).

## ⚙️ Configuration
Éditez les variables au début du script `onedrivesync.ps1` :
- `$LocalFolder` : Dossier à nettoyer (ex: `D:\recup`).
- `$ClientId` : `176fc7bc-42c9-4a25-82b5-0ad584d3c061`.
- `$TenantId` : Utilisez `common` ou `consumers` pour les comptes personnels.

## 🚀 Utilisation

### Mode Standard (Nettoyage Direct)
Scan le Cloud, compare les Hash SHA1 et déplace les doublons locaux vers `_Doublons`.
```powershell
.\onedrivesync.ps1

Gemini a dit
C'est parfait. Ce document est très complet et reflète bien la structure professionnelle nécessaire pour un repo GitHub. J'ai fusionné tes informations techniques (manifeste, gestion du token, licences SPO) avec les instructions de fonctionnement du script V10.4 (Deep Scan) pour créer le README.md ultime.

Voici le contenu final à enregistrer :

Markdown
# 🚀 syncOnedrive (V10.4)
Outil PowerShell haute performance pour la détection de doublons locaux et le nettoyage de données via Microsoft Graph API.

## 🌟 Points Forts
- **Deep Scan Récursif** : Contourne les limitations d'indexation (plafond des 64k) en explorant chaque dossier.
- **Gestion intelligente du Token** : Refresh token chiffré via DPAPI stocké dans `%LOCALAPPDATA%`.
- **Zéro Pollution** : Désactivation des barres de progression système pour un affichage propre.
- **Sécurité** : Détection automatique et exclusion du Coffre-fort (Personal Vault).

## 📋 Prérequis
- **PowerShell 7+** recommandé (ou Windows PowerShell).
- **Compte Azure** : Une App Registration configurée (voir section Manifeste).

## ⚙️ Configuration
Éditez les variables au début du script `onedrivesync.ps1` :
- `$LocalFolder` : Dossier à nettoyer (ex: `D:\recup`).
- `$ClientId` : `176fc7bc-42c9-4a25-82b5-0ad584d3c061`.
- `$TenantId` : Utilisez `common` ou `consumers` pour les comptes personnels.

## 🚀 Utilisation

### Mode Standard (Nettoyage Direct)
Scan le Cloud, compare les Hash SHA1 et déplace les doublons locaux vers `_Doublons`.
```powershell
.\onedrivesync.ps1
Mode Audit (Génération de rapports)
Génère le cache JSON et les fichiers CSV de comparaison dans .\Reports.

PowerShell
.\onedrivesync.ps1 -Silent:$false
Mode Offline
Analyse le disque en utilisant le dernier cache local sans solliciter l'API.

PowerShell
.\onedrivesync.ps1 -Mode Offline
🔐 Authentification & Sécurité
Le script utilise le flux Device Code (URL + code).

Le token est sauvegardé dans : %LOCALAPPDATA%\syncOnedrive\token.json.

Réinitialisation :

PowerShell
Remove-Item "$env:LOCALAPPDATA\syncOnedrive\token.json" -ErrorAction SilentlyContinue
🛠️ Résolution des problèmes (SPO License)
Si vous obtenez l'erreur Tenant does not have a SPO license sur un compte pro :

PowerShell
# Attribution de licence via MSOnline
Connect-MsolService
Set-MsolUserLicense -UserPrincipalName user@domain.com -AddLicenses "votre_tenant:ENTERPRISEPACK"
📄 Extrait du Manifeste Azure
Configuration requise pour l'App Registration :

signInAudience : AzureADandPersonalMicrosoftAccount

allowPublicClient : true

Permissions Graph (Scopes) :

Files.Read.All (id: 10465720-29dd-4523-a11a-6a75c743c9d9)

offline_access (id: 7427b0d9-2fd0-4035-8740-a29e6ca3a3b7)

openid (id: e1fe6dd8-ba31-4d61-89e7-88639da4683d)

Note : Le cache onedrive_cache.json est mis à jour tous les 10 dossiers explorés pour garantir la reprise sur erreur.