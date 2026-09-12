; SPDX-License-Identifier: MIT OR Apache-2.0
Unicode True
RequestExecutionLevel user
Name "kIRC"
OutFile "${OUT_FILE}"
InstallDir "$LOCALAPPDATA\Programs\kIRC"
InstallDirRegKey HKCU "Software\kIRC" "InstallDir"
Icon "..\kirc.ico"
UninstallIcon "..\kirc.ico"
SetCompressor /SOLID lzma

VIProductVersion "${KIRC_VERSION}.0"
VIAddVersionKey "ProductName" "kIRC"
VIAddVersionKey "FileDescription" "kIRC per-user installer"
VIAddVersionKey "FileVersion" "${KIRC_VERSION}"
VIAddVersionKey "LegalCopyright" "kIRC contributors"

Page directory
Page instfiles
UninstPage uninstConfirm
UninstPage instfiles

Section "kIRC" SecMain
  SetShellVarContext current
  SetOutPath "$INSTDIR"
  File /r "${STAGE_DIR}\*.*"
  WriteUninstaller "$INSTDIR\Uninstall.exe"
  CreateDirectory "$SMPROGRAMS"
  ExecWait '"$INSTDIR\kirc-shortcut.exe" "$SMPROGRAMS\kIRC.lnk" "$INSTDIR\kIRC.exe" "$INSTDIR\kIRC.exe"' $0
  IntCmp $0 0 shortcut_ok
    Abort "Could not create the Start menu shortcut required for notifications (code $0)."
  shortcut_ok:
  WriteRegStr HKCU "Software\kIRC" "InstallDir" "$INSTDIR"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\kIRC" "DisplayName" "kIRC"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\kIRC" "DisplayVersion" "${KIRC_VERSION}"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\kIRC" "Publisher" "kIRC contributors"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\kIRC" "DisplayIcon" "$INSTDIR\kIRC.exe"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\kIRC" "UninstallString" '"$INSTDIR\Uninstall.exe"'
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\kIRC" "NoModify" 1
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\kIRC" "NoRepair" 1
SectionEnd

Section "Uninstall"
  SetShellVarContext current
  Delete "$SMPROGRAMS\kIRC.lnk"
  DeleteRegKey HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\kIRC"
  DeleteRegKey HKCU "Software\kIRC"
  RMDir /r "$INSTDIR"
SectionEnd
