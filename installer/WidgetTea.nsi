; NSIS-Installer für WidgetTea (Gitea-Contributions als Desktop-Widget)
;
; Installiert pro Benutzer nach %LOCALAPPDATA%\Programs\WidgetTea – ohne Adminrechte.
; Dadurch kann der eingebaute Updater Updates ohne UAC-Abfrage einspielen.
;
; Aufruf über build/release.ps1, oder manuell:
;   makensis /INPUTCHARSET UTF8 /DVERSION=1.0.0 /DSRCDIR=<publish-ordner> /DOUTFILE=<setup.exe> WidgetTea.nsi
; (ruft beim Übersetzen New-PayloadList.ps1 über Windows PowerShell auf, für die Dateiliste der Deinstallation)
;
; Unbeaufsichtigt:  WidgetTea-…-setup.exe /S [/D=C:\Pfad]
; Vom Updater:      WidgetTea-…-setup.exe /S /RESTART   (wartet auf das Beenden der App und startet sie danach neu)
; Deinstallation:   uninstall.exe /S
;
; Fehlt die .NET-Laufzeit, entscheidet sich das vor dem ersten Schreibzugriff (.onInit):
;   /S            Exitcode 3, keine Nachfrage, nichts verändert
;   /S /RESTART   Nachfrage trotz /S; bei „Nein“ Exitcode 3, automatische Updates aus, alte Version startet wieder

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

; Was das Setup installiert, als Delete-Befehle für die Deinstallation: beim Übersetzen aus SRCDIR erzeugt.
; So entfernt die Deinstallation genau die installierten Dateien, auch wenn im Programm später eine dazukommt.
!tempfile PAYLOADLIST
!system 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "${__FILEDIR__}\New-PayloadList.ps1" -Source "${SRCDIR}" -Out "${PAYLOADLIST}"' = 0

!define APPNAME     "WidgetTea"
!define DISPLAYNAME "WidgetTea – Gitea-Contributions auf dem Desktop"
!define PUBLISHER   "Celestial0579"
!define EXENAME     "WidgetTea.exe"
!define UNINSTKEY   "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APPNAME}"
!define SETTINGSKEY "Software\${APPNAME}"
!define RUNKEY      "Software\Microsoft\Windows\CurrentVersion\Run"
!define PRODUCT     "${APPNAME}"

; Einstellungsdatei der App und die Schreibweisen von „Updates automatisch installieren“ darin.
; Die App schreibt eingerückt, also mit Leerzeichen nach dem Doppelpunkt. Je zwei Fassungen sind gleich lang,
; damit das Setup den Wert an Ort und Stelle umstellen kann (siehe PatchFile.nsh).
!define SETTINGSFILE "$LOCALAPPDATA\${APPNAME}\settings.json"
!define AU_ON        '"autoUpdate": true'
!define AU_OFF       '"autoUpdate":false'    ; so schreibt es PauseAutoUpdate
!define AU_OFF_APP   '"autoUpdate": false'   ; so schreibt es die App beim nächsten Speichern
!define AU_ON_PAD    '"autoUpdate": true '   ; gleich lang wie AU_OFF_APP; das Leerzeichen vor dem Komma ist gültiges JSON
; Leere Merkerdatei: Das Setup hat die Updates ausgeschaltet. Sie liegt neben den Einstellungen und nicht in
; der Registry, damit sie eine Deinstallation genau dann überlebt, wenn die Einstellungen es auch tun.
!define PAUSEDFILE   "$LOCALAPPDATA\${APPNAME}\autoupdate-paused"

; Benötigte .NET-Laufzeit (WPF/WinForms → Desktop Runtime). Die Mindest-Patchversion enthält die
; vorausgesetzten Sicherheitskorrekturen; bei neuen kritischen .NET-Patches anheben.
; Von außen überschreibbar (/DDOTNET_MINPATCH=999), damit die Installer-Tests den Abbruch ohne passende
; Laufzeit auf einem Rechner prüfen können, auf dem sie vorhanden ist.
!define DOTNET_FX       "Microsoft.WindowsDesktop.App"
!define DOTNET_MAJOR    "10.0"
!ifndef DOTNET_MINPATCH
  !define DOTNET_MINPATCH 14
!endif
!define DOTNET_NAME     ".NET Desktop Runtime"
!define DOTNET_WINGET   "Microsoft.DotNet.DesktopRuntime.10"
!define DOTNET_URL      "https://aka.ms/dotnet/10.0/windowsdesktop-runtime-win-x64.exe"
; Nachfragen mit Zeitablauf tragen denselben Fenstertitel wie die übrigen Meldungen des Setups.
!define SETUPCAPTION    "WidgetTea ${VERSION} – Installation"
!define DOTNET_CAPTION  "${SETUPCAPTION}"

