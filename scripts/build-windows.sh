#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
dotnet run --project "$root/src-windows/PrasenzPrinter.Core.Tests/PrasenzPrinter.Core.Tests.csproj" -c Release
dotnet publish "$root/src-windows/PrasenzPrinter.Windows/PrasenzPrinter.Windows.csproj" -c Release -r win-x64 --self-contained true -p:EnableWindowsTargeting=true -p:PublishTrimmed=false -o "$root/dist/windows/win-x64"
echo "Dependencies are not staged: validate and pin scripts/windows-dependencies.json, then run scripts/build-windows.ps1 on Windows."
