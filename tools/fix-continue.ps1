<#
.SYNOPSIS
    Diagnostic complet de l'extension Continue pour VS Code.
#>

$continuePath = "$env:USERPROFILE\.continue"
$configYaml = Join-Path $continuePath "config.yaml"
$settingsJson = "$env:APPDATA\Code\User\settings.json"
$ollamaUrl = "http://127.0.0.1:11434/api/tags"

Write-Host "=== Diagnostic de l'extension Continue ===" -ForegroundColor Cyan

# 1. Vérification d'Ollama
Write-Host "`n[1/4] Vérification du serveur Ollama..." -ForegroundColor Yellow
try {
    $response = Invoke-RestMethod -Uri $ollamaUrl -Method Get -ErrorAction Stop
    $model = $response.models | Where-Object { $_.name -like "*deepseek-coder:1.3b*" }
    if ($model) {
        Write-Host "[OK] Ollama est actif et le modèle deepseek-coder:1.3b est présent." -ForegroundColor Green
    } else {
        Write-Host "[ERREUR] Modèle deepseek-coder:1.3b non trouvé dans Ollama." -ForegroundColor Red
    }
} catch {
    Write-Host "[ERREUR] Impossible de contacter Ollama sur le port 11434." -ForegroundColor Red
}

# 2. Analyse du fichier config.yaml
Write-Host "`n[2/4] Analyse de config.yaml..." -ForegroundColor Yellow
if (Test-Path $configYaml) {
    $yaml = Get-Content $configYaml -Raw
    if ($yaml -match "tabAutocompleteModel:") {
        Write-Host "[OK] La clé 'tabAutocompleteModel' est présente." -ForegroundColor Green
    } elseif ($yaml -match "autocompleteModel:") {
        Write-Host "[INFO] Utilisation de 'autocompleteModel'. 'tabAutocompleteModel' est recommandé." -ForegroundColor Gray
    } else {
        Write-Host "[ATTENTION] Aucune section d'autocomplétion trouvée dans le YAML." -ForegroundColor Yellow
    }
} else {
    Write-Host "[ERREUR] Fichier config.yaml introuvable." -ForegroundColor Red
}

# 3. Analyse des paramètres VS Code (settings.json)
Write-Host "`n[3/4] Analyse de settings.json..." -ForegroundColor Yellow
if (Test-Path $settingsJson) {
    $settings = Get-Content $settingsJson -Raw | ConvertFrom-Json
    
    $checks = @(
        @{ Name = "Inline Suggest Enabled"; Val = $settings."editor.inlineSuggest.enabled"; Expected = $true },
        @{ Name = "PS Suppress Completions"; Val = $settings."powershell.integratedConsole.suppressInlineCompletions"; Expected = $false },
        @{ Name = "Continue Enabled"; Val = $settings."continue.enableTabAutocomplete"; Expected = $true }
    )

    foreach ($c in $checks) {
        if ($c.Val -eq $c.Expected) {
            Write-Host "[OK] $($c.Name) est bien configuré ($($c.Val))." -ForegroundColor Green
        } else {
            Write-Host "[ERREUR] $($c.Name) est à $($c.Val), devrait être $($c.Expected)." -ForegroundColor Red
        }
    }
}

# 4. Test de latence réseau locale
Write-Host "`n[4/4] Test de latence (Debounce Check)..." -ForegroundColor Yellow
$measure = Measure-Command { 
    try { $null = Invoke-WebRequest -Uri "http://127.0.0.1:11434" -TimeoutSec 1 } catch {} 
}
Write-Host "[INFO] Temps de réponse local : $($measure.TotalMilliseconds)ms" -ForegroundColor Gray
if ($settings."continue.autocomplete.debounceDelay" -lt $measure.TotalMilliseconds) {
    Write-Host "[ATTENTION] Votre 'debounceDelay' (50ms) est peut-être trop bas pour votre temps de réponse local." -ForegroundColor Yellow
}

Write-Host "`n=== Fin du Diagnostic ===" -ForegroundColor Cyan
Write-Host "CONSEIL : Si tout est [OK] mais que rien ne s'affiche, appuyez sur ALT + \ dans VS Code." -ForegroundColor White