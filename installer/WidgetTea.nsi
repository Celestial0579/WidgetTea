; NSIS-Installer für WidgetTea (Gitea-Contributions als Desktop-Widget)
;
; Installiert pro Benutzer nach %LOCALAPPDATA%\Programs\WidgetTea – ohne Adminrechte.
; Dadurch kann der eingebaute Updater Updates ohne UAC-Abfrage einspielen.
;
; Aufruf über build/release.ps1, oder manuell:
;   makensis /INPUTCHARSET UTF8 /DVERSION=1.0.0 /DSRCDIR=<publish-ordner> /DOUTFILE=<setup.exe> WidgetTea.nsi
;
; Unbeaufsichtigt:  WidgetTea-…-setup.exe /S [/D=C:\Pfad]
; Vom Updater:      WidgetTea-…-setup.exe /S /RESTART   (wartet auf das Beenden der App und startet sie danach neu)
; Deinstallation:   uninstall.exe /S

Unicode true
ManifestDPIAware true
SetCompressor /SOLID lzma
RequestExecutionLevel user

!ifndef VERSION
  !error "VERSION fehlt (/DVERSION=x.y.z)"
!endif
!ifndef SRCDIR
  !error "SRCDIR fehlt (/DSRCDIR=<dotnet publish Ausgabeordner>)"
!endif
!ifndef OUTFILE
  !define OUTFILE "WidgetTea-${VERSION}-setup.exe"
!endif
!ifndef ICON
  !define ICON "..\Assets\WidgetTea.ico"
!endif
!ifndef HOMEPAGE
  !define HOMEPAGE ""
!endif

!define APPNAME     "WidgetTea"
!define DISPLAYNAME "WidgetTea – Gitea-Contributions auf dem Desktop"
!define PUBLISHER   "Celestial0579"
!define EXENAME     "WidgetTea.exe"
!define UNINSTKEY   "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APPNAME}"
!define SETTINGSKEY "Software\${APPNAME}"
!define RUNKEY      "Software\Microsoft\Windows\CurrentVersion\Run"

Name "${APPNAME}"
Caption "WidgetTea ${VERSION} – Installation"
UninstallCaption "WidgetTea – Deinstallation"
OutFile "${OUTFILE}"
BrandingText "${APPNAME} ${VERSION}"
InstallDir "$LOCALAPPDATA\Programs\${APPNAME}"
InstallDirRegKey HKCU "${SETTINGSKEY}" "InstallDir"

VIProductVersion "${VERSION}.0"
VIAddVersionKey /LANG=1031 "ProductName" "${APPNAME}"
VIAddVersionKey /LANG=1031 "FileDescription" "${DISPLAYNAME} – Setup"
VIAddVersionKey /LANG=1031 "CompanyName" "${PUBLISHER}"
VIAddVersionKey /LANG=1031 "FileVersion" "${VERSION}"
VIAddVersionKey /LANG=1031 "ProductVersion" "${VERSION}"
VIAddVersionKey /LANG=1031 "LegalCopyright" "© 2026 Tim Heyne – MIT-Lizenz"

!include MUI2.nsh
!include LogicLib.nsh
!include x64.nsh
!include FileFunc.nsh
!include WinVer.nsh

Var Restart

; ---------- Oberfläche ----------
!define MUI_ICON "${ICON}"
!define MUI_UNICON "${ICON}"
!define MUI_ABORTWARNING
!define MUI_COMPONENTSPAGE_SMALLDESC
!define MUI_FINISHPAGE_RUN
!define MUI_FINISHPAGE_RUN_FUNCTION LaunchApp
!define MUI_FINISHPAGE_RUN_TEXT "WidgetTea jetzt starten"

