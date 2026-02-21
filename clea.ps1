# 1. Define the target paths
$oldDrive = "F:\"
$newBase  = "C:\Users\jeanp"

# 2. Fix User Shell Folders (Desktop, Documents, etc.)
$shellFoldersPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders"
$items = Get-ItemProperty -Path $shellFoldersPath

Write-Host "Checking Shell Folders..." -ForegroundColor Cyan
foreach ($prop in $items.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' }) {
    $name = $prop.Name
    $val = $prop.Value
    if ($null -ne $val -and $val -is [string] -and $val -like "*$oldDrive*") {
        $newVal = $val -replace [regex]::Escape($oldDrive), $newBase
        Set-ItemProperty -Path $shellFoldersPath -Name $name -Value $newVal
        Write-Host "Updated ${name}: ${val} -> ${newVal}" -ForegroundColor Yellow
    }
}

# 3. Fix Environment Variables (TEMP, TMP, HOME)
Write-Host "`nChecking Environment Variables..." -ForegroundColor Cyan
$envPath = "HKCU:\Environment"
$envItems = Get-ItemProperty -Path $envPath

foreach ($prop in $envItems.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' }) {
    $name = $prop.Name
    $val = $prop.Value
    if ($null -ne $val -and $val -is [string] -and $val -like "*$oldDrive*") {
        $newVal = $val -replace [regex]::Escape($oldDrive), $newBase
        Set-ItemProperty -Path $envPath -Name $name -Value $newVal
        Write-Host "Updated Env Var ${name}: ${val} -> ${newVal}" -ForegroundColor Yellow
    }
}

Write-Host "`nCleanup complete. PLEASE RESTART YOUR COMPUTER NOW." -ForegroundColor Green -BackgroundColor Black