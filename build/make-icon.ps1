# Erzeugt Assets\WidgetTea.ico (16–256 px, PNG-komprimiert): 3x3-Kacheln in den Heatmap-Blautönen.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$out = Join-Path $PSScriptRoot '..\Assets\WidgetTea.ico'
New-Item -ItemType Directory -Force (Split-Path $out) | Out-Null

$shades = @('#26406A', '#305690', '#4573BC', '#7DA2DC') | ForEach-Object { [System.Drawing.ColorTranslator]::FromHtml($_) }
$pattern = 1, 3, 2, 0, 2, 3, 3, 1, 2
$sizes = 16, 24, 32, 48, 64, 256

$images = foreach ($size in $sizes) {
    $bmp = New-Object System.Drawing.Bitmap $size, $size
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.Clear([System.Drawing.Color]::Transparent)
    $gap = [Math]::Max(1, [Math]::Round($size / 16))
    $cell = ($size - 2 * $gap) / 3
    for ($i = 0; $i -lt 9; $i++) {
        $x = ($i % 3) * ($cell + $gap); $y = [Math]::Floor($i / 3) * ($cell + $gap)
        $r = [Math]::Max(1, $cell / 5)
        $path = New-Object System.Drawing.Drawing2D.GraphicsPath
        $path.AddArc($x, $y, 2 * $r, 2 * $r, 180, 90)
        $path.AddArc($x + $cell - 2 * $r, $y, 2 * $r, 2 * $r, 270, 90)
        $path.AddArc($x + $cell - 2 * $r, $y + $cell - 2 * $r, 2 * $r, 2 * $r, 0, 90)
        $path.AddArc($x, $y + $cell - 2 * $r, 2 * $r, 2 * $r, 90, 90)
        $path.CloseFigure()
        $brush = New-Object System.Drawing.SolidBrush $shades[$pattern[$i]]
        $g.FillPath($brush, $path)
    }
    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    , @($size, $ms.ToArray())
}

$fs = [System.IO.File]::Create($out)
$w = New-Object System.IO.BinaryWriter $fs
$w.Write([uint16]0); $w.Write([uint16]1); $w.Write([uint16]$images.Count)
$offset = 6 + 16 * $images.Count
foreach ($img in $images) {
    $s = if ($img[0] -ge 256) { 0 } else { $img[0] }
    $w.Write([byte]$s); $w.Write([byte]$s); $w.Write([byte]0); $w.Write([byte]0)
    $w.Write([uint16]1); $w.Write([uint16]32); $w.Write([uint32]$img[1].Length); $w.Write([uint32]$offset)
    $offset += $img[1].Length
}
foreach ($img in $images) { $w.Write($img[1]) }
$w.Close()
Write-Host "Icon: $out"