!define MUI_WELCOMEPAGE_TITLE "Willkommen bei WidgetTea"
!define MUI_WELCOMEPAGE_TEXT "WidgetTea zeigt deine Contributions aus Gitea als Heatmap direkt auf dem Desktop – auch offline mit dem zuletzt geladenen Stand.$\r$\n$\r$\nDie Installation erfolgt nur für dein Benutzerkonto und braucht keine Administratorrechte. Updates holt sich WidgetTea später selbst.$\r$\n$\r$\nKlicke auf „Weiter“, um fortzufahren."
!define MUI_COMPONENTSPAGE_TEXT_TOP "Wähle aus, was installiert werden soll."
!define MUI_DIRECTORYPAGE_TEXT_TOP "WidgetTea wird in folgendes Verzeichnis installiert. Du kannst auch ein anderes wählen."
!define MUI_FINISHPAGE_TITLE "WidgetTea ist bereit"
!define MUI_FINISHPAGE_TEXT "WidgetTea wurde installiert.$\r$\n$\r$\nBeim ersten Start öffnen sich die Einstellungen: Gitea-Adresse, Benutzername und Access-Token eintragen – fertig."

!insertmacro MUI_PAGE_WELCOME
!define MUI_LICENSEPAGE_TEXT_TOP "WidgetTea ist freie Software unter der MIT-Lizenz."
!insertmacro MUI_PAGE_LICENSE "..\LICENSE"
!insertmacro MUI_PAGE_COMPONENTS
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_COMPONENTS
!insertmacro MUI_UNPAGE_INSTFILES

!insertmacro MUI_LANGUAGE "German"

; ---------- Hilfsfunktionen ----------

; Wartet, bis WidgetTea beendet ist (Dateien wären sonst gesperrt).
; Beim Update (/RESTART) beendet sich die App gerade selbst → bis zu 15 s still warten.
; Bei einer normalen Installation wird das laufende Widget nach Rückfrage beendet.
!macro CLOSE_APP_FUNC un
Function ${un}CloseRunningApp
  StrCpy $R8 0
  retry:
    nsExec::ExecToStack 'cmd.exe /C tasklist /FI "IMAGENAME eq ${EXENAME}" /NH | find /I "${EXENAME}"'
    Pop $0
    Pop $1
    ${If} $0 == 0
      ${If} $Restart == 1
      ${AndIf} $R8 < 30
        IntOp $R8 $R8 + 1
        Sleep 500
        Goto retry
      ${EndIf}
      MessageBox MB_OKCANCEL|MB_ICONEXCLAMATION \
        "WidgetTea läuft gerade und wird für die Installation beendet." \
        /SD IDOK IDOK kill
      Abort
      kill:
        nsExec::ExecToStack 'taskkill /IM "${EXENAME}"'
        Sleep 1500
        nsExec::ExecToStack 'taskkill /F /IM "${EXENAME}"'
        Sleep 500
        Goto retry
    ${EndIf}
FunctionEnd
!macroend
!insertmacro CLOSE_APP_FUNC ""
!insertmacro CLOSE_APP_FUNC "un."

Function LaunchApp
  ; Über explorer.exe starten, damit die App nie die Rechte des Setups erbt.
  Exec '"$WINDIR\explorer.exe" "$INSTDIR\${EXENAME}"'
FunctionEnd

Function .onInit
  ${IfNot} ${AtLeastWin10}
    MessageBox MB_OK|MB_ICONSTOP "WidgetTea benötigt Windows 10 oder neuer." /SD IDOK
    Abort
  ${EndIf}
  ${IfNot} ${IsNativeAMD64}
  ${AndIfNot} ${IsNativeARM64}
    MessageBox MB_OK|MB_ICONSTOP "WidgetTea benötigt ein 64-Bit-Windows." /SD IDOK
    Abort
  ${EndIf}

  StrCpy $Restart 0
  ${GetParameters} $R0
  ClearErrors
  ${GetOptions} $R0 "/RESTART" $R1
  ${IfNot} ${Errors}
    StrCpy $Restart 1
  ${EndIf}
FunctionEnd

Function .onInstSuccess
  ${If} $Restart == 1
    Call LaunchApp
  ${EndIf}
FunctionEnd

; ---------- Installation ----------

