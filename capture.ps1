param(
    [string]$Out = "",
    [string]$Hwnd = "",
    [switch]$List
)

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

$sig = @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public class SnapWin {
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr hWnd, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT r);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdc, uint flags);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }

    public static System.Collections.Generic.List<string> List() {
        var list = new System.Collections.Generic.List<string>();
        EnumWindows((h, l) => {
            if (!IsWindowVisible(h)) return true;
            var sb = new StringBuilder(512);
            GetWindowText(h, sb, 512);
            string t = sb.ToString();
            if (t.Length == 0) return true;
            RECT r; GetWindowRect(h, out r);
            int w = r.Right - r.Left, hh = r.Bottom - r.Top;
            if (w < 120 || hh < 90) return true;
            string esc = t.Replace("\\", "\\\\").Replace("\"", "\\\"");
            list.Add("{\"hwnd\":" + h.ToInt64() + ",\"title\":\"" + esc + "\",\"w\":" + w + ",\"h\":" + hh + "}");
            return true;
        }, IntPtr.Zero);
        return list;
    }

    public static bool Grab(IntPtr hWnd, string path) {
        RECT r; if (!GetWindowRect(hWnd, out r)) return false;
        int w = r.Right - r.Left, hh = r.Bottom - r.Top;
        if (w <= 0 || hh <= 0) return false;
        using (var bmp = new System.Drawing.Bitmap(w, hh))
        using (var g = System.Drawing.Graphics.FromImage(bmp)) {
            IntPtr hdc = g.GetHdc();
            bool ok = PrintWindow(hWnd, hdc, 2); // PW_RENDERFULLCONTENT
            g.ReleaseHdc(hdc);
            if (!ok) g.CopyFromScreen(r.Left, r.Top, 0, 0, new System.Drawing.Size(w, hh));
            bmp.Save(path, System.Drawing.Imaging.ImageFormat.Png);
        }
        return true;
    }
}
'@
if (-not ("SnapWin" -as [type])) { Add-Type -TypeDefinition $sig -ReferencedAssemblies System.Drawing }

if ($List) {
    $items = [SnapWin]::List()
    "[" + ($items -join ",") + "]"
    return
}

if ($Out -eq "") { Write-Error "missing -Out"; exit 1 }

if ($Hwnd -ne "") {
    $h = [IntPtr]::new([Int64]$Hwnd)
    if (-not [SnapWin]::Grab($h, $Out)) { Write-Error "PrintWindow failed"; exit 1 }
} else {
    $b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($b.Left, $b.Top, 0, 0, (New-Object System.Drawing.Size $b.Width, $b.Height))
    $g.Dispose()
    $bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
}
"OK"
