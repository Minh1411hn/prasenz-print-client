# PrasenzPrinter for Windows

The Windows client is a per-user WinForms tray application for Windows 10 22H2 x64 and Windows 11 x64. It hosts the same local HTTP contract as macOS, prints with the packaged SumatraPDF executable, and optionally runs the packaged `cloudflared.exe`.

## Build and package

Install the .NET SDK pinned by `src-windows/global.json`. On Windows, first validate each dependency on the target Windows 10 machine, then fill in the official version, URL, and optionally a vendor-verified SHA256 in `scripts/windows-dependencies.json`. The manifest is intentionally invalid until that action is completed.

Run `scripts/build-windows.ps1`. It fetches the validated tools, runs the no-package executable test projects, publishes a self-contained `win-x64` application, stages tools under `tools/`, and creates `dist/PrasenzPrinter-windows-win-x64.zip`.

On macOS, `scripts/build-windows.sh` runs core checks and cross-publishes only. It deliberately does not download or package unvalidated Windows executables. Cross-build cannot run WinForms or actual Windows printer tests.

## Install and configure

Extract the ZIP to a stable per-user directory and run `PrasenzPrinter.exe`. The first run opens Settings. Configure the Cloudflare token, port (default `37588`), optional New Relic key, and autostart. Settings, logs, and temporary PDFs are under `%LOCALAPPDATA%\PrasenzPrinter`.

Cloudflare must route its public hostname to the configured local port. Changing the app port does not update the Cloudflare Dashboard. The client binds IPv4/IPv6 loopback by default; **Allow direct LAN access** is an opt-in network exposure and may require an inbound firewall rule.

## API and options

See `contracts/http-v1/README.md` for response shapes and fixtures. Windows maps fit, no-scale, A4/Letter, copies, and duplex settings to SumatraPDF. `custom_*` media and zero-margin requests are accepted but are not certified until manually tested with the selected SumatraPDF binary, printer driver, A4 printer, and 80 mm receipt printer. Do not claim compatibility for these combinations before that acceptance.

## Troubleshooting and removal

Use the tray menu to open settings and inspect recent logs. Persistent logs are in `%LOCALAPPDATA%\PrasenzPrinter\logs\prasenz-printer.log`; `p-req-id` is retained with print and error events. A successful `POST /print` only confirms enqueue, so inspect logs for later SumatraPDF failures.

Exit from the tray menu before replacing files. The Inno Setup scaffold is per-user and removes temporary jobs on uninstall; settings/log retention must be chosen and tested during installer acceptance. Remove `%LOCALAPPDATA%\PrasenzPrinter` manually only when configuration and logs should be discarded.
