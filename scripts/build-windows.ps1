[CmdletBinding()]
param([switch]$SkipDependencies)

$root = Resolve-Path "$PSScriptRoot/.."
if (-not $SkipDependencies) { & "$PSScriptRoot/fetch-windows-deps.ps1" }
dotnet run --project "$root/src-windows/PrasenzPrinter.Core.Tests/PrasenzPrinter.Core.Tests.csproj" -c Release
dotnet run --project "$root/src-windows/PrasenzPrinter.Windows.Tests/PrasenzPrinter.Windows.Tests.csproj" -c Release
$publish = "$root/dist/windows/win-x64"
dotnet publish "$root/src-windows/PrasenzPrinter.Windows/PrasenzPrinter.Windows.csproj" -c Release -r win-x64 --self-contained true -p:PublishTrimmed=false -o $publish
New-Item -ItemType Directory -Force -Path "$publish/tools" | Out-Null
Copy-Item "$root/bin/windows/cloudflared.exe", "$publish/tools/cloudflared.exe" -Force
Copy-Item "$root/bin/windows/SumatraPDF.exe", "$publish/tools/SumatraPDF.exe" -Force
Copy-Item "$root/packaging/windows/THIRD-PARTY-NOTICES.txt", $publish -Force
Compress-Archive -Path "$publish/*" -DestinationPath "$root/dist/PrasenzPrinter-windows-win-x64.zip" -Force
