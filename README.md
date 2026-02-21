# syncOnedrive
pour synchro OneDrive efficiente

```markdown
# syncOnedrive
Outil PowerShell pour détecter les doublons locaux vs OneDrive (utilise Microsoft Graph).

## Prérequis
- PowerShell 7+ ou Windows PowerShell
- `az` (Azure CLI) installé et connecté si vous gérez des App registrations ou licences

## Configuration
Éditez `onedrivesync.ps1` et ajustez :
- `LocalFolder` : dossier local à scanner
- `ClientId` : Application (client) ID de l'app enregistrée dans Azure AD
- `TenantId` : soit l'ID de tenant (GUID) pour un compte pro/scolaire, soit `consumers` pour comptes Microsoft personnels

Exemple :
```powershell
$LocalFolder = "D:\recup\test"
$ClientId = "176fc7bc-42c9-4a25-82b5-0ad584d3c061"
$TenantId = "e3f75fb4-c0eb-4d7d-a335-65e4e3e32c76"
```

## Authentification (comportement du script)
- Le script utilise le flux device-code OAuth2 (affiche une URL + code à saisir).
- Il sauvegarde un refresh token chiffré dans `%LOCALAPPDATA%\syncOnedrive\token.json` pour éviter de redemander l'authentification à chaque exécution.
- Pour forcer une nouvelle authentification, supprimez le cache :
```powershell
Remove-Item "$env:LOCALAPPDATA\syncOnedrive\token.json" -ErrorAction SilentlyContinue
```

## Scénarios courants & résolution
- Si vous voulez utiliser un compte Microsoft personnel (OneDrive Family)
	- Mettez `TenantId = 'consumers'` et utilisez une App registration qui accepte les comptes personnels (`signInAudience=AzureADandPersonalMicrosoftAccount`) et a `Allow public client flows` activé.
	- Ouvrez une fenêtre de navigateur privée/incognito pour vous assurer de choisir le compte personnel lors du device-code.

- Si le script renvoie `Tenant does not have a SPO license`
	- Cela signifie que l'utilisateur dans le tenant organisationnel n'a pas de licence SharePoint/OneDrive for Business.
	- Solutions : attribuer une licence contenant SharePoint/OneDrive à l'utilisateur ou utiliser un compte personnel.
	- Pour attribuer une licence en CLI (admin) :
		```powershell
		Install-Module MSOnline -Force -Scope CurrentUser
		Connect-MsolService
		Get-MsolAccountSku
		Set-MsolUserLicense -UserPrincipalName user@domain.com -AddLicenses "<Tenant:SKU>"
		```

## Créer/Configurer l'App (si besoin)
- Création rapide via Azure CLI + Graph (exemples dans le repo session) :
	- Créer l'app qui accepte comptes personnels:
		```powershell
		# Create application (Graph REST or portal)
		# Ensure signInAudience=AzureADandPersonalMicrosoftAccount and publicClient.allowPublicClient=true
		```
	- Ajouter les permissions déléguées Microsoft Graph : `Files.Read`, `offline_access`, `openid` et appliquer l'admin-consent si vous voulez éviter l'étape de consent utilisateur.

## Lancer
```powershell
.\onedrivesync.ps1
```

## Notes de sécurité
- Le refresh token est chiffré avec DPAPI et lié au compte utilisateur système.
- Ne partagez pas `%LOCALAPPDATA%\syncOnedrive\token.json`.

---
Si vous voulez que je génère des commandes exactes pour créer l'app, ajouter les permissions et appliquer l'admin-consent, dites‑le — je peux automatiser via Azure CLI/Graph.
```