Name "${APPNAME}"
Caption "${SETUPCAPTION}"
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
!include DotnetRuntime.nsh
!include PatchFile.nsh

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

; Schaltet „Updates automatisch installieren“ aus, falls es an ist. $R3 = 1, wenn umgestellt wurde.
; Dann steht auch der Merker, mit dem ResumeAutoUpdate die Umstellung später zurücknimmt.
; War es schon aus (Entscheidung des Nutzers), passiert nichts und $R3 = 0.
Function PauseAutoUpdate
  ${If} ${FileExists} "${SETTINGSFILE}"
    Push "${SETTINGSFILE}"
    Push '${AU_ON}'
    Push '${AU_OFF}'
    Call PatchFile
    Pop $R3
  ${Else}
    ; Noch nie gespeichert: Die App nähme den Vorgabewert, und der ist „an“.
    ; Eine Minimaldatei genügt, alle anderen Einstellungen bleiben Vorgabe.
    StrCpy $R3 0
    CreateDirectory "$LOCALAPPDATA\${APPNAME}"
    ClearErrors
    FileOpen $R4 "${SETTINGSFILE}" w
    ${IfNot} ${Errors}
      FileWrite $R4 '{ ${AU_OFF} }'
      FileClose $R4
      StrCpy $R3 1
    ${EndIf}
  ${EndIf}
  ${If} $R3 == 1
    ClearErrors
    FileOpen $R4 "${PAUSEDFILE}" w
    ${IfNot} ${Errors}
      FileClose $R4
    ${EndIf}
  ${EndIf}
FunctionEnd

; Nimmt PauseAutoUpdate nach einer gelungenen Installation zurück – aber nur, wenn das Setup selbst
; ausgeschaltet hatte. Wer die automatischen Updates von Hand abgestellt hat, behält seine Einstellung.
Function ResumeAutoUpdate
  ${If} ${FileExists} "${PAUSEDFILE}"
    Push "${SETTINGSFILE}"
    Push '${AU_OFF}'
    Push '${AU_ON}'
    Call PatchFile
    Pop $R3
    ${If} $R3 != 1
      ; Die App hat inzwischen gespeichert und dabei „: false“ mit Leerzeichen geschrieben.
      Push "${SETTINGSFILE}"
      Push '${AU_OFF_APP}'
      Push '${AU_ON_PAD}'
      Call PatchFile
      Pop $R3
    ${EndIf}
    Delete "${PAUSEDFILE}"
  ${EndIf}
FunctionEnd

; Das Selbst-Update wurde abgebrochen, weil die .NET-Laufzeit fehlt und nicht installiert wurde.
; Die alte Version sucht eine Minute nach jedem Start nach Updates, lädt dieses Setup erneut und beendet
; sich dafür – ohne Eingriff also endlos im Minutentakt. Deshalb: automatische Updates ausschalten,
; alte Version wieder starten, Bescheid sagen. Das Update lässt sich über das Tray-Symbol nachholen.
; Dasselbe geschieht, wenn auf die Nachfrage niemand antwortet ($DotnetTimedOut, siehe DotnetRuntime.nsh).
Function UpdateDeclined
  ; /RESTART ohne vorhandene Installation (von Hand aufgerufen): nichts auszuschalten und nichts zu starten.
  ${IfNot} ${FileExists} "$INSTDIR\${EXENAME}"
    Return
  ${EndIf}
  Call PauseAutoUpdate
  ; Erst starten, dann Bescheid sagen: Sitzt niemand am Rechner, läuft das Widget trotzdem wieder,
  ; und der Hinweis wartet, bis ihn jemand liest.
  Call LaunchApp
  ${If} $DotnetTimedOut == 1
    StrCpy $R4 "Auf die Nachfrage kam keine Antwort.$\r$\n$\r$\n"
  ${Else}
    StrCpy $R4 ""
  ${EndIf}
  StrCpy $R5 "${APPNAME} bleibt in der bisherigen Version installiert und läuft wieder."
  ${If} $R3 == 1
    StrCpy $R6 "Damit diese Abfrage nicht nach jedem Start erneut kommt, wurde „Updates automatisch installieren“ ausgeschaltet. Sobald die ${DOTNET_NAME} installiert ist, lässt sich das Update über das Tray-Symbol nachholen – danach sind automatische Updates wieder an."
  ${Else}
    StrCpy $R6 "Ist „Updates automatisch installieren“ eingeschaltet, kommt diese Abfrage nach jedem Start erneut. In den Einstellungen lässt sich das ausschalten."
  ${EndIf}
  MessageBox MB_OK|MB_ICONINFORMATION|MB_TOPMOST "$R4$R5$\r$\n$\r$\n$R6"
FunctionEnd

