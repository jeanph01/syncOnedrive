$logFile = "continue-traffic-debug.log"
Write-Host "--- Surveillance active ---" -ForegroundColor Cyan
Write-Host "Le log est généré ici : $(Join-Path (Get-Location) $logFile)" -ForegroundColor Yellow
Write-Host "Appuyez sur Ctrl+C pour arrêter le script une fois le test fini."

# Entête du log
"--- Début du log : $(Get-Date) ---" | Out-File -FilePath $logFile -Append

while($true) {
    # On cherche les connexions établies ou en attente vers le port d'Ollama
    $connections = Get-NetTCPConnection -RemotePort 11434 -ErrorAction SilentlyContinue | 
                   Select-Object @{N='Timestamp';E={Get-Date -Format "HH:mm:ss"}}, 
                                 LocalAddress, State, 
                                 @{Name="Process";Expression={(Get-Process -Id $_.OwningProcess).ProcessName}}
    
    if ($connections) {
        foreach ($conn in $connections) {
            $logEntry = "[$($conn.Timestamp)] Process: $($conn.Process) | State: $($conn.State)"
            $logEntry | Out-File -FilePath $logFile -Append
            Write-Host $logEntry -ForegroundColor Green
        }
    }
    Start-Sleep -Milliseconds 200 # Fréquence rapide pour ne rien rater
}