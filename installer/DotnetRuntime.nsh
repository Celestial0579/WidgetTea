; DotnetRuntime.nsh – prüft vor der Installation, ob die benötigte .NET-Laufzeit (x64) vorhanden ist,
; und fordert sonst zur Installation auf (winget, ersatzweise Download von Microsoft).
;
; Vor dem !include definieren:
;   DOTNET_FX        Shared Framework, z.B. Microsoft.NETCore.App | Microsoft.WindowsDesktop.App | Microsoft.AspNetCore.App
;   DOTNET_MAJOR     z.B. 10.0
;   DOTNET_MINPATCH  kleinste zulässige Patchversion, z.B. 14 (→ 10.0.14, enthält die vorausgesetzten Sicherheitskorrekturen)
;   DOTNET_NAME      Anzeigename, z.B. ".NET Desktop Runtime"
;   DOTNET_WINGET    winget-Paket, z.B. Microsoft.DotNet.DesktopRuntime.10
;   DOTNET_URL       Direktdownload, z.B. https://aka.ms/dotnet/10.0/windowsdesktop-runtime-win-x64.exe
;   PRODUCT          Name der Anwendung für die Meldungen
;   DOTNET_CAPTION   Fenstertitel der Nachfragen im stillen Modus, üblicherweise der des Setups
; Wahlweise:
;   DOTNET_ASK_TIMEOUT    Sekunden, die „Jetzt installieren?“ im stillen Modus auf eine Antwort wartet (Vorgabe 120)
;   DOTNET_RETRY_TIMEOUT  dasselbe für „Wiederholen/Abbrechen“ nach dem Download im Browser (Vorgabe 1800)
; Benötigt LogicLib.nsh, x64.nsh und das System-Plugin.
;
; Aufruf in .onInit:
;   StrCpy $DotnetAsk 1   ; 1 = auch bei /S nachfragen (z.B. Selbst-Update mit angemeldetem Benutzer)
;   Call DotnetEnsure     ; bricht die Installation ab, wenn die Laufzeit fehlt und nicht installiert wird;
;                         ; vorher wird $DotnetAbortHook aufgerufen, falls gesetzt (GetFunctionAddress)
;
; Unbeaufsichtigt (/S ohne $DotnetAsk) wird nicht gefragt: Abbruch mit Exitcode 3.
;
; Mit /S und $DotnetAsk warten die Nachfragen nicht ewig: Beim Selbst-Update hat sich die Anwendung schon beendet,
; und sitzt niemand am Rechner, bliebe sie sonst geschlossen. Ohne Antwort wird abgebrochen wie bei „Nein“;
; $DotnetTimedOut ist dann 1, damit $DotnetAbortHook es dem Nutzer sagen kann.

!ifndef DOTNET_ASK_TIMEOUT
  !define DOTNET_ASK_TIMEOUT 120
!endif
!ifndef DOTNET_RETRY_TIMEOUT
  !define DOTNET_RETRY_TIMEOUT 1800
!endif
!define /math DOTNET_RETRY_MINUTES ${DOTNET_RETRY_TIMEOUT} / 60

Var DotnetAsk
Var DotnetFound
Var DotnetAbortHook
Var DotnetTimedOut

; $DotnetFound = höchste installierte Version ${DOTNET_MAJOR}.x (leer, wenn keine); $R9 = deren Patchnummer oder -1
Function DotnetFind
  Push $0
  Push $1
  Push $2
  Push $3
  StrCpy $DotnetFound ""
  StrCpy $R9 -1

  ; Installationsort laut dotnet-Setup (32-Bit-Registry-Ansicht), sonst Standardpfad
  ReadRegStr $0 HKLM "SOFTWARE\dotnet\Setup\InstalledVersions\x64" "InstallLocation"
  ${If} $0 == ""
  ${OrIfNot} ${FileExists} "$0\shared\*.*"
    ${If} ${IsNativeARM64}
      StrCpy $0 "$PROGRAMFILES64\dotnet\x64"
    ${Else}
      StrCpy $0 "$PROGRAMFILES64\dotnet"
    ${EndIf}
  ${EndIf}

  StrLen $3 "${DOTNET_MAJOR}."
  FindFirst $1 $2 "$0\shared\${DOTNET_FX}\${DOTNET_MAJOR}.*"
  ${DoWhile} $2 != ""
    ${If} ${FileExists} "$0\shared\${DOTNET_FX}\$2\*.dll"
      StrCpy $2 $2 "" $3        ; "10.0.14" → "14", Vorabversionen "0-rc.2…" → 0
      IntOp $2 $2 + 0
      ${If} $2 > $R9
        StrCpy $R9 $2
      ${EndIf}
    ${EndIf}
    FindNext $1 $2
  ${Loop}
  FindClose $1

  ${If} $R9 >= 0
    StrCpy $DotnetFound "${DOTNET_MAJOR}.$R9"
  ${EndIf}
  Pop $3
  Pop $2
  Pop $1
  Pop $0
