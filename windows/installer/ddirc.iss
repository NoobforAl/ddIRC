; ddIRC — Windows installer.
;
; Built with Inno Setup 6.3 or newer (`ISCC.exe`); `make installer` finds it and
; passes the version in. The output is a single `.exe` under `build\installer\`.
;
; The one decision this file is really making: it installs **for the person
; running it**, into `%LOCALAPPDATA%\Programs\ddIRC`, and never asks for
; administrator rights. Nothing ddIRC does needs them — it opens sockets and
; writes its own settings — and an installer that asks for elevation is asking
; to be trusted with the whole machine in order to put a chat client on it.
; That is the same choice the app makes everywhere else, so it is the one the
; installer makes too. `PrivilegesRequired=lowest` with no override allowed is
; what enforces it: there is no "install for all users" path to take by
; accident, and no UAC prompt on any of them.

#define AppName        "ddIRC"
#define AppPublisher   "ddIRC"
#define AppUrl         "https://github.com/NoobforAl/ddIRC"
#define AppExeName     "ddirc.exe"
#define BuildDir       "..\..\build\windows\x64\runner\Release"

; Overridden by `make installer`, which reads it from pubspec.yaml. The default
; only exists so running ISCC on this file by hand still produces something.
#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif

[Setup]
; Never change AppId: it is how Windows recognises an existing installation, so
; a new one turns every future release into a second copy alongside the first
; rather than an upgrade of it.
AppId={{6F3A2C41-9D5E-4B78-A0C6-1E8B4D2F7A93}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher={#AppPublisher}
AppPublisherURL={#AppUrl}
AppSupportURL={#AppUrl}/issues
AppUpdatesURL={#AppUrl}/releases
VersionInfoVersion={#AppVersion}

; Per-user, no elevation. See the note at the top of this file.
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes

; Flutter's Windows embedder does not support anything older, and there is no
; 32-bit build to fall back to.
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0

; GPL-3.0. Shown because the licence is the reason the source is available, not
; because a click on it is worth anything legally.
LicenseFile=..\..\LICENSE

SetupIconFile=..\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#AppExeName}
WizardStyle=modern
Compression=lzma2/max
SolidCompression=yes
OutputDir=..\..\build\installer
OutputBaseFilename=ddIRC-{#AppVersion}-windows-x64-setup

; An upgrade over a running copy would otherwise fail on a locked DLL and say
; so in terms nobody can act on. This asks Windows' Restart Manager to close it
; first; it is not reopened afterwards, because relaunching a chat client
; behind someone's back is not the installer's business.
CloseApplications=yes
RestartApplications=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
; The whole Release output: ddirc.exe, the Flutter engine, the Rust core in
; ddirc_bridge.dll, the plugin DLLs, and data\ with the assets and ICU. Listing
; them individually would mean a silent, working-on-this-machine-only installer
; the first time a plugin is added.
Source: "{#BuildDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExeName}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(AppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent

; Deliberately no [UninstallDelete]. Settings, saved networks and logs live
; under %APPDATA%\ddIRC and are the user's, not the installer's: uninstalling
; removes the program and leaves them alone, so reinstalling finds them where
; they were. Anyone who wants them gone can delete that folder, which is a
; thing they can see and decide about — unlike an uninstaller that quietly
; takes the logs with it.
