!ifndef APP_VERSION
  !define APP_VERSION "0.0.0.0"
!endif

!ifndef PAYLOAD_DIR
  !error "PAYLOAD_DIR must be defined by the build script"
!endif

!ifndef OUTPUT_EXE
  !define OUTPUT_EXE "CodexSetup-x64-${APP_VERSION}.exe"
!endif

!define APP_NAME "Codex"
!define APP_PUBLISHER "OpenAI"
!define APP_REGKEY "Software\OpenAI\Codex"
!define APP_UNINSTALL_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\Codex"
!define APP_PROTOCOL_KEY "Software\Classes\codex"

Unicode true
SetCompress off
RequestExecutionLevel admin
InstallDir "$PROGRAMFILES64\Codex"
InstallDirRegKey HKLM "${APP_REGKEY}" "InstallDir"
OutFile "${OUTPUT_EXE}"
Name "${APP_NAME}"
BrandingText "${APP_NAME}"

VIProductVersion "${APP_VERSION}"
VIAddVersionKey "ProductName" "${APP_NAME}"
VIAddVersionKey "CompanyName" "${APP_PUBLISHER}"
VIAddVersionKey "FileDescription" "${APP_NAME} installer"
VIAddVersionKey "FileVersion" "${APP_VERSION}"
VIAddVersionKey "ProductVersion" "${APP_VERSION}"
VIAddVersionKey "LegalCopyright" "${APP_PUBLISHER}"

!include LogicLib.nsh
!include MUI2.nsh
!include x64.nsh

!define MUI_ABORTWARNING
!define MUI_ICON "${PAYLOAD_DIR}\resources\icon.ico"
!define MUI_UNICON "${PAYLOAD_DIR}\resources\icon.ico"

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "English"

Function .onInit
  SetShellVarContext all
  ${IfNot} ${RunningX64}
    MessageBox MB_ICONSTOP "Codex requires 64-bit Windows."
    Abort
  ${EndIf}
FunctionEnd

Section "Codex" SEC01
  SetShellVarContext all
  SetRegView 64

  SetOutPath "$INSTDIR"
  File /r "${PAYLOAD_DIR}\*.*"

  CreateDirectory "$SMPROGRAMS\Codex"
  CreateShortCut "$SMPROGRAMS\Codex\Codex.lnk" "$INSTDIR\Codex.exe" "" "$INSTDIR\resources\icon.ico"

  WriteRegStr HKLM "${APP_REGKEY}" "InstallDir" "$INSTDIR"
  WriteRegStr HKLM "${APP_REGKEY}" "Version" "${APP_VERSION}"

  WriteRegStr HKLM "Software\Classes\codex" "" "URL:Codex Protocol"
  WriteRegStr HKLM "Software\Classes\codex" "URL Protocol" ""
  WriteRegStr HKLM "Software\Classes\codex\DefaultIcon" "" "$INSTDIR\resources\icon.ico"
  WriteRegStr HKLM "Software\Classes\codex\shell\open\command" "" '"$INSTDIR\Codex.exe" "%1"'

  WriteUninstaller "$INSTDIR\Uninstall.exe"

  WriteRegStr HKLM "${APP_UNINSTALL_KEY}" "DisplayName" "${APP_NAME}"
  WriteRegStr HKLM "${APP_UNINSTALL_KEY}" "DisplayVersion" "${APP_VERSION}"
  WriteRegStr HKLM "${APP_UNINSTALL_KEY}" "Publisher" "${APP_PUBLISHER}"
  WriteRegStr HKLM "${APP_UNINSTALL_KEY}" "InstallLocation" "$INSTDIR"
  WriteRegStr HKLM "${APP_UNINSTALL_KEY}" "DisplayIcon" "$INSTDIR\resources\icon.ico"
  WriteRegStr HKLM "${APP_UNINSTALL_KEY}" "UninstallString" '"$INSTDIR\Uninstall.exe"'
  WriteRegStr HKLM "${APP_UNINSTALL_KEY}" "QuietUninstallString" '"$INSTDIR\Uninstall.exe" /S'
  WriteRegDWORD HKLM "${APP_UNINSTALL_KEY}" "NoModify" 1
  WriteRegDWORD HKLM "${APP_UNINSTALL_KEY}" "NoRepair" 1
SectionEnd

Section "Uninstall"
  SetShellVarContext all
  SetRegView 64

  Delete "$SMPROGRAMS\Codex\Codex.lnk"
  RMDir "$SMPROGRAMS\Codex"

  DeleteRegKey HKLM "${APP_PROTOCOL_KEY}"
  DeleteRegKey HKLM "${APP_UNINSTALL_KEY}"
  DeleteRegKey HKLM "${APP_REGKEY}"

  RMDir /r "$INSTDIR"
SectionEnd