Section "WidgetTea (erforderlich)" SecMain
  SectionIn RO
  SetShellVarContext current
  Call CloseRunningApp

  SetOutPath "$INSTDIR"
  File /r "${SRCDIR}\*.*"
  File "/oname=LICENSE.txt" "..\LICENSE"
  WriteUninstaller "$INSTDIR\uninstall.exe"

  CreateShortcut "$SMPROGRAMS\WidgetTea.lnk" "$INSTDIR\${EXENAME}" "" "$INSTDIR\${EXENAME}" 0 SW_SHOWNORMAL "" "Gitea-Contributions auf dem Desktop"

  ; Eintrag unter "Apps & Features"
  WriteRegStr   HKCU "${UNINSTKEY}" "DisplayName" "${DISPLAYNAME}"
  WriteRegStr   HKCU "${UNINSTKEY}" "DisplayVersion" "${VERSION}"
  WriteRegStr   HKCU "${UNINSTKEY}" "Publisher" "${PUBLISHER}"
  WriteRegStr   HKCU "${UNINSTKEY}" "URLInfoAbout" "${HOMEPAGE}"
  WriteRegStr   HKCU "${UNINSTKEY}" "DisplayIcon" "$INSTDIR\${EXENAME}"
  WriteRegStr   HKCU "${UNINSTKEY}" "InstallLocation" "$INSTDIR"
  WriteRegStr   HKCU "${UNINSTKEY}" "UninstallString" '"$INSTDIR\uninstall.exe"'
  WriteRegStr   HKCU "${UNINSTKEY}" "QuietUninstallString" '"$INSTDIR\uninstall.exe" /S'
  WriteRegDWORD HKCU "${UNINSTKEY}" "NoModify" 1
  WriteRegDWORD HKCU "${UNINSTKEY}" "NoRepair" 1
  ${GetSize} "$INSTDIR" "/S=0K" $0 $1 $2
  IntFmt $0 "0x%08X" $0
  WriteRegDWORD HKCU "${UNINSTKEY}" "EstimatedSize" "$0"

  WriteRegStr HKCU "${SETTINGSKEY}" "InstallDir" "$INSTDIR"
SectionEnd

Section "Mit Windows starten" SecAutostart
  ; Beim Update die Entscheidung des Nutzers (Einstellungsfenster) nicht überschreiben.
  ${If} $Restart != 1
    WriteRegStr HKCU "${RUNKEY}" "${APPNAME}" '"$INSTDIR\${EXENAME}"'
  ${EndIf}
SectionEnd

!insertmacro MUI_FUNCTION_DESCRIPTION_BEGIN
  !insertmacro MUI_DESCRIPTION_TEXT ${SecMain} "Das Widget inkl. .NET-Laufzeit."
  !insertmacro MUI_DESCRIPTION_TEXT ${SecAutostart} "Startet das Widget bei der Anmeldung (später im Einstellungsfenster änderbar)."
!insertmacro MUI_FUNCTION_DESCRIPTION_END

; ---------- Deinstallation ----------

Section "un.WidgetTea" SecUnMain
  SectionIn RO
  SetShellVarContext current
  Call un.CloseRunningApp

  Delete "$SMPROGRAMS\WidgetTea.lnk"

  ; Nur löschen, wenn es wirklich unser Ordner ist.
  ${If} ${FileExists} "$INSTDIR\${EXENAME}"
    RMDir /r "$INSTDIR"
  ${Else}
    Delete "$INSTDIR\uninstall.exe"
    RMDir "$INSTDIR"
  ${EndIf}

  DeleteRegKey HKCU "${UNINSTKEY}"
  DeleteRegKey HKCU "${SETTINGSKEY}"
  DeleteRegValue HKCU "${RUNKEY}" "${APPNAME}"
SectionEnd

Section /o "un.Benutzerdaten entfernen" SecUnData
  ; Einstellungen, verschlüsseltes Token, Cache
  RMDir /r "$LOCALAPPDATA\WidgetTea"
SectionEnd

!insertmacro MUI_UNFUNCTION_DESCRIPTION_BEGIN
  !insertmacro MUI_DESCRIPTION_TEXT ${SecUnMain} "Entfernt das Widget."
  !insertmacro MUI_DESCRIPTION_TEXT ${SecUnData} "Löscht zusätzlich Einstellungen, gespeichertes Token und Cache."
!insertmacro MUI_UNFUNCTION_DESCRIPTION_END
