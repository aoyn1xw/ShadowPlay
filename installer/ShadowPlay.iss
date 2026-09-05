#define MyAppExeName "ShadowPlay.exe"
#define PublishDir AddBackslash(SourcePath) + "..\publish\win-x64"
#define MyAppExe AddBackslash(PublishDir) + MyAppExeName
#define MyAppName GetStringFileInfo(MyAppExe, "ProductName")
#ifndef MyAppVersion
#define MyAppVersion GetVersionNumbersString(MyAppExe)
#endif
#define MyAppPublisher GetStringFileInfo(MyAppExe, "CompanyName")

[Setup]
AppId={{16C8742E-AD7A-4A83-AF71-EAA2F1405DB3}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL=https://github.com/aoyn1xw/ShadowPlay
AppSupportURL=https://github.com/aoyn1xw/ShadowPlay/issues
AppUpdatesURL=https://github.com/aoyn1xw/ShadowPlay/releases
DefaultDirName={autopf}\ShadowPlay
DefaultGroupName=ShadowPlay
DisableDirPage=yes
DisableProgramGroupPage=yes
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
CloseApplications=yes
RestartApplications=no
AppMutex=Local\ShadowPlay.SingleInstance.9f2c1a
UsePreviousAppDir=yes
Uninstallable=yes
CreateUninstallRegKey=yes
UninstallDisplayName={#MyAppName}
UninstallDisplayIcon={app}\{#MyAppExeName}
SetupIconFile=..\flutter\windows\runner\resources\app_icon.ico
OutputDir=..\artifacts\installer
OutputBaseFilename=ShadowPlay-Setup-{#MyAppVersion}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
VersionInfoCompany={#MyAppPublisher}
VersionInfoDescription={#MyAppName} Setup
VersionInfoProductName={#MyAppName}
VersionInfoProductVersion={#MyAppVersion}
VersionInfoVersion={#MyAppVersion}

[Files]
Source: "{#PublishDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Icons]
Name: "{group}\ShadowPlay"; Filename: "{app}\{#MyAppExeName}"; WorkingDir: "{app}"; IconFilename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\ShadowPlay"; Filename: "{app}\{#MyAppExeName}"; WorkingDir: "{app}"; IconFilename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent runasoriginaluser

[UninstallDelete]
Type: dirifempty; Name: "{app}"

[Code]
var
  RemoveAppData: Boolean;

function InitializeUninstall(): Boolean;
begin
  RemoveAppData := False;

  if not UninstallSilent then
    RemoveAppData := MsgBox(
      'Remove ShadowPlay application data too?' + #13#10 + #13#10 +
      'Choose Yes to delete settings, pairing information, logs, and cached previews from:' + #13#10 +
      ExpandConstant('{localappdata}\ShadowPlay') + #13#10 + #13#10 +
      'Your recordings and downloaded clips will not be deleted.',
      mbConfirmation, MB_YESNO) = IDYES;

  Result := True;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if (CurUninstallStep = usPostUninstall) and RemoveAppData then
    DelTree(ExpandConstant('{localappdata}\ShadowPlay'), True, True, True);
end;
