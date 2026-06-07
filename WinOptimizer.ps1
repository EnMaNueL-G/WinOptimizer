#Requires -Version 5.1
<#
.SYNOPSIS
    WinOptimizer v2.0.0
    Optimizador de rendimiento para Windows 10/11
    Enmanuel Gil — github.com/EnMaNueL-G
.DESCRIPTION
    Monitorea CPU, RAM y disco en tiempo real.
    Libera memoria, limpia archivos temporales y gestiona el inicio de Windows.
    Disenado para ser rapido, liviano y sin dependencias externas.
#>

Set-StrictMode -Off
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

# ============================================================
#  DATOS COMPARTIDOS: UI <-> Worker (thread-safe)
# ============================================================
$script:d = [hashtable]::Synchronized(@{
    CpuPct    = 0
    FreeMB    = 0L
    TotalMB   = 32768L
    CpuName   = 'Detectando...'
    DiskFree  = 0L
    DiskTotal = 1L
    Tick      = 0
})

# ============================================================
#  BACKGROUND WORKER — lee contadores sin bloquear el UI
#  Get-Counter tarda ~1s cada llamada; aqui corre en otro hilo
# ============================================================
function Start-Worker {
    $rs = [RunspaceFactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.ThreadOptions  = 'ReuseThread'
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('d', $script:d)

    $ps = [PowerShell]::Create()
    $ps.Runspace = $rs
    $null = $ps.AddScript({
        # CimInstance: se llama UNA sola vez al inicio del worker
        try {
            $os  = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
            $cpu = Get-CimInstance Win32_Processor       -ErrorAction Stop | Select-Object -First 1
            $d['TotalMB'] = [long]($os.TotalVisibleMemorySize / 1KB)
            $d['CpuName'] = $cpu.Name.Trim() -replace '\s+', ' '
        } catch {
            $d['CpuName'] = 'No disponible'
        }

        # Loop cada 2 segundos — Performance Counters (rapidos)
        while ($true) {
            try {
                $d['CpuPct']    = [int]((Get-Counter '\Procesador(_Total)\% de tiempo de procesador').CounterSamples[0].CookedValue)
                $d['FreeMB']    = [long]((Get-Counter '\Memoria\Mbytes disponibles').CounterSamples[0].CookedValue)
                $dr             = Get-PSDrive C -ErrorAction Stop
                $d['DiskFree']  = $dr.Free
                $d['DiskTotal'] = $dr.Free + $dr.Used
                $d['Tick']++
            } catch {}
            Start-Sleep -Seconds 2
        }
    })
    $null = $ps.BeginInvoke()
    $script:bgPS = $ps
    $script:bgRS = $rs
}

# ============================================================
#  XAML — diseno inspirado en Mem Reduct
#  Compacto, funcional, sin ControlTemplate custom
# ============================================================
[xml]$xaml = @"
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="WinOptimizer"
    Width="370" Height="540"
    MinWidth="320" MinHeight="460"
    WindowStartupLocation="CenterScreen"
    Background="#F0F0F0"
    FontFamily="Segoe UI"
    FontSize="12">

    <DockPanel LastChildFill="True">

        <!-- ── MENU BAR ─────────────────────────────────── -->
        <Menu DockPanel.Dock="Top" Background="#F0F0F0" Padding="2,2">
            <MenuItem Header="Archivo">
                <MenuItem x:Name="miExit" Header="Salir"/>
            </MenuItem>
            <MenuItem Header="Ver">
                <MenuItem x:Name="miAlwaysTop" Header="Siempre visible" IsCheckable="True"/>
                <Separator/>
                <MenuItem x:Name="miRefresh" Header="Actualizar ahora"/>
            </MenuItem>
            <MenuItem Header="Herramientas">
                <MenuItem x:Name="miOptimize"  Header="Optimizar sistema"/>
                <MenuItem x:Name="miFreeRam"   Header="Liberar RAM"/>
                <Separator/>
                <MenuItem x:Name="miCleanTemp" Header="Limpiar archivos temporales..."/>
                <MenuItem x:Name="miStartup"   Header="Inicio de Windows..."/>
                <MenuItem x:Name="miPowerPlan" Header="Plan de energia..."/>
            </MenuItem>
            <MenuItem Header="Ayuda">
                <MenuItem x:Name="miAbout"  Header="Acerca de WinOptimizer"/>
                <MenuItem x:Name="miGithub" Header="Ver en GitHub"/>
            </MenuItem>
        </Menu>

        <!-- ── STATUS BAR ───────────────────────────────── -->
        <StatusBar DockPanel.Dock="Bottom" Background="#DEDEDE">
            <StatusBarItem Padding="6,2">
                <TextBlock x:Name="txtStatus" Text="Iniciando..." FontSize="11" Foreground="#444"/>
            </StatusBarItem>
        </StatusBar>

        <!-- ── BOTONES PRINCIPALES ──────────────────────── -->
        <Border DockPanel.Dock="Bottom" Padding="8,6"
                Background="#EBEBEB"
                BorderBrush="#CCCCCC" BorderThickness="0,1,0,0">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="5"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <Button x:Name="btnOptimize" Grid.Column="0"
                        Content="Optimizar sistema"
                        Padding="0,7" FontWeight="SemiBold" FontSize="12"
                        Background="#0078D4" Foreground="White"
                        BorderBrush="#005A9E" BorderThickness="1"
                        Cursor="Hand"/>
                <Button x:Name="btnFreeRam" Grid.Column="2"
                        Content="Liberar RAM"
                        Padding="14,7" FontSize="12"
                        Background="#EBEBEB" Foreground="#1A1A1A"
                        BorderBrush="#ADADAD" BorderThickness="1"
                        Cursor="Hand"/>
            </Grid>
        </Border>

        <!-- ── PANEL CENTRAL ─────────────────────────────── -->
        <ScrollViewer VerticalScrollBarVisibility="Auto"
                      HorizontalScrollBarVisibility="Disabled">
            <StackPanel Margin="8,6,8,6">

                <!-- Memoria fisica -->
                <GroupBox Margin="0,0,0,5" Padding="6,4,6,6"
                          BorderBrush="#AAAACC" Background="White">
                    <GroupBox.Header>
                        <TextBlock Text="Memoria fisica"
                                   FontWeight="SemiBold" Foreground="#003399" FontSize="11"/>
                    </GroupBox.Header>
                    <Grid>
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="140"/>
                        </Grid.ColumnDefinitions>
                        <Grid.RowDefinitions>
                            <RowDefinition Height="22"/>
                            <RowDefinition Height="22"/>
                            <RowDefinition Height="22"/>
                            <RowDefinition Height="14"/>
                        </Grid.RowDefinitions>
                        <TextBlock Grid.Row="0" Grid.Column="0" Text="En uso" VerticalAlignment="Center" Foreground="#555"/>
                        <TextBlock x:Name="lblRamPct"   Grid.Row="0" Grid.Column="1"
                                   HorizontalAlignment="Right" VerticalAlignment="Center"
                                   FontWeight="Bold" Foreground="#BB1100" Text="--%  /  -- GB"/>
                        <TextBlock Grid.Row="1" Grid.Column="0" Text="Libre" VerticalAlignment="Center" Foreground="#555"/>
                        <TextBlock x:Name="lblRamFree"  Grid.Row="1" Grid.Column="1"
                                   HorizontalAlignment="Right" VerticalAlignment="Center" Text="-- GB"/>
                        <TextBlock Grid.Row="2" Grid.Column="0" Text="Total disponible" VerticalAlignment="Center" Foreground="#555"/>
                        <TextBlock x:Name="lblRamTotal" Grid.Row="2" Grid.Column="1"
                                   HorizontalAlignment="Right" VerticalAlignment="Center" Text="-- GB"/>
                        <ProgressBar x:Name="barRam" Grid.Row="3" Grid.ColumnSpan="2"
                                     Minimum="0" Maximum="100" Value="0"
                                     Height="7" Margin="0,4,0,0"
                                     Background="#E0E0E0" Foreground="#CC2200"/>
                    </Grid>
                </GroupBox>

                <!-- Procesador CPU -->
                <GroupBox Margin="0,0,0,5" Padding="6,4,6,6"
                          BorderBrush="#AAAACC" Background="White">
                    <GroupBox.Header>
                        <TextBlock Text="Procesador (CPU)"
                                   FontWeight="SemiBold" Foreground="#003399" FontSize="11"/>
                    </GroupBox.Header>
                    <Grid>
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="140"/>
                        </Grid.ColumnDefinitions>
                        <Grid.RowDefinitions>
                            <RowDefinition Height="22"/>
                            <RowDefinition Height="22"/>
                            <RowDefinition Height="14"/>
                        </Grid.RowDefinitions>
                        <TextBlock Grid.Row="0" Grid.Column="0" Text="En uso" VerticalAlignment="Center" Foreground="#555"/>
                        <TextBlock x:Name="lblCpuPct"  Grid.Row="0" Grid.Column="1"
                                   HorizontalAlignment="Right" VerticalAlignment="Center"
                                   FontWeight="Bold" Foreground="#BB1100" Text="--%"/>
                        <TextBlock Grid.Row="1" Grid.Column="0" Text="Modelo" VerticalAlignment="Center" Foreground="#555"/>
                        <TextBlock x:Name="lblCpuName" Grid.Row="1" Grid.Column="1"
                                   HorizontalAlignment="Right" VerticalAlignment="Center"
                                   Foreground="#444" Text="..." TextTrimming="CharacterEllipsis"/>
                        <ProgressBar x:Name="barCpu" Grid.Row="2" Grid.ColumnSpan="2"
                                     Minimum="0" Maximum="100" Value="0"
                                     Height="7" Margin="0,4,0,0"
                                     Background="#E0E0E0" Foreground="#0078D4"/>
                    </Grid>
                </GroupBox>

                <!-- Almacenamiento C: -->
                <GroupBox Margin="0,0,0,5" Padding="6,4,6,6"
                          BorderBrush="#AAAACC" Background="White">
                    <GroupBox.Header>
                        <TextBlock Text="Almacenamiento (C:)"
                                   FontWeight="SemiBold" Foreground="#003399" FontSize="11"/>
                    </GroupBox.Header>
                    <Grid>
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="140"/>
                        </Grid.ColumnDefinitions>
                        <Grid.RowDefinitions>
                            <RowDefinition Height="22"/>
                            <RowDefinition Height="22"/>
                            <RowDefinition Height="22"/>
                            <RowDefinition Height="14"/>
                        </Grid.RowDefinitions>
                        <TextBlock Grid.Row="0" Grid.Column="0" Text="Libre" VerticalAlignment="Center" Foreground="#555"/>
                        <TextBlock x:Name="lblDiskFree"  Grid.Row="0" Grid.Column="1"
                                   HorizontalAlignment="Right" VerticalAlignment="Center"
                                   FontWeight="Bold" Foreground="#007722" Text="-- GB"/>
                        <TextBlock Grid.Row="1" Grid.Column="0" Text="Usado" VerticalAlignment="Center" Foreground="#555"/>
                        <TextBlock x:Name="lblDiskUsed"  Grid.Row="1" Grid.Column="1"
                                   HorizontalAlignment="Right" VerticalAlignment="Center" Text="-- GB"/>
                        <TextBlock Grid.Row="2" Grid.Column="0" Text="Total disponible" VerticalAlignment="Center" Foreground="#555"/>
                        <TextBlock x:Name="lblDiskTotal" Grid.Row="2" Grid.Column="1"
                                   HorizontalAlignment="Right" VerticalAlignment="Center" Text="-- GB"/>
                        <ProgressBar x:Name="barDisk" Grid.Row="3" Grid.ColumnSpan="2"
                                     Minimum="0" Maximum="100" Value="0"
                                     Height="7" Margin="0,4,0,0"
                                     Background="#E0E0E0" Foreground="#22AA44"/>
                    </Grid>
                </GroupBox>

                <!-- Registro de acciones -->
                <GroupBox Margin="0,0,0,0" Padding="4,2,4,4"
                          BorderBrush="#AAAACC" Background="White">
                    <GroupBox.Header>
                        <TextBlock Text="Registro de acciones"
                                   FontWeight="SemiBold" Foreground="#003399" FontSize="11"/>
                    </GroupBox.Header>
                    <TextBox x:Name="txtLog"
                             Height="70" IsReadOnly="True"
                             FontFamily="Consolas" FontSize="10"
                             Background="White" BorderThickness="0"
                             VerticalScrollBarVisibility="Auto"
                             HorizontalScrollBarVisibility="Disabled"
                             TextWrapping="Wrap" Foreground="#333" Padding="2"
                             Text=""/>
                </GroupBox>

            </StackPanel>
        </ScrollViewer>

    </DockPanel>
</Window>
"@

# ============================================================
#  REFERENCIAS A CONTROLES
# ============================================================
$reader = [System.Xml.XmlNodeReader]::new($xaml)
$window = [System.Windows.Markup.XamlReader]::Load($reader)

function Get-C($n) { $window.FindName($n) }

$lblRamPct   = Get-C "lblRamPct"
$lblRamFree  = Get-C "lblRamFree"
$lblRamTotal = Get-C "lblRamTotal"
$barRam      = Get-C "barRam"
$lblCpuPct   = Get-C "lblCpuPct"
$lblCpuName  = Get-C "lblCpuName"
$barCpu      = Get-C "barCpu"
$lblDiskFree  = Get-C "lblDiskFree"
$lblDiskUsed  = Get-C "lblDiskUsed"
$lblDiskTotal = Get-C "lblDiskTotal"
$barDisk     = Get-C "barDisk"
$txtLog      = Get-C "txtLog"
$txtStatus   = Get-C "txtStatus"
$btnOptimize = Get-C "btnOptimize"
$btnFreeRam  = Get-C "btnFreeRam"
$miExit      = Get-C "miExit"
$miAlwaysTop = Get-C "miAlwaysTop"
$miRefresh   = Get-C "miRefresh"
$miOptimize  = Get-C "miOptimize"
$miFreeRam   = Get-C "miFreeRam"
$miCleanTemp = Get-C "miCleanTemp"
$miStartup   = Get-C "miStartup"
$miPowerPlan = Get-C "miPowerPlan"
$miAbout     = Get-C "miAbout"
$miGithub    = Get-C "miGithub"

# ============================================================
#  UTILIDADES
# ============================================================
function Fmt([long]$bytes) {
    if ($bytes -ge 1GB) { return "{0:F1} GB" -f ($bytes / 1GB) }
    if ($bytes -ge 1MB) { return "{0:F0} MB" -f ($bytes / 1MB) }
    if ($bytes -gt 0)   { return "{0} KB"    -f [int]($bytes / 1KB) }
    return "0 B"
}

function FmtMB([long]$mb) {
    if ($mb -ge 1024) { return "{0:F1} GB" -f ($mb / 1024.0) }
    return "$mb MB"
}

function Log($msg) {
    $t = (Get-Date).ToString("HH:mm:ss")
    $txtLog.AppendText("[$t] $msg`r`n")
    $txtLog.ScrollToEnd()
}

function Status($msg) { $txtStatus.Text = $msg }

# ============================================================
#  ACTUALIZAR UI — lee del hashtable (no bloquea)
# ============================================================
function Update-UI {
    $cpu    = $script:d['CpuPct']
    $freeMB = $script:d['FreeMB']
    $totMB  = $script:d['TotalMB']
    $usedMB = $totMB - $freeMB
    $ramPct = if ($totMB -gt 0) { [int](($usedMB / $totMB) * 100) } else { 0 }

    $lblCpuPct.Text    = "$cpu%"
    $lblCpuName.Text   = $script:d['CpuName']
    $barCpu.Value      = [Math]::Min($cpu, 100)

    $lblRamPct.Text    = "$ramPct%  /  $(FmtMB $usedMB)"
    $lblRamFree.Text   = FmtMB $freeMB
    $lblRamTotal.Text  = FmtMB $totMB
    $barRam.Value      = [Math]::Min($ramPct, 100)

    $dfree  = $script:d['DiskFree']
    $dtotal = $script:d['DiskTotal']
    $dused  = $dtotal - $dfree
    $dpct   = if ($dtotal -gt 0) { [int](($dused / $dtotal) * 100) } else { 0 }

    $lblDiskFree.Text  = Fmt $dfree
    $lblDiskUsed.Text  = Fmt $dused
    $lblDiskTotal.Text = Fmt $dtotal
    $barDisk.Value     = [Math]::Min($dpct, 100)

    $t = (Get-Date).ToString("HH:mm:ss")
    Status "Actualizado $t   CPU: $cpu%   RAM: $ramPct%   Disco: $(Fmt $dfree) libre"
}

# ============================================================
#  LIBERAR RAM
# ============================================================
function Free-RAM {
    Status "Liberando RAM..."
    $before = $script:d['FreeMB']

    [System.GC]::Collect(2, [System.GCCollectionMode]::Forced)
    [System.GC]::WaitForPendingFinalizers()
    [System.GC]::Collect()

    $skip = @('System','smss','csrss','wininit','winlogon','lsass','services',
              'svchost','Registry','MsMpEng','WmiPrvSE','dwm','fontdrvhost')
    $n = 0
    Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $_.WorkingSet64 -gt 20MB -and $skip -notcontains $_.ProcessName } |
        Sort-Object WorkingSet64 -Descending |
        Select-Object -First 30 |
        ForEach-Object {
            try { $_.MinWorkingSet = [IntPtr]1; $_.MaxWorkingSet = [IntPtr]1; $n++ } catch {}
        }

    Start-Sleep -Milliseconds 500
    $after  = $script:d['FreeMB']
    $freed  = ($after - $before) * 1MB
    if ($freed -lt 0) { $freed = 0 }

    $msg = if ($freed -gt 1MB) { "RAM liberada: $(Fmt $freed) ($n procesos ajustados)" }
           else                { "RAM optimizada ($n procesos ajustados)" }
    Log $msg
    Status "Listo — $msg"
}

