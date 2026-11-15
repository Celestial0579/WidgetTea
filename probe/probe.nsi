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
  System::Call 'user32::MessageBoxTimeoutW(p 0, w "Probe ${MODE}: wird von Microsoft heruntergeladen", w "Probe", i 0x00050045, i 0, i 60000) i .r0'
  !if ${MODE} == attach
    System::Call 'user32::AttachThreadInput(i r7, i r6, i 0)'
  !endif
  !if ${MODE} == keep
    Banner::destroy
  !endif
FunctionEnd
Section
SectionEnd
