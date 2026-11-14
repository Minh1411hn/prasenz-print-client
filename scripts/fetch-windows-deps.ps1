[CmdletBinding()]
param([string]$ManifestPath = "$PSScriptRoot/windows-dependencies.json", [string]$CacheDirectory = "$PSScriptRoot/../bin/windows")

$manifest = Get-Content -Raw $ManifestPath | ConvertFrom-Json
New-Item -ItemType Directory -Force -Path $CacheDirectory | Out-Null
foreach ($name in @('cloudflared', 'sumatraPdf')) {
  $dependency = $manifest.$name
  if ([string]::IsNullOrWhiteSpace($dependency.version) -or $dependency.version -eq 'REQUIRES_VALIDATION' -or [string]::IsNullOrWhiteSpace($dependency.url)) {
    throw "$name is not pinned. Update scripts/windows-dependencies.json with a validated official release before packaging."
  }
  $output = Join-Path $CacheDirectory $dependency.destination
  if (-not (Test-Path $output)) { Invoke-WebRequest -Uri $dependency.url -OutFile $output }
  if (-not [string]::IsNullOrWhiteSpace($dependency.sha256)) {
    $actual = (Get-FileHash -Algorithm SHA256 $output).Hash.ToLowerInvariant()
    if ($actual -ne $dependency.sha256.ToLowerInvariant()) { Remove-Item $output -Force; throw "SHA256 mismatch for $name" }
  } else { Write-Warning "$name has no SHA256. Validate the downloaded binary manually before release." }
}
