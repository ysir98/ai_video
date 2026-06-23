$files = @("run.ps1", "www\app.js", "config\appsettings.json")
foreach ($f in $files) {
    $full = Join-Path $PSScriptRoot $f
    $b = [System.IO.File]::ReadAllBytes($full)[0..2]
    $hasBom = ($b[0] -eq 239 -and $b[1] -eq 187 -and $b[2] -eq 191)
    Write-Host ("{0}: {1} {2} {3} -> {4}" -f $f, $b[0], $b[1], $b[2], (if ($hasBom) { "BOM" } else { "NO_BOM" }))
}
