$ErrorActionPreference = "Continue"

# ================================
# 🔑 CONFIG (clés en clair assumées)
# ================================
$OPENAI_API_KEY = "sk-proj-i_nTsOF0ljeqcwP-8M7C4AvVovWTRzG5KqvsgA8q9k_TbGZxnbgwy5fLcn5UHQtT_KS4d7RuLzT3BlbkFJZQD08VnSpQdlovidII"
$GEMINI_API_KEY = "AIzaSyDRgTx_xCOJPNecwVY-bRfEtGtYyEnfn2w"

$continuePath = "$env:USERPROFILE\.continue"
$vscodeStorage = "$env:APPDATA\Code\User\globalStorage"
$vscodeLogs = "$env:APPDATA\Code\logs"

$logFile = Join-Path $env:TEMP "continue_full_reset_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
Start-Transcript -Path $logFile

Write-Host "=== RESET COMPLET CONTINUE + DIAGNOSTIC ===" -ForegroundColor Cyan

# =====================================================
# 1) STOP VS CODE (sinon fichiers lockés)
# =====================================================
Write-Host "`n[1] Fermeture VS Code..." -ForegroundColor Yellow
Get-Process Code -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 2
Write-Host "[OK] VS Code stoppé"

# =====================================================
# 2) CLEAN TOTAL
# =====================================================
Write-Host "`n[2] Nettoyage complet..." -ForegroundColor Yellow

# Supprime .continue
if (Test-Path $continuePath) {
    Remove-Item $continuePath -Recurse -Force
    Write-Host "[OK] .continue supprimé"
}

# Supprime cache Continue dans VS Code
Get-ChildItem $vscodeStorage -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match "continue" } |
    ForEach-Object {
        Remove-Item $_.FullName -Recurse -Force
        Write-Host "[OK] Cache supprimé: $($_.Name)"
    }

# Logs Continue
Get-ChildItem $vscodeLogs -Recurse -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -match "continue" } |
    ForEach-Object {
        Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
    }

Write-Host "[OK] Nettoyage terminé"

# =====================================================
# 3) RECRÉATION CONFIG PROPRE
# =====================================================
Write-Host "`n[3] Création config.yaml..." -ForegroundColor Yellow

New-Item -ItemType Directory -Force -Path $continuePath | Out-Null

$yaml = @"
models:
  - title: "GPT-4o"
    provider: "openai"
    model: "gpt-4o"
    apiKey: "$OPENAI_API_KEY"

  - title: "GPT-4o mini"
    provider: "openai"
    model: "gpt-4o-mini"
    apiKey: "$OPENAI_API_KEY"

  - title: "Gemini 1.5 Pro"
    provider: "gemini"
    model: "gemini-1.5-pro"
    apiKey: "$GEMINI_API_KEY"

  - title: "DeepSeek local"
    provider: "ollama"
    model: "deepseek-coder:1.3b"

tabAutocompleteModel:
  title: "DeepSeek local"
  provider: "ollama"
  model: "deepseek-coder:1.3b"

allowAnonymousTelemetry: false
"@

$yamlFile = Join-Path $continuePath "config.yaml"
Set-Content -Path $yamlFile -Value $yaml -Encoding utf8

Write-Host "[OK] config.yaml recréé"

# =====================================================
# 4) VALIDATION YAML
# =====================================================
Write-Host "`n[4] Validation YAML..." -ForegroundColor Yellow

$content = Get-Content $yamlFile -Raw

if ($content -match "`t") {
    Write-Host "[X] YAML contient des TABS" -ForegroundColor Red
} else {
    Write-Host "[OK] YAML valide (pas de tabs)"
}

# =====================================================
# 5) TEST OPENAI
# =====================================================
Write-Host "`n[5] Test OpenAI..." -ForegroundColor Yellow

try {
    $headers = @{
        "Authorization" = "Bearer $OPENAI_API_KEY"
        "Content-Type"  = "application/json"
    }

    $body = @{
        model = "gpt-4o-mini"
        messages = @(@{ role = "user"; content = "ping" })
        max_tokens = 5
    } | ConvertTo-Json -Depth 5

    Invoke-RestMethod -Uri "https://api.openai.com/v1/chat/completions" `
        -Method Post -Headers $headers -Body $body | Out-Null

    Write-Host "[OK] OpenAI fonctionne" -ForegroundColor Green
}
catch {
    Write-Host "[X] OpenAI erreur" -ForegroundColor Red
    Write-Host $_.Exception.Message
}

# =====================================================
# 6) TEST GEMINI
# =====================================================
Write-Host "`n[6] Test Gemini..." -ForegroundColor Yellow

try {
    $body = @{
        contents = @(
            @{ parts = @(@{ text = "ping" }) }
        )
    } | ConvertTo-Json -Depth 5

    Invoke-RestMethod `
        -Uri "https://generativelanguage.googleapis.com/v1/models/gemini-1.5-pro:generateContent?key=$GEMINI_API_KEY" `
        -Method Post -Body $body -ContentType "application/json" | Out-Null

    Write-Host "[OK] Gemini fonctionne" -ForegroundColor Green
}
catch {
    Write-Host "[X] Gemini erreur" -ForegroundColor Red
}

# =====================================================
# 7) TEST OLLAMA
# =====================================================
Write-Host "`n[7] Test Ollama..." -ForegroundColor Yellow

$ollama = Test-NetConnection 127.0.0.1 -Port 11434 -InformationLevel Quiet

if ($ollama) {
    Write-Host "[OK] Ollama actif"
} else {
    Write-Host "[!] Ollama non lancé (optionnel)"
}

# =====================================================
# 8) VS CODE EXTENSION
# =====================================================
Write-Host "`n[8] Vérification extension Continue..." -ForegroundColor Yellow

code --list-extensions | Select-String "continue"

# =====================================================
# 9) FIN
# =====================================================
Write-Host "`n=== TERMINÉ ===" -ForegroundColor Cyan
Write-Host "Relance VS Code maintenant."
Write-Host "Puis ouvre: Output > Continue"

Write-Host "`nLog complet: $logFile"

Stop-Transcript