# ============================================================
#  LIMPIAR ARCHIVOS TEMPORALES
# ============================================================
function Clean-Temp {
    Status "Analizando temporales..."
    $paths  = @($env:TEMP, "$env:SystemRoot\Temp")
    $total  = 0L
    $files  = 0
    $errors = 0

    foreach ($p in $paths) {
        if (-not (Test-Path $p)) { continue }
        Get-ChildItem $p -Recurse -Force -ErrorAction SilentlyContinue |
            Where-Object { -not $_.PSIsContainer } |
            ForEach-Object {
                try {
                    $total += $_.Length
                    Remove-Item $_.FullName -Force -ErrorAction Stop
                    $files++
                } catch { $errors++ }
            }
    }

    $msg = "Temporales: $(Fmt $total) eliminados ($files archivos"
    if ($errors -gt 0) { $msg += ", $errors en uso" }
    $msg += ")"
    Log $msg
    Status "Listo — $msg"
}

# ============================================================
#  OPTIMIZACION RAPIDA (RAM + TEMP)
# ============================================================
function Quick-Optimize {
    Log "=== Iniciando optimizacion rapida ==="
    Status "Optimizando..."

    # 1. GC y Working Set
    [System.GC]::Collect(2, [System.GCCollectionMode]::Forced)
    [System.GC]::WaitForPendingFinalizers()
    Log "GC completado"

    # 2. Limpiar temporales
    $paths = @($env:TEMP, "$env:SystemRoot\Temp")
    $total = 0L; $files = 0
    foreach ($p in $paths) {
        if (-not (Test-Path $p)) { continue }
        Get-ChildItem $p -Recurse -Force -ErrorAction SilentlyContinue |
            Where-Object { -not $_.PSIsContainer } |
            ForEach-Object {
                try { $total += $_.Length; Remove-Item $_.FullName -Force -ErrorAction Stop; $files++ } catch {}
            }
    }
    Log "Temporales: $(Fmt $total) liberados ($files archivos)"
    Log "=== Completado ==="
    Status "Optimizacion completa — $(Fmt $total) liberados en temporales"
}

