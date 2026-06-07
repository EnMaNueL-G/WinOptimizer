@echo off
:: WinOptimizer — Launcher con solicitud de UAC si no hay permisos de admin
:: github.com/EnMaNueL-G/WinOptimizer

net session >nul 2>&1
if %errorLevel% == 0 (
    :: Ya es administrador — ejecutar directamente
    PowerShell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0WinOptimizer.ps1"
) else (
    :: Solicitar elevacion UAC
    PowerShell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
        "Start-Process PowerShell '-NoProfile -ExecutionPolicy Bypass -File \"%~dp0WinOptimizer.ps1\"' -Verb RunAs"
)