FunctionEnd

Function DotnetAbort
  ${If} $DotnetAbortHook != ""
    Call $DotnetAbortHook
  ${EndIf}
  SetErrorLevel 3
  Quit
FunctionEnd

; Meldungsfenster mit Zeitablauf.
;   Push <Text>  Push <MB_-Flags als Zahl>  Push <Sekunden>  Call DotnetTimedBox  Pop <Antwort>
; Antwort: 6 Ja, 7 Nein, 4 Wiederholen, 2 Abbrechen, 32000 Zeitablauf – oder "error", wenn Windows die Funktion
; nicht kennt. NSIS selbst kann kein Fenster mit Zeitablauf. MessageBoxTimeoutW ist von Microsoft nicht
; dokumentiert, steckt aber seit Windows XP hinter MessageBox selbst; für den Fall der Fälle fragen die Aufrufer
; bei "error" ohne Zeitablauf, wie vorher.
Function DotnetTimedBox
  ; Stack beim Aufruf (oben zuerst): Sekunden, Flags, Text
  Exch $2         ; $2 = Sekunden
  Exch
  Exch $1         ; $1 = Flags
  Exch 2
  Exch $0         ; $0 = Text            Stack jetzt: altes $0, altes $2, altes $1
  Push $3
  IntOp $2 $2 * 1000
  StrCpy $3 "${DOTNET_CAPTION}"
  System::Call 'user32::MessageBoxTimeoutW(p 0, w r0, w r3, i r1, i 0, i r2) i .r0'
  Pop $3
  Exch $0         ; Antwort auf den Stack, $0 wiederhergestellt
  Exch
  Pop $2
  Exch
  Pop $1
FunctionEnd

