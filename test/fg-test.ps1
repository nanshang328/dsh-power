# Plumbing test: run the exact Win32 sequence from restart-dsh.ps1 against the window
# that is ALREADY in the foreground (SetForegroundWindow on it must succeed and stay).
$ErrorActionPreference = 'Continue'
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace DshPower {
  public static class Win32 {
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);
    [DllImport("user32.dll")] public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, IntPtr dwExtraInfo);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
  }
}
'@
"add-type OK"
$handle = [DshPower.Win32]::GetForegroundWindow()
"fg handle = $handle"
if ($handle -eq [IntPtr]::Zero) { 'FAIL: no foreground window'; exit 1 }
$fgPid = [uint32]0
$fgThread = [DshPower.Win32]::GetWindowThreadProcessId($handle, [ref]$fgPid)
$myThread = [DshPower.Win32]::GetCurrentThreadId()
"fg pid=$fgPid fgThread=$fgThread myThread=$myThread"
$attached = $false
if ($fgThread -ne 0 -and $fgThread -ne $myThread) {
  $attached = [DshPower.Win32]::AttachThreadInput($myThread, $fgThread, $true)
}
"D attached=$attached"
[DshPower.Win32]::keybd_event(0x12, 0, 0, [IntPtr]::Zero)
[DshPower.Win32]::keybd_event(0x12, 0, 2, [IntPtr]::Zero)
"iconic = " + [DshPower.Win32]::IsIconic($handle)
"bwt = " + [DshPower.Win32]::BringWindowToTop($handle)
$ok = [DshPower.Win32]::SetForegroundWindow($handle)
if ($attached) { $null = [DshPower.Win32]::AttachThreadInput($myThread, $fgThread, $false) }
"sfw = $ok"
$still = [DshPower.Win32]::GetForegroundWindow()
"fg after = $still"
if ($ok -and ($still -eq $handle)) { 'PASS'; exit 0 } else { 'FAIL'; exit 1 }
