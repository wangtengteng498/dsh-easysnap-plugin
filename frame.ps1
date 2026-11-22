param(
    [Parameter(Mandatory = $true)][string]$Out,
    [string]$DoneMarker = ""
)

# DPI awareness must be declared before any window is created.
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class DpiAware {
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
    public static void Apply() {
        try { SetProcessDpiAwarenessContext(new IntPtr(-4)); return; } catch { }
        try { SetProcessDPIAware(); } catch { }
    }
}
'@ -ErrorAction SilentlyContinue
try { [DpiAware]::Apply() } catch { }

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Keep the frame above other topmost windows without stealing focus.
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class TopMostKeeper {
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr insertAfter, int x, int y, int cx, int cy, uint flags);
}
'@ -ErrorAction SilentlyContinue

$logPath = Join-Path $env:TEMP 'dsh-easysnap-plugin-frame.log'
function Log($m) {
    try { Add-Content -Path $logPath -Value ((Get-Date).ToString('HH:mm:ss.fff') + ' ' + $m) -Encoding UTF8 } catch { }
}
Log ('start pid=' + $PID + ' v=4')

# Single instance: close the previous frame tracked by a pid file.
$pidFile = Join-Path $env:TEMP 'dsh-easysnap-plugin-frame.pid'
try {
    if (Test-Path $pidFile) {
        $oldPid = [int](Get-Content $pidFile -ErrorAction SilentlyContinue | Select-Object -First 1)
        if ($oldPid -gt 0 -and $oldPid -ne $PID) {
            $op = Get-Process -Id $oldPid -ErrorAction SilentlyContinue
            if ($op -and $op.ProcessName -like 'powershell*') {
                Log ('closing stale frame pid=' + $oldPid)
                Stop-Process -Id $oldPid -Force -ErrorAction SilentlyContinue
            }
        }
    }
} catch { }
try { Set-Content -Path $pidFile -Value $PID -Encoding ASCII } catch { }

