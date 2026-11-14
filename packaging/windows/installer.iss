; Build only after ZIP acceptance and dependency/license validation.
#define MyAppName "PrasenzPrinter"
#define MyAppVersion "0.0.0"
#define MyAppPublisher "Prasenz"
#define MyAppExeName "PrasenzPrinter.exe"

[Setup]
AppId={{C9B0C585-98D5-41D4-AE0E-76AB1EB0E1E7}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={localappdata}\Programs\{#MyAppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
OutputDir=..\..\dist\windows

[Files]
Source: "..\..\dist\windows\win-x64\*"; DestDir: "{app}"; Flags: recursesubdirs ignoreversion

[Icons]
Name: "{autostartup}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: autostart

[Tasks]
Name: "autostart"; Description: "Start PrasenzPrinter when I sign in"; Flags: unchecked

[UninstallDelete]
Type: filesandordirs; Name: "{localappdata}\PrasenzPrinter\jobs"