# ============================================================
#  HANDLERS DE EVENTOS
# ============================================================
$btnOptimize.Add_Click({ Quick-Optimize })
$btnFreeRam.Add_Click({  Free-RAM      })

$miOptimize.Add_Click({  Quick-Optimize })
$miFreeRam.Add_Click({   Free-RAM       })
$miCleanTemp.Add_Click({ Clean-Temp     })
$miRefresh.Add_Click({   Update-UI      })

$miAlwaysTop.Add_Checked({   $window.Topmost = $true  })
$miAlwaysTop.Add_Unchecked({ $window.Topmost = $false })

$miStartup.Add_Click({
    try { Start-Process "taskmgr.exe" -ArgumentList "/7" } catch {
        try { Start-Process "ms-settings:startupapps" } catch {}
    }
})

$miPowerPlan.Add_Click({
    Start-Process "powercfg.cpl" -ErrorAction SilentlyContinue
})

$miAbout.Add_Click({
    $msg = "WinOptimizer v2.0.0`r`n" +
           "Optimizador de rendimiento para Windows 10/11`r`n`r`n" +
           "Desarrollado por Enmanuel Gil`r`n" +
           "github.com/EnMaNueL-G`r`n`r`n" +
           "Licencia: MIT — Codigo abierto y gratuito"
    [System.Windows.MessageBox]::Show($msg, "Acerca de WinOptimizer",
        [System.Windows.MessageBoxButton]::OK,
        [System.Windows.MessageBoxImage]::Information)
})

$miGithub.Add_Click({
    Start-Process "https://github.com/EnMaNueL-G/WinOptimizer"
})

$miExit.Add_Click({
    $script:timer.Stop()
    try { $script:bgPS.Stop() } catch {}
    try { $script:bgRS.Close() } catch {}
    $window.Close()
})

# ============================================================
#  TIMER — actualiza UI cada 2 segundos (instantaneo, no bloquea)
# ============================================================
$script:timer = [System.Windows.Threading.DispatcherTimer]::new()
$script:timer.Interval = [TimeSpan]::FromSeconds(2)
$script:timer.Add_Tick({ Update-UI })

# ============================================================
#  ARRANQUE
# ============================================================
$window.Add_Loaded({
    Start-Worker
    $script:timer.Start()
    Log "WinOptimizer v2.0.0 iniciado"
    Status "Cargando datos del sistema..."
})

$window.Add_Closed({
    $script:timer.Stop()
    try { $script:bgPS.Stop() } catch {}
    try { $script:bgRS.Close() } catch {}
})

# Tecla F5 = actualizar manualmente
$window.Add_KeyDown({
    if ($_.Key -eq [System.Windows.Input.Key]::F5) { Update-UI }
})

$window.ShowDialog() | Out-Null