$ErrorActionPreference = 'Stop'
try {

$W = 520
$H = 320
$edge = 8           # top/left/right border thickness (also the grab size)
$barH = 36          # bottom bar: drag handle + buttons; no resize here
$cornerZone = 26    # corner grab radius (top corners only)
$accent = [System.Drawing.Color]::FromArgb(47, 124, 246)
$barColor = [System.Drawing.Color]::FromArgb(26, 28, 34)
$minW = 200
$minH = 120

$screen = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$x = [int](($screen.Width - $W) / 2 + $screen.Left)
$y = [int](($screen.Height - $H) / 2 + $screen.Top)

$form = New-Object System.Windows.Forms.Form
$form.FormBorderStyle = 'None'
$form.StartPosition = 'Manual'
$form.TopMost = $true
$form.ShowInTaskbar = $false
$form.BackColor = $barColor
$form.Location = New-Object System.Drawing.Point $x, $y
$form.Size = New-Object System.Drawing.Size $W, $H

# Window region: frame ring + bottom bar; the capture area is really absent,
# so clicks there reach the app underneath.
function Update-Region {
    try {
        $gp = New-Object System.Drawing.Drawing2D.GraphicsPath
        $gp.FillMode = [System.Drawing.Drawing2D.FillMode]::Alternate
        $gp.AddRectangle((New-Object System.Drawing.Rectangle 0, 0, $form.Width, $form.Height))
        $iw = $form.Width - 2 * $edge
        $ih = $form.Height - $edge - $barH
        if ($iw -ge 1 -and $ih -ge 1) {
            $gp.AddRectangle((New-Object System.Drawing.Rectangle $edge, $edge, $iw, $ih))
        }
        $old = $form.Region
        $form.Region = New-Object System.Drawing.Region $gp
        if ($old) { $old.Dispose() }
        $gp.Dispose()
    } catch {
        Log ('region ERROR: ' + $_.Exception.Message)
    }
}

function Add-Panel($l, $t, $w, $h, $color) {
    $p = New-Object System.Windows.Forms.Panel
    $p.BackColor = $color
    $p.Location = New-Object System.Drawing.Point $l, $t
    $p.Size = New-Object System.Drawing.Size $w, $h
    $form.Controls.Add($p)
    return $p
}

$edgeTop = Add-Panel 0 0 $W $edge $accent
$edgeLeft = Add-Panel 0 0 $edge $H $accent
$edgeRight = Add-Panel ($W - $edge) 0 $edge $H $accent
$bar = Add-Panel 0 ($H - $barH) $W $barH $barColor

$snap = New-Object System.Windows.Forms.Button
$snap.Text = 'Snap'
$snap.Size = New-Object System.Drawing.Size 70, 24
$snap.Location = New-Object System.Drawing.Point ($W - 154), 6
$snap.FlatStyle = 'Flat'
$snap.BackColor = $accent
$snap.ForeColor = [System.Drawing.Color]::White
$snap.FlatAppearance.BorderSize = 0
$bar.Controls.Add($snap)

$close = New-Object System.Windows.Forms.Button
$close.Text = 'X'
$close.Size = New-Object System.Drawing.Size 30, 24
$close.Location = New-Object System.Drawing.Point ($W - 78), 6
$close.FlatStyle = 'Flat'
$close.BackColor = [System.Drawing.Color]::FromArgb(70, 74, 84)
$close.ForeColor = [System.Drawing.Color]::White
$close.FlatAppearance.BorderSize = 0
$bar.Controls.Add($close)

$hint = New-Object System.Windows.Forms.Label
$hint.Text = 'drag to move   |   edges to resize'
$hint.AutoSize = $false
$hint.AutoEllipsis = $true
$hint.Location = New-Object System.Drawing.Point 10, 9
$hint.Size = New-Object System.Drawing.Size ($W - 190), 22
$hint.ForeColor = [System.Drawing.Color]::FromArgb(198, 205, 216)
# Keep it enabled so the text is not greyed out; the label gets the same move
# handlers as the bar, so dragging on the text still drags the frame.
$bar.Controls.Add($hint)

function Update-Layout {
    try {
        $edgeTop.SetBounds(0, 0, $form.Width, $edge)
        $edgeLeft.SetBounds(0, 0, $edge, ($form.Height - $barH))
        $edgeRight.SetBounds(($form.Width - $edge), 0, $edge, ($form.Height - $barH))
        $bar.SetBounds(0, ($form.Height - $barH), $form.Width, $barH)
        $hint.SetBounds(10, 9, ($bar.Width - 190), 22)
        $snap.Location = New-Object System.Drawing.Point ($bar.Width - 154), 6
        $close.Location = New-Object System.Drawing.Point ($bar.Width - 78), 6
    } catch {
        Log ('layout ERROR: ' + $_.Exception.Message)
    }
    Update-Region
}

# Direction for resizing: top / left / right only. No bottom resize at all.
function DirAt($px, $py) {
    $relX = $px - $form.Left
    $relY = $py - $form.Top
    $nearL = $relX -le $cornerZone
    $nearR = $relX -ge ($form.Width - $cornerZone)
    $nearT = $relY -le $cornerZone
    if ($nearT -and $nearL) { return 'nw' }
    if ($nearT -and $nearR) { return 'ne' }
    if ($nearT) { return 'n' }
    if ($nearL) { return 'w' }
    if ($nearR) { return 'e' }
    return ''
}

function SetResizeCursor($ctrl, $dir) {
    try {
        switch ($dir) {
            'n' { $ctrl.Cursor = [System.Windows.Forms.Cursors]::SizeNS }
            'e' { $ctrl.Cursor = [System.Windows.Forms.Cursors]::SizeWE }
            'w' { $ctrl.Cursor = [System.Windows.Forms.Cursors]::SizeWE }
            'nw' { $ctrl.Cursor = [System.Windows.Forms.Cursors]::SizeNWSE }
            'ne' { $ctrl.Cursor = [System.Windows.Forms.Cursors]::SizeNESW }
            default { $ctrl.Cursor = [System.Windows.Forms.Cursors]::Default }
        }
    } catch { }
}

$script:drag = $null

# Bottom bar: always move.
function Attach-Move($ctrl) {
    $ctrl.Add_MouseDown({
        param($s, $e)
        if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }
        try {
            $p = [System.Windows.Forms.Cursor]::Position
            $script:drag = @{ mode = 'move'; mx = $p.X; my = $p.Y; x = $form.Left; y = $form.Top }
            $s.Capture = $true
            Log ('move down at ' + $p.X + ',' + $p.Y)
        } catch { }
    })
    $ctrl.Add_MouseMove({
        param($s, $e)
        if ($null -eq $script:drag) { return }
        try {
            $p = [System.Windows.Forms.Cursor]::Position
            $form.Left = $script:drag.x + ($p.X - $script:drag.mx)
            $form.Top = $script:drag.y + ($p.Y - $script:drag.my)
        } catch { }
    })
    $ctrl.Add_MouseUp({
        param($s, $e)
        $script:drag = $null
        try { $s.Capture = $false } catch { }
        Log ('move up at ' + $form.Left + ',' + $form.Top)
    })
}

