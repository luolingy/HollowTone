; ==================================================
#define AppVersion "1.0.0"
#define BuildNumber "50"
; ==================================================

#define FullVersion AppVersion + "." + BuildNumber

[Setup]
AppName=HollowTone
AppVersion={#AppVersion}
AppPublisher=Solsynth
AppPublisherURL=https://luolingy.qzz.io
AppSupportURL=https://www.luolingy.qzz.io/project-detail.html?slug=%E7%A9%BA%E8%B0%B7
AppUpdatesURL=https://github.com/luolingy/HollowTone/releases
AppCopyright=Copyright © 2026 luoling/Solsynth
VersionInfoVersion={#FullVersion}
UninstallDisplayName=HollowTone
UninstallDisplayIcon={app}\hollowtone.exe

DefaultDirName={commonpf}\HollowTone
UsePreviousAppDir=no

OutputDir=.\Installer
OutputBaseFilename=windows-x86_64-setup
SetupIconFile=.\assets\images\icon.ico

Compression=lzma2/ultra64
SolidCompression=yes
LZMAUseSeparateProcess=yes
LZMANumBlockThreads=4

ArchitecturesAllowed=x64compatible
PrivilegesRequired=admin

[Files]
Source: ".\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\HollowTone"; Filename: "{app}\hollowtone.exe";IconFilename: "{app}\hollowtone.exe"
Name: "{group}\{cm:UninstallProgram,HollowTone}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\HollowTone"; Filename: "{app}\hollowtone.exe"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Run]
Filename: "{app}\hollowtone.exe"; Description: "Launch HollowTone"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
Type: filesandordirs; Name: "{userappdata}\io.qzz.luolingy\hollowtone"
Type: files; Name: "{group}\HollowTone.lnk" ;
Type: files; Name: "{autodesktop}\HollowTone.lnk" ;
