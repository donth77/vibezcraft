; VibezCraft Windows installer (NSIS)
; Compiled in CI via: makensis -DAPP_VERSION=1.0.0 installer/windows.nsi
; Assumes the Godot export output (VibezCraft.exe, VibezCraft.console.exe,
; VibezCraft.pck) is in the same directory as the .nsi file at compile
; time; the CI step copies them before invoking makensis.

!include "MUI2.nsh"
!include "x64.nsh"

!ifndef APP_VERSION
  !define APP_VERSION "0.0.0"
!endif

Name "VibezCraft"
OutFile "VibezCraft-Windows-Setup.exe"
InstallDir "$PROGRAMFILES64\VibezCraft"
InstallDirRegKey HKLM "Software\VibezCraft" "InstallDir"
RequestExecutionLevel admin

VIProductVersion "${APP_VERSION}.0"
VIAddVersionKey "ProductName" "VibezCraft"
VIAddVersionKey "FileDescription" "A clone of MC Alpha"
VIAddVersionKey "FileVersion" "${APP_VERSION}"
VIAddVersionKey "ProductVersion" "${APP_VERSION}"
VIAddVersionKey "CompanyName" "donth77"

!define MUI_ICON "app_icon.ico"
!define MUI_UNICON "app_icon.ico"
!define MUI_ABORTWARNING

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!define MUI_FINISHPAGE_RUN "$INSTDIR\VibezCraft.exe"
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

!insertmacro MUI_LANGUAGE "English"

Section "VibezCraft (required)" SecMain
  SectionIn RO
  SetOutPath "$INSTDIR"
  File "VibezCraft.exe"
  File "VibezCraft.console.exe"
  File "VibezCraft.pck"

  CreateDirectory "$SMPROGRAMS\VibezCraft"
  CreateShortcut "$SMPROGRAMS\VibezCraft\VibezCraft.lnk" "$INSTDIR\VibezCraft.exe"
  CreateShortcut "$SMPROGRAMS\VibezCraft\Uninstall VibezCraft.lnk" "$INSTDIR\Uninstall.exe"
  CreateShortcut "$DESKTOP\VibezCraft.lnk" "$INSTDIR\VibezCraft.exe"

  WriteUninstaller "$INSTDIR\Uninstall.exe"

  WriteRegStr HKLM "Software\VibezCraft" "InstallDir" "$INSTDIR"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\VibezCraft" \
    "DisplayName" "VibezCraft"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\VibezCraft" \
    "UninstallString" '"$INSTDIR\Uninstall.exe"'
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\VibezCraft" \
    "DisplayIcon" "$INSTDIR\VibezCraft.exe"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\VibezCraft" \
    "DisplayVersion" "${APP_VERSION}"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\VibezCraft" \
    "Publisher" "donth77"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\VibezCraft" \
    "URLInfoAbout" "https://github.com/donth77/vibezcraft"
  WriteRegDWORD HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\VibezCraft" \
    "NoModify" 1
  WriteRegDWORD HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\VibezCraft" \
    "NoRepair" 1
SectionEnd

Section "Uninstall"
  Delete "$INSTDIR\VibezCraft.exe"
  Delete "$INSTDIR\VibezCraft.console.exe"
  Delete "$INSTDIR\VibezCraft.pck"
  Delete "$INSTDIR\Uninstall.exe"
  RMDir "$INSTDIR"

  Delete "$SMPROGRAMS\VibezCraft\VibezCraft.lnk"
  Delete "$SMPROGRAMS\VibezCraft\Uninstall VibezCraft.lnk"
  RMDir "$SMPROGRAMS\VibezCraft"
  Delete "$DESKTOP\VibezCraft.lnk"

  DeleteRegKey HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\VibezCraft"
  DeleteRegKey HKLM "Software\VibezCraft"
SectionEnd
