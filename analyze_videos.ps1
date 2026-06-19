# analyze_videos.ps1
$csvPath = "c:\Users\jeanp\github\syncOnedrive\_cache\evaluation_report.csv"
$csv = Import-Csv -Path $csvPath -Delimiter ";"

$videoExts = @(".mp4", ".mov", ".avi", ".mkv", ".wmv", ".3gp", ".mpg", ".mpeg", ".m4v", ".flv")

$videos = $csv | Where-Object { $videoExts -contains $_.Extension.ToLower() }
Write-Host "Total video files found: $($videos.Count)"

# Let's see where they are currently located (ParentPath)
$byParent = $videos | Group-Object ParentPath | Select-Object Name, Count | Sort-Object Count -Descending
Write-Host "`n=== Video count by current parent folder ==="
$byParent | Format-Table -AutoSize

# Let's see how many videos are currently in a folder that doesn't contain "videos" or "vidéos"
$nonVideoFolderVideos = $videos | Where-Object { $_.ParentPath -notlike "*Videos*" -and $_.ParentPath -notlike "*Vidéos*" }
Write-Host "`n=== Videos in folders that do NOT contain 'Videos' or 'Vidéos': $($nonVideoFolderVideos.Count) ==="
$nonVideoFolderVideos | Select-Object Name, ParentPath, IsAlreadyProcessed, Status, RoutingAction -First 30 | Format-Table -AutoSize