; Entfernt die .NET-Laufzeit, die Version 1.0.x selbst mitbrachte. Sie muss weg: Solange hostfxr.dll und
; coreclr.dll neben der EXE liegen, nimmt der Starter sie statt der installierten Laufzeit.
; Gelöscht wird gezielt und nicht der ganze Ordner. Wer WidgetTea in einen Ordner mit eigenen Dateien
; installiert hat, behält sie (bis auf DLLs im Hauptordner – die lassen sich von denen der Laufzeit
; nicht unterscheiden).
Function RemoveBundledRuntime
  Delete "$INSTDIR\*.dll"
  Delete "$INSTDIR\createdump.exe"
  Delete "$INSTDIR\${EXENAME}"
  Delete "$INSTDIR\${APPNAME}.deps.json"
  Delete "$INSTDIR\${APPNAME}.runtimeconfig.json"
  ; Sprachordner der Laufzeit (cs, de, … zh-Hant): nur die *.resources.dll, den Ordner nur, wenn er danach leer ist.
  FindFirst $R0 $R1 "$INSTDIR\*.*"
  ${DoWhile} $R1 != ""
    ${If} $R1 != "."
    ${AndIf} $R1 != ".."
    ${AndIf} ${FileExists} "$INSTDIR\$R1\*.resources.dll"
      Delete "$INSTDIR\$R1\*.resources.dll"
      RMDir "$INSTDIR\$R1"
    ${EndIf}
    FindNext $R0 $R1
  ${Loop}
  FindClose $R0
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

  ; Beim Selbst-Update hat sich die App schon beendet: auch still nachfragen. Bricht der Nutzer ab, schaltet
  ; UpdateDeclined die automatischen Updates aus und startet die alte Version wieder. Bis hierher ist an der
  ; vorhandenen Installation nichts verändert.
  StrCpy $DotnetAsk $Restart
  ${If} $Restart == 1
    GetFunctionAddress $DotnetAbortHook UpdateDeclined
  ${EndIf}
  Call DotnetEnsure
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

  ; Frühere Versionen brachten die .NET-Laufzeit selbst mit – erkennbar an coreclr.dll neben der EXE.
  ${If} ${FileExists} "$INSTDIR\coreclr.dll"
    Call RemoveBundledRuntime
  ${EndIf}

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

  ; Hatte ein abgebrochenes Selbst-Update die automatischen Updates ausgeschaltet, sind sie jetzt wieder an.
  Call ResumeAutoUpdate
SectionEnd

Section "Mit Windows starten" SecAutostart
  ; Beim Update die Entscheidung des Nutzers (Einstellungsfenster) nicht überschreiben.
  ${If} $Restart != 1
    WriteRegStr HKCU "${RUNKEY}" "${APPNAME}" '"$INSTDIR\${EXENAME}"'
  ${EndIf}
SectionEnd

!insertmacro MUI_FUNCTION_DESCRIPTION_BEGIN
  !insertmacro MUI_DESCRIPTION_TEXT ${SecMain} "Das Widget (benötigt die .NET Desktop Runtime ${DOTNET_MAJOR})."
  !insertmacro MUI_DESCRIPTION_TEXT ${SecAutostart} "Startet das Widget bei der Anmeldung (später im Einstellungsfenster änderbar)."
!insertmacro MUI_FUNCTION_DESCRIPTION_END

; ---------- Deinstallation ----------

Section "un.WidgetTea" SecUnMain
  SectionIn RO
  SetShellVarContext current
  Call un.CloseRunningApp

  Delete "$SMPROGRAMS\WidgetTea.lnk"

  ; Nur entfernen, was das Setup installiert hat. Der Ordner ist frei wählbar; was dort sonst noch liegt,
  ; gehört nicht WidgetTea und bleibt. Der Ordner selbst verschwindet nur, wenn er danach leer ist.
  !include "${PAYLOADLIST}"
  Delete "$INSTDIR\LICENSE.txt"
  Delete "$INSTDIR\uninstall.exe"
  RMDir "$INSTDIR"

  DeleteRegKey HKCU "${UNINSTKEY}"
  DeleteRegKey HKCU "${SETTINGSKEY}"
  DeleteRegValue HKCU "${RUNKEY}" "${APPNAME}"
SectionEnd

Section /o "un.Benutzerdaten entfernen" SecUnData
  ; Einstellungen, verschlüsseltes Token, Cache
  RMDir /r "$LOCALAPPDATA\WidgetTea"
SectionEnd

!insertmacro MUI_UNFUNCTION_DESCRIPTION_BEGIN
  !insertmacro MUI_DESCRIPTION_TEXT ${SecUnMain} "Entfernt das Widget. Andere Dateien im Installationsordner bleiben."
  !insertmacro MUI_DESCRIPTION_TEXT ${SecUnData} "Löscht zusätzlich Einstellungen, gespeichertes Token und Cache."
!insertmacro MUI_UNFUNCTION_DESCRIPTION_END

!delfile "${PAYLOADLIST}"
