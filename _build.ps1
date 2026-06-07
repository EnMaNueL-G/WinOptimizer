# _build.ps1 — Genera icon.ico y compila WinOptimizer.exe
# Ejecutar desde: C:\Users\usuario\Desktop\SER\WinOptimizer\
Set-Location $PSScriptRoot

# ── 1. Crear icon.ico ─────────────────────────────────────────────────────
Write-Host "[1/3] Creando icon.ico..." -ForegroundColor Cyan
Add-Type -AssemblyName System.Drawing

function New-IcoFile {
    param([string]$OutPath, [int]$Size = 48)

    $bmp = New-Object System.Drawing.Bitmap($Size, $Size)
    $g   = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode      = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.TextRenderingHint  = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
    $g.InterpolationMode  = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic

    # Fondo naranja
    $bgColor = [System.Drawing.Color]::FromArgb(255, 220, 110, 0)
    $g.Clear($bgColor)

    # Borde inferior oscuro (profundidad)
    $shadowBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(60, 0, 0, 0))
    $g.FillRectangle($shadowBrush, 0, [int]($Size * 0.82), $Size, [int]($Size * 0.18))
    $shadowBrush.Dispose()

    # Letra "W" centrada, blanca
    $fs   = [int]($Size * 0.60)
    $font = New-Object System.Drawing.Font("Segoe UI", $fs, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
    $sf   = New-Object System.Drawing.StringFormat
    $sf.Alignment     = [System.Drawing.StringAlignment]::Center
    $sf.LineAlignment = [System.Drawing.StringAlignment]::Center
    $rect = [System.Drawing.RectangleF]::new(0, -2, $Size, $Size)

    # Sombra del texto
    $shadowF = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(80, 0, 0, 0))
    $rectS   = [System.Drawing.RectangleF]::new(1, 0, $Size, $Size)
    $g.DrawString("W", $font, $shadowF, $rectS, $sf)
    $shadowF.Dispose()

    # Texto principal
    $g.DrawString("W", $font, [System.Drawing.Brushes]::White, $rect, $sf)
    $font.Dispose()
    $g.Dispose()

    # Guardar PNG en memoria
    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $pngBytes = $ms.ToArray()
    $ms.Dispose()
    $bmp.Dispose()

    # Construir ICO (formato: ICONDIR + ICONDIRENTRY + datos PNG)
    $ico = New-Object System.IO.MemoryStream
    $w   = New-Object System.IO.BinaryWriter($ico)

    # ICONDIR header (6 bytes)
    $w.Write([uint16]0)   # reserved
    $w.Write([uint16]1)   # type=1 (icon)
    $w.Write([uint16]1)   # count=1 image

    # ICONDIRENTRY (16 bytes)
    $bSz = if ($Size -ge 256) { 0 } else { [byte]$Size }
    $w.Write([byte]$bSz)                   # width
    $w.Write([byte]$bSz)                   # height
    $w.Write([byte]0)                      # colorCount (0 = true color)
    $w.Write([byte]0)                      # reserved
    $w.Write([uint16]1)                    # planes
    $w.Write([uint16]32)                   # bitCount
    $w.Write([uint32]$pngBytes.Count)      # bytesInRes
    $w.Write([uint32]22)                   # offset (6 header + 16 entry = 22)

    # Datos de imagen (PNG)
    $w.Write($pngBytes)
    $w.Flush()

    [System.IO.File]::WriteAllBytes($OutPath, $ico.ToArray())
    $ico.Dispose()
    Write-Host "   icon.ico creado ($Size x $Size px, $($pngBytes.Count) bytes)" -ForegroundColor Green
}

New-IcoFile -OutPath "icon.ico" -Size 48

# ── 2. Instalar PS2EXE si no esta disponible ─────────────────────────────
Write-Host "[2/3] Verificando PS2EXE..." -ForegroundColor Cyan

if (-not (Get-Module -ListAvailable -Name ps2exe)) {
    Write-Host "   Instalando ps2exe desde PSGallery..." -ForegroundColor Yellow
    try {
        Install-Module -Name ps2exe -Scope CurrentUser -Force -AllowClobber -Repository PSGallery -ErrorAction Stop
        Write-Host "   ps2exe instalado correctamente" -ForegroundColor Green
    } catch {
        Write-Host "   ERROR instalando ps2exe: $_" -ForegroundColor Red
        Write-Host "   Intenta: Install-Module -Name ps2exe -Scope CurrentUser -Force" -ForegroundColor Yellow
        exit 1
    }
} else {
    Write-Host "   ps2exe ya disponible" -ForegroundColor Green
}

# ── 3. Compilar WinOptimizer.exe ─────────────────────────────────────────
Write-Host "[3/3] Compilando WinOptimizer.exe..." -ForegroundColor Cyan

Import-Module ps2exe -ErrorAction Stop

$buildParams = @{
    InputFile   = "WinOptimizer.ps1"
    OutputFile  = "WinOptimizer.exe"
    IconFile    = "icon.ico"
    NoConsole   = $true
    Title       = "WinOptimizer"
    Description = "Optimizador de rendimiento para Windows 10/11"
    Company     = "Enmanuel Gil"
    Copyright   = "(c) 2026 Enmanuel Gil"
    Version     = "2.0.0.0"
    NoOutput    = $false
}

try {
    Invoke-PS2EXE @buildParams
    if (Test-Path "WinOptimizer.exe") {
        $size = (Get-Item "WinOptimizer.exe").Length
        Write-Host "   WinOptimizer.exe compilado correctamente ($([int]($size/1KB)) KB)" -ForegroundColor Green
    } else {
        Write-Host "   ADVERTENCIA: exe no generado. Verificar PS2EXE." -ForegroundColor Yellow
    }
} catch {
    Write-Host "   ERROR compilando: $_" -ForegroundColor Red
}

Write-Host ""
Write-Host "Build completado." -ForegroundColor Cyan
Write-Host "  Archivos generados:" -ForegroundColor White
Get-ChildItem "WinOptimizer.exe", "icon.ico" -ErrorAction SilentlyContinue | ForEach-Object {
    Write-Host "    $($_.Name)  ($([int]($_.Length/1KB)) KB)" -ForegroundColor Gray
}
