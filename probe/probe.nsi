Unicode true
!include LogicLib.nsh
Name "Probe"
OutFile "${OUT}"
RequestExecutionLevel user
SilentInstall silent
Function .onInit
  !if ${MODE} != base
    Banner::show /NOUNLOAD /set 76 "Hinweis" "läuft"
    Sleep 1500
  !endif
  !if ${MODE} == keep
    ; Banner bleibt, bis die Box zu ist
  !else if ${MODE} != base
    Banner::destroy
  !endif
  !if ${MODE} == attach
    System::Call 'user32::GetForegroundWindow() p .r5'
    System::Call 'user32::GetWindowThreadProcessId(p r5, p 0) i .r6'
    System::Call 'kernel32::GetCurrentThreadId() i .r7'
    System::Call 'user32::AttachThreadInput(i r7, i r6, i 1) i .r8'
  !endif
  StrCpy $9 0
  StrCpy $4 0x00050045
  !if ${MODE} == sysmodal
    StrCpy $4 0x00051045
  !endif
  !if ${MODE} == owner
    ; unsichtbares Besitzerfenster „immer im Vordergrund“ (WS_EX_TOPMOST|WS_EX_TOOLWINDOW, WS_POPUP)
    System::Call 'user32::CreateWindowExW(i 0x88, w "STATIC", w "", i 0x80000000, i 0, i 0, i 0, i 0, p 0, p 0, p 0, p 0) p .r9'
  !endif
  System::Call 'user32::MessageBoxTimeoutW(p r9, w "Probe ${MODE}: wird von Microsoft heruntergeladen", w "Probe", i r4, i 0, i 60000) i .r0'
  !if ${MODE} == owner
    System::Call 'user32::DestroyWindow(p r9)'
  !endif
  !if ${MODE} == attach
    System::Call 'user32::AttachThreadInput(i r7, i r6, i 0)'
  !endif
  !if ${MODE} == keep
    Banner::destroy
  !endif
FunctionEnd
Section
SectionEnd
