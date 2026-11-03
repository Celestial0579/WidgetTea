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
; Benötigt LogicLib.nsh und x64.nsh.
;
; Aufruf in .onInit:
;   StrCpy $DotnetAsk 1   ; 1 = auch bei /S nachfragen (z.B. Selbst-Update mit angemeldetem Benutzer)
;   Call DotnetEnsure     ; bricht die Installation ab, wenn die Laufzeit fehlt und nicht installiert wird;
;                         ; vorher wird $DotnetAbortHook aufgerufen, falls gesetzt (GetFunctionAddress)
;
; Unbeaufsichtigt (/S ohne $DotnetAsk) wird nicht gefragt: Abbruch mit Exitcode 3.

Var DotnetAsk
Var DotnetFound
Var DotnetAbortHook

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
    MessageBox MB_YESNO|MB_ICONEXCLAMATION|MB_TOPMOST \
      "${PRODUCT} benötigt die ${DOTNET_NAME} ${DOTNET_MAJOR}.${DOTNET_MINPATCH} oder neuer (x64).$\r$\n($0)$\r$\n$\r$\nJetzt installieren? Dafür sind Administratorrechte nötig.$\r$\n$\r$\nBei „Nein“ wird die Installation von ${PRODUCT} abgebrochen." \
      IDYES install
    Call DotnetAbort

  install:
    ; winget ist auf aktuellen Windows-Versionen vorhanden; die UAC-Abfrage stellt das Laufzeit-Setup selbst
    nsExec::ExecToStack 'cmd.exe /C where winget'
    Pop $1
    Pop $0
    ${If} $1 == 0
      Banner::show /NOUNLOAD /set 76 "${DOTNET_NAME} wird installiert …" "Bitte die Windows-Abfrage bestätigen."
      nsExec::ExecToStack 'cmd.exe /C winget install --id ${DOTNET_WINGET} --exact --source winget --silent --accept-package-agreements --accept-source-agreements --disable-interactivity'
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
    MessageBox MB_RETRYCANCEL|MB_ICONINFORMATION|MB_TOPMOST \
      "Das Setup der ${DOTNET_NAME} wird von Microsoft heruntergeladen.$\r$\nBitte ausführen und danach auf „Wiederholen“ klicken." \
      IDRETRY check
    Call DotnetAbort
FunctionEnd
