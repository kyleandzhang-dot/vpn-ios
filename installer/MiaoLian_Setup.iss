
; MiaoLian（喵脸）Windows 安装程序
; Inno Setup Configuration

#define MyAppName "喵脸"
#define MyAppVersion "1.0.1"
#define MyAppPublisher "youran"
#define MyAppExeName "MiaoLian.exe"
#define MyAppSourceDir "U:\project\vpn-ios\build\windows\x64\runner\Release"

#define DoubleAmp(Value) StringChange(Value, "&", "&&")

[Setup]
; 保持原 AppId，确保后续版本能够识别为同一个软件
AppId={{E7C888F6-4619-4AC3-A043-46AA295B5F0D}

; 软件信息
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}

; 安装路径：保持英文目录，避免升级时路径变化
DefaultDirName={autopf}\MiaoLian

; 卸载程序显示图标
UninstallDisplayIcon={app}\{#MyAppExeName}

; Windows 64 位支持
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible

; 安装权限：仅当前用户，无需管理员权限
PrivilegesRequired=lowest

; 不显示开始菜单文件夹选择页面
DisableProgramGroupPage=yes

; 安装包输出位置
OutputDir=U:\project\vpn-ios\installer

; 安装包名称自动跟随版本号
OutputBaseFilename=MiaoLian_Setup_v{#MyAppVersion}

; 安装程序图标
SetupIconFile=U:\project\vpn-ios\windows\runner\resources\app_icon.ico

; 压缩设置
Compression=lzma2
SolidCompression=yes

; 现代安装向导界面
WizardStyle=modern dynamic

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "chinesesimplified"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"

[Tasks]
; 允许用户选择是否创建桌面快捷方式
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
; 包含 Flutter Release 中的所有文件及子文件夹
Source: "{#MyAppSourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
; 开始菜单快捷方式
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"

; 桌面快捷方式
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
; 安装完成后允许启动程序
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#DoubleAmp(MyAppName)}}"; Flags: nowait postinstall skipifsilent
