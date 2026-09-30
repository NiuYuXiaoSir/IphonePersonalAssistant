## 生成 App 图标（1024x1024 PNG）。
##
## 为什么在 Windows 上画：这个项目没有 Mac，图标又必须是一张实实在在的 PNG。
## System.Drawing 在 Windows 上就能画，所以图标也是「脚本生成 + 提交产物」，
## 想改配色或形状改这个脚本重跑一次即可：
##     powershell -NoProfile -ExecutionPolicy Bypass -File tools/make-appicon.ps1
##
## 图形：一个说话气泡里放一个对勾——「说出来，它替你记下来」。
## 小尺寸下只看得清轮廓，所以不放任何细节。
##
## 注意：这里一律用 ::new() 构造 .NET 对象，不用 New-Object -ArgumentList。
## 后者在类型能隐式转换的时候容易挑不到重载（角度的 Single、矩形的结构体）。

Add-Type -AssemblyName System.Drawing

$size = 1024
$bmp = [System.Drawing.Bitmap]::new($size, $size, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality

# 背景：上浅下深的蓝
$rect = [System.Drawing.Rectangle]::new(0, 0, $size, $size)
$top = [System.Drawing.Color]::FromArgb(255, 82, 150, 255)
$bottom = [System.Drawing.Color]::FromArgb(255, 26, 58, 168)
## 第四个参数用 LinearGradientMode 而不是角度：角度的重载只接受 Single，
## PowerShell 的绑定器在 (Single) 和 (LinearGradientMode) 之间挑不出来，会直接报找不到重载
$bg = [System.Drawing.Drawing2D.LinearGradientBrush]::new($rect, $top, $bottom, [System.Drawing.Drawing2D.LinearGradientMode]::Vertical)
$g.FillRectangle($bg, $rect)

# 气泡：圆角矩形 + 左下角一个小尾巴
$bx = 196; $by = 236; $bw = 632; $bh = 468; $br = 140
$bubble = [System.Drawing.Drawing2D.GraphicsPath]::new()
$bubble.AddArc($bx, $by, $br, $br, 180, 90)
$bubble.AddArc($bx + $bw - $br, $by, $br, $br, 270, 90)
$bubble.AddArc($bx + $bw - $br, $by + $bh - $br, $br, $br, 0, 90)
$bubble.AddArc($bx, $by + $bh - $br, $br, $br, 90, 90)
$bubble.CloseFigure()

$tail = [System.Drawing.Drawing2D.GraphicsPath]::new()
$tail.AddPolygon([System.Drawing.Point[]]@(
    [System.Drawing.Point]::new(300, 600),
    [System.Drawing.Point]::new(300, 812),
    [System.Drawing.Point]::new(452, 672)
))

$white = [System.Drawing.Brushes]::White
$g.FillPath($white, $bubble)
$g.FillPath($white, $tail)

# 对勾：和背景同色系，压在白色气泡上
$pen = [System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb(255, 30, 74, 196), [single]74)
$pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
$pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
$pen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
$g.DrawLines($pen, [System.Drawing.Point[]]@(
    [System.Drawing.Point]::new(356, 470),
    [System.Drawing.Point]::new(464, 578),
    [System.Drawing.Point]::new(672, 376)
))

$g.Dispose()

$root = Split-Path -Parent $PSScriptRoot
$dir = Join-Path $root "ios\IPhoneAssistant\Assets.xcassets\AppIcon.appiconset"
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$bmp.Save((Join-Path $dir "AppIcon.png"), [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()
Write-Output "已生成：$dir\AppIcon.png"
