; ==================================================
#define AppVersion "1.0.0"
#define BuildNumber "47"
; ==================================================

#define FullVersion AppVersion + "." + BuildNumber

[Setup]
AppName=GroovyBox
AppVersion={#AppVersion}
AppPublisher=Solsynth
AppPublisherURL=https://solsynth.dev
AppSupportURL=https://kb.solsynth.dev/zh/groovy-box
AppUpdatesURL=https://github.com/Solsynth/GroovyBox/releases
AppCopyright=Copyright © 2025 Solsynth
VersionInfoVersion={#FullVersion}
UninstallDisplayName=GroovyBox
UninstallDisplayIcon={app}\groovybox.exe

DefaultDirName={commonpf}\GroovyBox
UsePreviousAppDir=no

OutputDir=.\Installer
OutputBaseFilename=windows-x86_64-setup
SetupIconFile=.\assets\images\icon-rounded.ico

Compression=lzma2/ultra64
SolidCompression=yes
LZMAUseSeparateProcess=yes
LZMANumBlockThreads=4

ArchitecturesAllowed=x64compatible
PrivilegesRequired=admin

[Files]
Source: ".\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\GroovyBox"; Filename: "{app}\groovybox.exe";IconFilename: "{app}\groovybox.exe"
Name: "{group}\{cm:UninstallProgram,GroovyBox}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\GroovyBox"; Filename: "{app}\groovybox.exe"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Run]
Filename: "{app}\groovybox.exe"; Description: "Launch GroovyBox"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
Type: filesandordirs; Name: "{userappdata}\dev.solsynth\GroovyBox"
Type: filesandordirs; Name: "{userappdata}\io.qzz.luolingy\groovybox"
Type: files; Name: "{group}\GroovyBox.lnk" ;
Type: files; Name: "{autodesktop}\GroovyBox.lnk" ;
