$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @'
using System; using System.Collections.Generic; using System.Runtime.InteropServices; using System.Text;
public static class P {
  delegate bool EP(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] static extern bool EnumWindows(EP cb, IntPtr l);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr h, int i);
  [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out R r);
  [DllImport("user32.dll")] static extern IntPtr WindowFromPoint(Q p);
  [DllImport("user32.dll")] static extern IntPtr GetAncestor(IntPtr h, uint f);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  public struct R { public int L, T, Ri, B; } public struct Q { public int X, Y; }
  public static long Box(int pid) { long f = 0; EnumWindows((h, l) => { uint p; GetWindowThreadProcessId(h, out p);
    var c = new StringBuilder(64); GetClassName(h, c, 64); var t = new StringBuilder(256); GetWindowText(h, t, 256);
    if (p == pid && IsWindowVisible(h) && c.ToString() == "#32770" && t.ToString() == "Probe") { f = h.ToInt64(); return false; } return true; }, IntPtr.Zero); return f; }
  public static bool Top(long h) { return (GetWindowLong(new IntPtr(h), -20) & 8) != 0; }
  public static bool Vis(long h) { R r; GetWindowRect(new IntPtr(h), out r); Q q; q.X = (r.L + r.Ri) / 2; q.Y = (r.T + r.B) / 2;
    return GetAncestor(WindowFromPoint(q), 2).ToInt64() == h; }
  public static bool Fg(long h) { return GetForegroundWindow().ToInt64() == h; }
}
'@
foreach ($m in 'base', 'destroy', 'sysmodal', 'owner') {
  $p = Start-Process -FilePath "$PSScriptRoot\probe-$m.exe" -PassThru
  $h = 0; $until = (Get-Date).AddSeconds(20)
  while (-not $h -and (Get-Date) -lt $until) { Start-Sleep -Milliseconds 200; $h = [P]::Box($p.Id) }
  if (-not $h) { "$m : keine Box"; Stop-Process -Id $p.Id -Force; continue }
  $top = [P]::Top($h); $fg = [P]::Fg($h)
  Start-Process "$env:WINDIR\System32\notepad.exe" -WindowStyle Maximized
  Start-Sleep -Seconds 3
  $np = @(Get-Process notepad -ErrorAction SilentlyContinue | Where-Object MainWindowHandle).Count
  $vis = [P]::Vis($h); $top2 = [P]::Top($h)
  "$m : topmost=$top vordergrund=$fg | editor=$np danach topmost=$top2 sichtbar=$vis"
  Get-Process notepad -ErrorAction SilentlyContinue | Stop-Process -Force
  [void][P]::PostMessage([IntPtr]$h, 0x0111, [IntPtr]2, [IntPtr]::Zero)
  $p.WaitForExit(10000) | Out-Null
}