Function DotnetEnsure
  Push $0
  Push $1
  check:
    Call DotnetFind
    ${If} $R9 >= ${DOTNET_MINPATCH}
      Pop $1
      Pop $0
      Return
    ${EndIf}

    ${If} ${Silent}
    ${AndIf} $DotnetAsk != 1
      Call DotnetAbort
    ${EndIf}

    ${If} $DotnetFound == ""
      StrCpy $0 "nicht installiert"
    ${Else}
      StrCpy $0 "installiert ist $DotnetFound – diese Version ist veraltet und enthält bekannte Sicherheitslücken"
    ${EndIf}
    StrCpy $1 "${PRODUCT} benötigt die ${DOTNET_NAME} ${DOTNET_MAJOR}.${DOTNET_MINPATCH} oder neuer (x64).$\r$\n($0)$\r$\n$\r$\nJetzt installieren? Dafür sind Administratorrechte nötig.$\r$\n$\r$\nBei „Nein“ wird die Installation von ${PRODUCT} abgebrochen."
    ${If} ${Silent}
      ; Stiller Aufruf mit Nachfrage (Selbst-Update): Die Anwendung hat sich schon beendet, und vielleicht sitzt
      ; niemand am Rechner. Ohne Antwort geht es nach DOTNET_ASK_TIMEOUT Sekunden weiter wie bei „Nein“.
      Push "$1$\r$\n$\r$\nOhne Antwort geschieht das nach ${DOTNET_ASK_TIMEOUT} Sekunden von selbst."
      Push 0x00050034              ; MB_YESNO | MB_ICONEXCLAMATION | MB_SETFOREGROUND | MB_TOPMOST
      Push ${DOTNET_ASK_TIMEOUT}
      Call DotnetTimedBox
      Pop $0
      ${If} $0 == 6                ; Ja
        Goto install
      ${ElseIf} $0 == 32000        ; Zeitablauf
        StrCpy $DotnetTimedOut 1
      ${ElseIf} $0 == "error"      ; Windows kennt die Funktion nicht: fragen wie bisher, ohne Zeitablauf
        MessageBox MB_YESNO|MB_ICONEXCLAMATION|MB_TOPMOST "$1" IDYES install
      ${EndIf}
    ${Else}
      MessageBox MB_YESNO|MB_ICONEXCLAMATION|MB_TOPMOST "$1" IDYES install
    ${EndIf}
    Call DotnetAbort

  install:
    ; winget ist auf aktuellen Windows-Versionen vorhanden; die UAC-Abfrage stellt das Laufzeit-Setup selbst.
    ; Aufgerufen wird es über seinen festen Ort im Benutzerprofil und ohne cmd, nicht über den Suchpfad: Beim
    ; bloßen Namen käme ein gleichnamiges Programm im Ordner des Setups oder im aktuellen Ordner zuerst zum Zug.
    ; --architecture x64: Auf einem ARM64-Windows nähme winget sonst die ARM64-Laufzeit, gesucht wird hier aber x64.
    nsExec::ExecToStack '"$LOCALAPPDATA\Microsoft\WindowsApps\winget.exe" --version'
    Pop $1                         ; Exitcode, oder "error", wenn es winget dort nicht gibt
    Pop $0
    ${If} $1 == 0
      ; Die Abfrage der Benutzerkontensteuerung stellt nicht das Setup, sondern das Laufzeit-Setup hinter winget.
      ; Windows zeigt sie dann oft nicht von selbst, sondern nur als blinkendes Schild in der Taskleiste – das
      ; muss hier stehen. Das Fenster ist klein: oben zwei Zeilen zu etwa 35 Zeichen, unten eine kurze.
      Banner::show /NOUNLOAD /set 76 "Windows-Abfrage bitte bestätigen –$\r$\ndas Schild in der Taskleiste blinkt." "Installation läuft …"
      nsExec::ExecToStack '"$LOCALAPPDATA\Microsoft\WindowsApps\winget.exe" install --id ${DOTNET_WINGET} --exact --source winget --architecture x64 --silent --accept-package-agreements --accept-source-agreements --disable-interactivity'
      Pop $1
      Pop $0
      Banner::destroy
      Call DotnetFind
      ${If} $R9 >= ${DOTNET_MINPATCH}
        Goto check
      ${EndIf}
    ${EndIf}

    ; Ersatzweise: offizielles Setup im Browser laden lassen und auf den Benutzer warten
    ExecShell "open" "${DOTNET_URL}"
    StrCpy $1 "Das Setup der ${DOTNET_NAME} wird von Microsoft heruntergeladen.$\r$\nBitte ausführen und danach auf „Wiederholen“ klicken."
    ${If} ${Silent}
      ; Auch hier nicht ewig warten – aber lange genug, um die Laufzeit in Ruhe zu laden und zu installieren.
      Push "$1$\r$\n$\r$\nOhne Antwort wird die Installation von ${PRODUCT} nach ${DOTNET_RETRY_MINUTES} Minuten abgebrochen."
      Push 0x00050045              ; MB_RETRYCANCEL | MB_ICONINFORMATION | MB_SETFOREGROUND | MB_TOPMOST
      Push ${DOTNET_RETRY_TIMEOUT}
      Call DotnetTimedBox
      Pop $0
      ${If} $0 == 4                ; Wiederholen
        Goto check
      ${ElseIf} $0 == 32000        ; Zeitablauf
        StrCpy $DotnetTimedOut 1
      ${ElseIf} $0 == "error"
        MessageBox MB_RETRYCANCEL|MB_ICONINFORMATION|MB_TOPMOST "$1" IDRETRY check
      ${EndIf}
    ${Else}
      MessageBox MB_RETRYCANCEL|MB_ICONINFORMATION|MB_TOPMOST "$1" IDRETRY check
    ${EndIf}
    Call DotnetAbort
FunctionEnd
