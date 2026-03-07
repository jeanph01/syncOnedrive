Write-Host "--- Diagnostic du modèle Ollama pour Continue ---" -ForegroundColor Cyan

# 1. Vérifier si le modèle est réellement installé
$ModelName = "deepseek-coder:6.7b-instruct-q4_K_M"
$InstalledModels = ollama list

if ($InstalledModels -match $ModelName) {
    Write-Host "[OK] Le modèle '$ModelName' est bien présent dans Ollama." -ForegroundColor Green
    
    # 2. Vérifier si le service tourne
    $OllamaProcess = Get-Process -Name "ollama" -ErrorAction SilentlyContinue
    if ($OllamaProcess) {
        Write-Host "[OK] Le service Ollama est actif." -ForegroundColor Green
    } else {
        Write-Host "[!] Attention : Le service Ollama ne semble pas tourner." -ForegroundColor Yellow
    }

    # 3. Générer la ligne correcte pour config.yaml
    Write-Host "`n--- Copie cette ligne pour ton fichier config.yaml ---" -ForegroundColor Cyan
    Write-Host "- uses: ollama/deepseek-coder:6.7b-instruct-q4_K_M" -ForegroundColor White
} else {
    Write-Host "[!] ERREUR : Le modèle '$ModelName' est introuvable." -ForegroundColor Red
    Write-Host "Vérifie le nom exact avec : ollama list" -ForegroundColor Gray
}