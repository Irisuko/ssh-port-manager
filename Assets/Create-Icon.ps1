# Rebuild the original application icon with built-in Windows drawing libraries.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$sizes = @(16, 32, 48, 64, 128, 256)
$images = @()
foreach ($size in $sizes) {
    $bitmap = New-Object Drawing.Bitmap($size, $size)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    $background = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(22, 35, 60))
    $accent = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(91, 219, 203))
    $pen = New-Object Drawing.Pen([Drawing.Color]::White, [single]18)
    $outline = New-Object Drawing.Drawing2D.GraphicsPath
    $memory = New-Object IO.MemoryStream
    try {
        $graphics.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $graphics.ScaleTransform([single]($size / 256.0), [single]($size / 256.0))
        $graphics.Clear([Drawing.Color]::Transparent)
        $outline.AddArc(12, 12, 64, 64, 180, 90)
        $outline.AddArc(180, 12, 64, 64, 270, 90)
        $outline.AddArc(180, 180, 64, 64, 0, 90)
        $outline.AddArc(12, 180, 64, 64, 90, 90)
        $outline.CloseFigure()
        $graphics.FillPath($background, $outline)
        $pen.StartCap = [Drawing.Drawing2D.LineCap]::Round
        $pen.EndCap = [Drawing.Drawing2D.LineCap]::Round
        $graphics.DrawLine($pen, 65, 90, 105, 128)
        $graphics.DrawLine($pen, 105, 128, 65, 166)
        $graphics.DrawLine($pen, 137, 166, 190, 166)
        $graphics.FillRectangle($accent, 156, 73, 41, 10)
        $graphics.FillEllipse($accent, 145, 67, 22, 22)
        $graphics.FillEllipse($accent, 185, 67, 22, 22)
        $bitmap.Save($memory, [Drawing.Imaging.ImageFormat]::Png)
        $images += ,$memory.ToArray()
    }
    finally {
        $memory.Dispose(); $outline.Dispose(); $pen.Dispose(); $accent.Dispose(); $background.Dispose(); $graphics.Dispose(); $bitmap.Dispose()
    }
}
$output = Join-Path $PSScriptRoot 'SshPortManager.ico'
$file = [IO.File]::Open($output, [IO.FileMode]::Create, [IO.FileAccess]::Write)
$writer = New-Object IO.BinaryWriter($file)
try {
    $writer.Write([UInt16]0); $writer.Write([UInt16]1); $writer.Write([UInt16]$sizes.Count)
    $offset = 6 + 16 * $sizes.Count
    for ($i = 0; $i -lt $sizes.Count; $i++) {
        $dimension = if ($sizes[$i] -eq 256) { 0 } else { $sizes[$i] }
        $writer.Write([byte]$dimension); $writer.Write([byte]$dimension)
        $writer.Write([byte]0); $writer.Write([byte]0)
        $writer.Write([UInt16]1); $writer.Write([UInt16]32)
        $writer.Write([UInt32]$images[$i].Length); $writer.Write([UInt32]$offset)
        $offset += $images[$i].Length
    }
    foreach ($bytes in $images) { $writer.Write([byte[]]$bytes) }
}
finally { $writer.Dispose(); $file.Dispose() }
Write-Output ('Created original icon: ' + $output)
