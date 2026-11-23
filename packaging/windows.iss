; 在 Windows 构建 apps.spec 后，用 Inno Setup 6 编译本文件。
[Setup]
AppId={{EED5A253-FE88-48CA-BBD3-E994F2EFA011}
AppName=语音三屏集控
AppVersion=0.1.0
DefaultDirName={localappdata}\Programs\VoiceScreenControl
DefaultGroupName=语音三屏集控
PrivilegesRequired=lowest
OutputDir=..\dist
OutputBaseFilename=VoiceScreenControl-Setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
LicenseFile=..\LICENSE

[Types]
Name: "both"; Description: "集控端和客户端"
Name: "controller"; Description: "仅集控端"
Name: "client"; Description: "仅客户端"
Name: "custom"; Description: "自定义"; Flags: iscustom

[Components]
Name: "controller"; Description: "语音集控端"; Types: both controller
Name: "client"; Description: "三屏客户端"; Types: both client

[Files]
Source: "..\dist\VoiceController\*"; DestDir: "{app}\VoiceController"; Flags: ignoreversion recursesubdirs createallsubdirs; Components: controller
Source: "..\dist\ScreenClient\*"; DestDir: "{app}\ScreenClient"; Flags: ignoreversion recursesubdirs createallsubdirs; Components: client

[Icons]
Name: "{group}\语音集控端"; Filename: "{app}\VoiceController\VoiceController.exe"; Components: controller
Name: "{group}\三屏客户端"; Filename: "{app}\ScreenClient\ScreenClient.exe"; Components: client

; 用户配置及 Chrome 独立配置保存在应用数据目录，卸载时不删除。
