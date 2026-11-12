; PatchFile.nsh – ersetzt in einer Datei eine Zeichenfolge durch eine gleich lange, an Ort und Stelle.
;
; Gedacht für kleine Eingriffe in Textdateien, die dem Setup nicht gehören (hier: settings.json der App).
; Die Datei wird nicht neu geschrieben: Überschrieben werden genau die Bytes des Treffers, alles andere
; bleibt, wie es ist – unabhängig von Kodierung, Zeilenenden und Umlauten davor oder dahinter.
; Deshalb müssen Suche und Ersatz gleich lang und reines ASCII sein.
;
; Aufruf:
;   Push "<Datei>"
;   Push "<Suche>"
;   Push "<Ersatz>"
;   Call PatchFile
;   Pop $0        ; 1 = ersetzt, 0 = nicht gefunden, Datei nicht zu öffnen oder Längen ungleich
;
; Ersetzt wird nur das erste Vorkommen, Groß-/Kleinschreibung zählt. Benötigt LogicLib.nsh.

Function PatchFile
  ; Stack beim Aufruf (oben zuerst): Ersatz, Suche, Datei
  Exch $R2        ; $R2 = Ersatz
  Exch
  Exch $R1        ; $R1 = Suche
  Exch 2
  Exch $R0        ; $R0 = Datei          Stack jetzt: altes $R0, altes $R2, altes $R1
  Push $R3        ; Dateihandle
  Push $R4        ; Länge der Suche
  Push $R5        ; Zahl der bisher passenden Zeichen
  Push $R6        ; gelesenes Byte, dann als Zeichen
  Push $R7        ; Vergleichszeichen / Hilfswert
  Push $R8        ; Ergebnis

  StrCpy $R8 0
  StrLen $R4 $R1
  StrLen $R7 $R2
  ${If} $R4 > 0
  ${AndIf} $R4 == $R7
    ClearErrors
    FileOpen $R3 $R0 a          ; „a“: lesen und schreiben, Inhalt bleibt, Zeiger steht am Anfang
    ${IfNot} ${Errors}
      StrCpy $R5 0
      ${Do}
        ClearErrors
        FileReadByte $R3 $R6
        ${If} ${Errors}
        ${OrIf} $R6 == ""
          ${ExitDo}             ; Dateiende
        ${EndIf}
        IntFmt $R6 "%c" $R6     ; Byte → Zeichen; Bytes ab 128 passen nie auf ein ASCII-Muster
        StrCpy $R7 $R1 1 $R5    ; das an dieser Stelle erwartete Zeichen
        ${If} $R6 S== $R7
          IntOp $R5 $R5 + 1
          ${If} $R5 == $R4
            IntOp $R7 0 - $R4
            FileSeek $R3 $R7 CUR  ; zurück an den Anfang des Treffers
            FileWrite $R3 $R2
            StrCpy $R8 1
            ${ExitDo}
          ${EndIf}
        ${ElseIf} $R5 > 0
          ; Fehlgriff nach $R5 passenden Zeichen: Der Treffer kann mitten im Fehlgriff beginnen. Deshalb zurück
          ; auf das Byte hinter dessen Anfang und dort neu ansetzen, statt einfach weiterzulesen.
          IntOp $R7 0 - $R5
          FileSeek $R3 $R7 CUR
          StrCpy $R5 0
        ${EndIf}
      ${Loop}
      FileClose $R3
    ${EndIf}
  ${EndIf}

  StrCpy $R0 $R8  ; Ergebnis
  Pop $R8
  Pop $R7
  Pop $R6
  Pop $R5
  Pop $R4
  Pop $R3
  Exch $R0        ; Ergebnis auf den Stack, $R0 wiederhergestellt
  Exch
  Pop $R2
  Exch
  Pop $R1
FunctionEnd