# Top / side borders: resize only (never move).
function Attach-Resize($ctrl) {
    $ctrl.Add_MouseDown({
        param($s, $e)
        if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }
        try {
            $p = [System.Windows.Forms.Cursor]::Position
            $dir = DirAt $p.X $p.Y
            if ($dir -eq '') { return }
            $script:drag = @{
                mode = 'resize'; dir = $dir
                mx = $p.X; my = $p.Y
                x = $form.Left; y = $form.Top; w = $form.Width; h = $form.Height
            }
            $s.Capture = $true
            Log ('resize down at ' + $p.X + ',' + $p.Y + ' dir=' + $dir)
        } catch { }
    })
    $ctrl.Add_MouseMove({
        param($s, $e)
        if ($null -eq $script:drag) {
            try { $p0 = [System.Windows.Forms.Cursor]::Position; SetResizeCursor $s (DirAt $p0.X $p0.Y) } catch { }
            return
        }
        try {
            $p = [System.Windows.Forms.Cursor]::Position
            $dx = $p.X - $script:drag.mx
            $dy = $p.Y - $script:drag.my
            $nx = $script:drag.x; $ny = $script:drag.y
            $nw = $script:drag.w; $nh = $script:drag.h
            if ($script:drag.dir.Contains('w')) { $nw = $script:drag.w - $dx; $nx = $script:drag.x + $dx }
            if ($script:drag.dir.Contains('e')) { $nw = $script:drag.w + $dx }
            if ($script:drag.dir.Contains('n')) { $nh = $script:drag.h - $dy; $ny = $script:drag.y + $dy }
            if ($nw -lt $minW) {
                if ($script:drag.dir.Contains('w')) { $nx = $script:drag.x + ($script:drag.w - $minW) }
                $nw = $minW
            }
            if ($nh -lt $minH) {
                if ($script:drag.dir.Contains('n')) { $ny = $script:drag.y + ($script:drag.h - $minH) }
                $nh = $minH
            }
            $form.SetBounds($nx, $ny, $nw, $nh)
        } catch { }
    })
    $ctrl.Add_MouseUp({
        param($s, $e)
        Log ('resize up size=' + $form.Width + 'x' + $form.Height)
        $script:drag = $null
        try { $s.Capture = $false } catch { }
    })
}

Attach-Move $bar
Attach-Move $hint
$hint.Add_MouseDown({ param($s, $e) $bar.Focus() })
Attach-Resize $edgeTop
Attach-Resize $edgeLeft
Attach-Resize $edgeRight

# Snap the visible inner area, keep the frame open.
$script:snapNow = {
    $w = $form.Width - 2 * $edge
    $h = $form.Height - $edge - $barH
    $lx = $form.Left + $edge
    $ly = $form.Top + $edge
    Log ('snap inner ' + $lx + ',' + $ly + ' ' + $w + 'x' + $h)
    $form.Hide()
    Start-Sleep -Milliseconds 150
    try {
        $bmp = New-Object System.Drawing.Bitmap $w, $h
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.CopyFromScreen($lx, $ly, 0, 0, (New-Object System.Drawing.Size $w, $h))
        $g.Dispose()
        $dir = Split-Path -Parent $Out
        if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        $bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose()
        if ($DoneMarker -ne "") { Set-Content -Path $DoneMarker -Value ((Get-Date).ToUniversalTime().Ticks) -Encoding ASCII }
        Log 'snap saved'
    } catch {
        Log ('snap failed: ' + $_.Exception.Message)
    }
    $form.Show()
    $form.Activate()
    $hint.Text = 'saved ' + (Get-Date).ToString('HH:mm:ss')
}

$snap.Add_Click({ & $script:snapNow })
$close.Add_Click({ $form.Close() })
$form.Add_KeyDown({
    param($s, $e)
    if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Escape) { $form.Close() }
    elseif ($e.KeyCode -eq [System.Windows.Forms.Keys]::Enter) { & $script:snapNow }
})
$form.KeyPreview = $true
$form.Add_Resize({ Update-Layout })
$form.Add_Shown({ Update-Layout })
Update-Layout

Log ('form built ' + $form.Width + 'x' + $form.Height + ' at ' + $form.Left + ',' + $form.Top + ' dpi=' + $form.DeviceDpi)

$keep = New-Object System.Windows.Forms.Timer
$keep.Interval = 300
$keep.Add_Tick({
    try {
        if ($form.Visible) {
            [void][TopMostKeeper]::SetWindowPos($form.Handle, [intptr]-1, 0, 0, 0, 0, 0x0001 -bor 0x0002 -bor 0x0010)
        }
    } catch { }
})
$keep.Start()

[void]$form.ShowDialog()
$keep.Stop()
Log 'form closed'

} catch {
    Log ('ERROR: ' + $_.Exception.GetType().Name + ': ' + $_.Exception.Message)
    Log ('AT: ' + $_.InvocationInfo.PositionMessage)
}
