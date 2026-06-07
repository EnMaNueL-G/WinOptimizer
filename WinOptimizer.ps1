#Requires -Version 5.1
<#
.SYNOPSIS
    WinOptimizer v2.2.0
    Optimizador de rendimiento para Windows 10/11
    Enmanuel Gil — github.com/EnMaNueL-G
.NOTES
    Funciones:
      RAM fisica + virtual + cache del sistema
      CPU (uso + modelo + temperatura si disponible)
      Disco, Red, Top 5 procesos con kill
      Historial grafico 2 min, Bandeja del sistema
      Auto-optimizacion programada, Limpiar Temp
      Inicio de Windows, Plan de energia
#>

Set-StrictMode -Off

# Ruta segura del directorio del script/exe (PSScriptRoot es null en EXE compilado)
if ($PSScriptRoot -and $PSScriptRoot -ne '') {
    $script:AppDir = $PSScriptRoot
} else {
    try {
        $script:AppDir = Split-Path -Parent ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
    } catch {
        $script:AppDir = $env:TEMP
    }
}

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ============================================================
#  DATOS COMPARTIDOS  UI <-> Worker  (thread-safe)
#  REGLA: solo tipos simples (int, long, string, string[])
#         NO hashtables anidadas — fallan entre runspaces
# ============================================================
$script:d = [hashtable]::Synchronized(@{
    # RAM fisica
    CpuPct       = 0;     FreeMB      = 0L;   TotalMB    = 32768L
    CpuName      = 'Detectando...'
    CpuTempC     = -1     # -1 = no disponible
    # RAM virtual
    VirtUsedMB   = 0L;    VirtFreeMB  = 0L;   VirtTotalMB = 64000L; VirtPct = 0
    # Cache del sistema
    CacheMB      = 0L
    # Disco
    DiskFree     = 0L;    DiskTotal   = 1L
    # Red
    NetRxBps     = 0L;    NetTxBps    = 0L
    # Top 5 procesos — 3 arrays paralelos de strings/ints (seguros cross-runspace)
    TopProcNames = [string[]]@('','','','','')
    TopProcMBs   = [int[]]@(0,0,0,0,0)
    TopProcPIDs  = [int[]]@(0,0,0,0,0)
    # Historial (arrays int 0-100, max 60 muestras)
    CpuHistory   = [int[]]@()
    RamHistory   = [int[]]@()
    # Estado
    Tick         = 0
})

# ============================================================
#  BACKGROUND WORKER
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
        # -- Inicializacion unica --
        try {
            $os  = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
            $cpu = Get-CimInstance Win32_Processor       -ErrorAction Stop | Select-Object -First 1
            $d['TotalMB'] = [long]($os.TotalVisibleMemorySize / 1KB)
            $d['CpuName'] = ($cpu.Name.Trim() -replace '\s+', ' ')
        } catch {}

        # Listas de historial locales al worker
        $cpuH = New-Object System.Collections.Generic.List[int]
        $ramH = New-Object System.Collections.Generic.List[int]

        while ($true) {
            try {
                $cpuPct = [int]((Get-Counter '\Procesador(_Total)\% de tiempo de procesador' `
                    -ErrorAction Stop).CounterSamples[0].CookedValue)
                $freeMB = [long]((Get-Counter '\Memoria\Mbytes disponibles' `
                    -ErrorAction Stop).CounterSamples[0].CookedValue)
                $d['CpuPct'] = $cpuPct
                $d['FreeMB'] = $freeMB
            } catch {}

            try {
                $pm = Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory -ErrorAction Stop
                $d['VirtUsedMB']  = [long]($pm.CommittedBytes / 1MB)
                $d['VirtTotalMB'] = [long]($pm.CommitLimit    / 1MB)
                $d['VirtFreeMB']  = [long](($pm.CommitLimit - $pm.CommittedBytes) / 1MB)
                $d['VirtPct']     = if ($pm.CommitLimit -gt 0) {
                    [int](($pm.CommittedBytes / $pm.CommitLimit) * 100) } else { 0 }
                $d['CacheMB']     = [long]($pm.SystemCacheResidentBytes / 1MB)
            } catch {}

            try {
                $temp = Get-CimInstance -Namespace 'root/WMI' `
                    -ClassName MSAcpi_ThermalZoneTemperature -ErrorAction Stop |
                    Select-Object -First 1
                if ($temp) {
                    $d['CpuTempC'] = [int](($temp.CurrentTemperature - 2732) / 10)
                }
            } catch { $d['CpuTempC'] = -1 }

            try {
                $dr = Get-PSDrive C -ErrorAction Stop
                $d['DiskFree']  = $dr.Free
                $d['DiskTotal'] = $dr.Free + $dr.Used
            } catch {}

            try {
                $nic = Get-CimInstance Win32_PerfFormattedData_Tcpip_NetworkInterface `
                    -ErrorAction Stop |
                    Where-Object { $_.Name -notlike '*Loopback*' -and $_.Name -notlike '*Virtual*' } |
                    Sort-Object BytesTotalPersec -Descending | Select-Object -First 1
                if ($nic) {
                    $d['NetRxBps'] = [long]$nic.BytesReceivedPersec
                    $d['NetTxBps'] = [long]$nic.BytesSentPersec
                }
            } catch {}

            # Top 5 procesos — arrays simples string[]/int[] seguros cross-runspace
            try {
                $skip = @('System','smss','csrss','wininit','winlogon','lsass',
                          'services','svchost','Registry','MsMpEng','dwm',
                          'fontdrvhost','Idle','WmiPrvSE')
                $top = @(Get-Process -ErrorAction SilentlyContinue |
                    Where-Object { $skip -notcontains $_.ProcessName } |
                    Sort-Object WorkingSet64 -Descending |
                    Select-Object -First 5)
                $names = [string[]]@('','','','','')
                $mbs   = [int[]]@(0,0,0,0,0)
                $pids2 = [int[]]@(0,0,0,0,0)
                for ($i = 0; $i -lt [Math]::Min($top.Count, 5); $i++) {
                    $names[$i] = [string]$top[$i].ProcessName
                    $mbs[$i]   = [int]($top[$i].WorkingSet64 / 1MB)
                    $pids2[$i] = [int]$top[$i].Id
                }
                $d['TopProcNames'] = $names
                $d['TopProcMBs']   = $mbs
                $d['TopProcPIDs']  = $pids2
            } catch {}

            try {
                $totMB  = $d['TotalMB']
                $frMB   = $d['FreeMB']
                $ramPct = if ($totMB -gt 0) { [int](($totMB - $frMB) * 100 / $totMB) } else { 0 }
                $cpuH.Add($d['CpuPct'])
                $ramH.Add($ramPct)
                if ($cpuH.Count -gt 60) { $cpuH.RemoveAt(0) }
                if ($ramH.Count -gt 60) { $ramH.RemoveAt(0) }
                $d['CpuHistory'] = [int[]]$cpuH.ToArray()
                $d['RamHistory'] = [int[]]$ramH.ToArray()
            } catch {}

            $d['Tick']++
            Start-Sleep -Seconds 2
        }
    })
    $null = $ps.BeginInvoke()
    $script:bgPS = $ps
    $script:bgRS = $rs
}

# ============================================================
#  XAML
# ============================================================
[xml]$xaml = @"
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="WinOptimizer"
    Width="375" Height="720"
    MinWidth="320" MinHeight="500"
    WindowStartupLocation="CenterScreen"
    Background="#F0F0F0"
    FontFamily="Segoe UI" FontSize="12">

    <DockPanel LastChildFill="True">

        <Menu DockPanel.Dock="Top" Background="#F0F0F0" Padding="2,2">
            <MenuItem Header="Archivo">
                <MenuItem x:Name="miMinTray"   Header="Minimizar a bandeja"/>
                <Separator/>
                <MenuItem x:Name="miExit"      Header="Salir"/>
            </MenuItem>
            <MenuItem Header="Ver">
                <MenuItem x:Name="miAlwaysTop" Header="Siempre visible" IsCheckable="True"/>
                <Separator/>
                <MenuItem x:Name="miRefresh"   Header="Actualizar ahora  (F5)"/>
            </MenuItem>
            <MenuItem Header="Herramientas">
                <MenuItem x:Name="miOptimize"  Header="Optimizar sistema"/>
                <MenuItem x:Name="miFreeRam"   Header="Liberar RAM"/>
                <Separator/>
                <MenuItem x:Name="miCleanTemp" Header="Limpiar archivos temporales"/>
                <MenuItem x:Name="miStartup"   Header="Inicio de Windows..."/>
                <MenuItem x:Name="miPowerPlan" Header="Plan de energia..."/>
                <Separator/>
                <MenuItem Header="Auto-optimizacion">
                    <MenuItem x:Name="miAutoOff"  Header="Desactivada"     IsCheckable="True" IsChecked="True"/>
                    <MenuItem x:Name="miAuto5"    Header="Cada 5 minutos"  IsCheckable="True"/>
                    <MenuItem x:Name="miAuto15"   Header="Cada 15 minutos" IsCheckable="True"/>
                    <MenuItem x:Name="miAuto30"   Header="Cada 30 minutos" IsCheckable="True"/>
                </MenuItem>
            </MenuItem>
            <MenuItem Header="Ayuda">
                <MenuItem x:Name="miAbout"  Header="Acerca de WinOptimizer"/>
                <MenuItem x:Name="miGithub" Header="Ver en GitHub"/>
            </MenuItem>
        </Menu>

        <StatusBar DockPanel.Dock="Bottom" Background="#DEDEDE">
            <StatusBarItem Padding="6,2">
                <TextBlock x:Name="txtStatus" Text="Iniciando..." FontSize="11" Foreground="#444"/>
            </StatusBarItem>
        </StatusBar>

        <Border DockPanel.Dock="Bottom" Padding="8,6"
                Background="#EBEBEB" BorderBrush="#CCCCCC" BorderThickness="0,1,0,0">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="5"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <Button x:Name="btnOptimize" Grid.Column="0" Content="Optimizar sistema"
                        Padding="0,7" FontWeight="SemiBold" FontSize="12"
                        Background="#0078D4" Foreground="White"
                        BorderBrush="#005A9E" BorderThickness="1" Cursor="Hand"/>
                <Button x:Name="btnFreeRam"  Grid.Column="2" Content="Liberar RAM"
                        Padding="14,7" FontSize="12"
                        Background="#EBEBEB" Foreground="#1A1A1A"
                        BorderBrush="#ADADAD" BorderThickness="1" Cursor="Hand"/>
            </Grid>
        </Border>

        <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
            <StackPanel Margin="8,4,8,4">

                <!-- MEMORIA FISICA -->
                <GroupBox Margin="0,2,0,4" Padding="6,3,6,6" BorderBrush="#AAAACC" Background="White">
                    <GroupBox.Header>
                        <TextBlock Text="Memoria fisica" FontWeight="SemiBold" Foreground="#003399" FontSize="11"/>
                    </GroupBox.Header>
                    <Grid>
                        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="150"/></Grid.ColumnDefinitions>
                        <Grid.RowDefinitions>
                            <RowDefinition Height="20"/><RowDefinition Height="20"/>
                            <RowDefinition Height="20"/><RowDefinition Height="12"/>
                        </Grid.RowDefinitions>
                        <TextBlock Grid.Row="0" Grid.Column="0" Text="En uso"           VerticalAlignment="Center" Foreground="#555"/>
                        <TextBlock Grid.Row="1" Grid.Column="0" Text="Libre"            VerticalAlignment="Center" Foreground="#555"/>
                        <TextBlock Grid.Row="2" Grid.Column="0" Text="Total disponible" VerticalAlignment="Center" Foreground="#555"/>
                        <TextBlock x:Name="lblRamPct"   Grid.Row="0" Grid.Column="1" HorizontalAlignment="Right" VerticalAlignment="Center" FontWeight="Bold" Foreground="#BB1100" Text="--%"/>
                        <TextBlock x:Name="lblRamFree"  Grid.Row="1" Grid.Column="1" HorizontalAlignment="Right" VerticalAlignment="Center" Text="--"/>
                        <TextBlock x:Name="lblRamTotal" Grid.Row="2" Grid.Column="1" HorizontalAlignment="Right" VerticalAlignment="Center" Text="--"/>
                        <ProgressBar x:Name="barRam" Grid.Row="3" Grid.ColumnSpan="2" Minimum="0" Maximum="100" Value="0" Height="6" Margin="0,3,0,0" Background="#E0E0E0" Foreground="#CC2200"/>
                    </Grid>
                </GroupBox>

                <!-- MEMORIA VIRTUAL -->
                <GroupBox Margin="0,0,0,4" Padding="6,3,6,6" BorderBrush="#AAAACC" Background="White">
                    <GroupBox.Header>
                        <TextBlock Text="Memoria virtual (paginada)" FontWeight="SemiBold" Foreground="#003399" FontSize="11"/>
                    </GroupBox.Header>
                    <Grid>
                        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="150"/></Grid.ColumnDefinitions>
                        <Grid.RowDefinitions>
                            <RowDefinition Height="20"/><RowDefinition Height="20"/>
                            <RowDefinition Height="20"/><RowDefinition Height="12"/>
                        </Grid.RowDefinitions>
                        <TextBlock Grid.Row="0" Grid.Column="0" Text="En uso"           VerticalAlignment="Center" Foreground="#555"/>
                        <TextBlock Grid.Row="1" Grid.Column="0" Text="Libre"            VerticalAlignment="Center" Foreground="#555"/>
                        <TextBlock Grid.Row="2" Grid.Column="0" Text="Total disponible" VerticalAlignment="Center" Foreground="#555"/>
                        <TextBlock x:Name="lblVirtPct"   Grid.Row="0" Grid.Column="1" HorizontalAlignment="Right" VerticalAlignment="Center" FontWeight="Bold" Foreground="#BB1100" Text="--%"/>
                        <TextBlock x:Name="lblVirtFree"  Grid.Row="1" Grid.Column="1" HorizontalAlignment="Right" VerticalAlignment="Center" Text="--"/>
                        <TextBlock x:Name="lblVirtTotal" Grid.Row="2" Grid.Column="1" HorizontalAlignment="Right" VerticalAlignment="Center" Text="--"/>
                        <ProgressBar x:Name="barVirt" Grid.Row="3" Grid.ColumnSpan="2" Minimum="0" Maximum="100" Value="0" Height="6" Margin="0,3,0,0" Background="#E0E0E0" Foreground="#9B59B6"/>
                    </Grid>
                </GroupBox>

                <!-- CACHE DEL SISTEMA -->
                <GroupBox Margin="0,0,0,4" Padding="6,3,6,6" BorderBrush="#AAAACC" Background="White">
                    <GroupBox.Header>
                        <TextBlock Text="Cache del sistema" FontWeight="SemiBold" Foreground="#003399" FontSize="11"/>
                    </GroupBox.Header>
                    <Grid>
                        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="150"/></Grid.ColumnDefinitions>
                        <Grid.RowDefinitions><RowDefinition Height="20"/><RowDefinition Height="12"/></Grid.RowDefinitions>
                        <TextBlock Grid.Row="0" Grid.Column="0" Text="En uso (residente en RAM)" VerticalAlignment="Center" Foreground="#555"/>
                        <TextBlock x:Name="lblCacheMB" Grid.Row="0" Grid.Column="1" HorizontalAlignment="Right" VerticalAlignment="Center" FontWeight="Bold" Foreground="#007722" Text="--"/>
                        <ProgressBar x:Name="barCache" Grid.Row="1" Grid.ColumnSpan="2" Minimum="0" Maximum="100" Value="0" Height="6" Margin="0,3,0,0" Background="#E0E0E0" Foreground="#22AA44"/>
                    </Grid>
                </GroupBox>

                <!-- CPU -->
                <GroupBox Margin="0,0,0,4" Padding="6,3,6,6" BorderBrush="#AAAACC" Background="White">
                    <GroupBox.Header>
                        <TextBlock Text="Procesador (CPU)" FontWeight="SemiBold" Foreground="#003399" FontSize="11"/>
                    </GroupBox.Header>
                    <Grid>
                        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="150"/></Grid.ColumnDefinitions>
                        <Grid.RowDefinitions>
                            <RowDefinition Height="20"/><RowDefinition Height="20"/>
                            <RowDefinition Height="20"/><RowDefinition Height="12"/>
                        </Grid.RowDefinitions>
                        <TextBlock Grid.Row="0" Grid.Column="0" Text="En uso"       VerticalAlignment="Center" Foreground="#555"/>
                        <TextBlock Grid.Row="1" Grid.Column="0" Text="Temperatura"  VerticalAlignment="Center" Foreground="#555"/>
                        <TextBlock Grid.Row="2" Grid.Column="0" Text="Modelo"       VerticalAlignment="Center" Foreground="#555"/>
                        <TextBlock x:Name="lblCpuPct"  Grid.Row="0" Grid.Column="1" HorizontalAlignment="Right" VerticalAlignment="Center" FontWeight="Bold" Foreground="#BB1100" Text="--%"/>
                        <TextBlock x:Name="lblCpuTemp" Grid.Row="1" Grid.Column="1" HorizontalAlignment="Right" VerticalAlignment="Center" Foreground="#555" Text="--"/>
                        <TextBlock x:Name="lblCpuName" Grid.Row="2" Grid.Column="1" HorizontalAlignment="Right" VerticalAlignment="Center" Foreground="#444" Text="..." TextTrimming="CharacterEllipsis"/>
                        <ProgressBar x:Name="barCpu" Grid.Row="3" Grid.ColumnSpan="2" Minimum="0" Maximum="100" Value="0" Height="6" Margin="0,3,0,0" Background="#E0E0E0" Foreground="#0078D4"/>
                    </Grid>
                </GroupBox>

                <!-- ALMACENAMIENTO -->
                <GroupBox Margin="0,0,0,4" Padding="6,3,6,6" BorderBrush="#AAAACC" Background="White">
                    <GroupBox.Header>
                        <TextBlock Text="Almacenamiento (C:)" FontWeight="SemiBold" Foreground="#003399" FontSize="11"/>
                    </GroupBox.Header>
                    <Grid>
                        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="150"/></Grid.ColumnDefinitions>
                        <Grid.RowDefinitions>
                            <RowDefinition Height="20"/><RowDefinition Height="20"/>
                            <RowDefinition Height="20"/><RowDefinition Height="12"/>
                        </Grid.RowDefinitions>
                        <TextBlock Grid.Row="0" Grid.Column="0" Text="Libre"            VerticalAlignment="Center" Foreground="#555"/>
                        <TextBlock Grid.Row="1" Grid.Column="0" Text="Usado"            VerticalAlignment="Center" Foreground="#555"/>
                        <TextBlock Grid.Row="2" Grid.Column="0" Text="Total disponible" VerticalAlignment="Center" Foreground="#555"/>
                        <TextBlock x:Name="lblDiskFree"  Grid.Row="0" Grid.Column="1" HorizontalAlignment="Right" VerticalAlignment="Center" FontWeight="Bold" Foreground="#007722" Text="--"/>
                        <TextBlock x:Name="lblDiskUsed"  Grid.Row="1" Grid.Column="1" HorizontalAlignment="Right" VerticalAlignment="Center" Text="--"/>
                        <TextBlock x:Name="lblDiskTotal" Grid.Row="2" Grid.Column="1" HorizontalAlignment="Right" VerticalAlignment="Center" Text="--"/>
                        <ProgressBar x:Name="barDisk" Grid.Row="3" Grid.ColumnSpan="2" Minimum="0" Maximum="100" Value="0" Height="6" Margin="0,3,0,0" Background="#E0E0E0" Foreground="#22AA44"/>
                    </Grid>
                </GroupBox>

                <!-- RED -->
                <GroupBox Margin="0,0,0,4" Padding="6,3,6,6" BorderBrush="#AAAACC" Background="White">
                    <GroupBox.Header>
                        <TextBlock Text="Red" FontWeight="SemiBold" Foreground="#003399" FontSize="11"/>
                    </GroupBox.Header>
                    <Grid>
                        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="150"/></Grid.ColumnDefinitions>
                        <Grid.RowDefinitions><RowDefinition Height="20"/><RowDefinition Height="20"/></Grid.RowDefinitions>
                        <TextBlock Grid.Row="0" Grid.Column="0" Text="Recibiendo" VerticalAlignment="Center" Foreground="#555"/>
                        <TextBlock Grid.Row="1" Grid.Column="0" Text="Enviando"   VerticalAlignment="Center" Foreground="#555"/>
                        <TextBlock x:Name="lblNetRx" Grid.Row="0" Grid.Column="1" HorizontalAlignment="Right" VerticalAlignment="Center" FontWeight="Bold" Foreground="#0078D4" Text="--"/>
                        <TextBlock x:Name="lblNetTx" Grid.Row="1" Grid.Column="1" HorizontalAlignment="Right" VerticalAlignment="Center" Foreground="#555" Text="--"/>
                    </Grid>
                </GroupBox>

                <!-- HISTORIAL GRAFICO -->
                <GroupBox Margin="0,0,0,4" Padding="6,3,6,4" BorderBrush="#AAAACC" Background="White">
                    <GroupBox.Header>
                        <TextBlock Text="Historial (2 min)" FontWeight="SemiBold" Foreground="#003399" FontSize="11"/>
                    </GroupBox.Header>
                    <StackPanel>
                        <StackPanel Orientation="Horizontal" Margin="0,0,0,3">
                            <Rectangle Width="18" Height="3" Fill="#0078D4" VerticalAlignment="Center" Margin="0,0,4,0"/>
                            <TextBlock Text="CPU" FontSize="10" Foreground="#555" Margin="0,0,12,0"/>
                            <Rectangle Width="18" Height="3" Fill="#CC2200" VerticalAlignment="Center" Margin="0,0,4,0"/>
                            <TextBlock Text="RAM" FontSize="10" Foreground="#555"/>
                        </StackPanel>
                        <Border BorderBrush="#DDDDDD" BorderThickness="1" Background="#FAFAFA">
                            <Canvas x:Name="graphCanvas" Height="48">
                                <Polyline x:Name="graphCpu" Stroke="#0078D4" StrokeThickness="1.5" StrokeLineJoin="Round"/>
                                <Polyline x:Name="graphRam" Stroke="#CC2200" StrokeThickness="1.5" StrokeLineJoin="Round"/>
                            </Canvas>
                        </Border>
                    </StackPanel>
                </GroupBox>

                <!-- TOP PROCESOS con boton Kill -->
                <GroupBox Margin="0,0,0,4" Padding="6,3,6,6" BorderBrush="#AAAACC" Background="White">
                    <GroupBox.Header>
                        <TextBlock Text="Procesos (top 5 por RAM)" FontWeight="SemiBold" Foreground="#003399" FontSize="11"/>
                    </GroupBox.Header>
                    <Grid>
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="60"/>
                            <ColumnDefinition Width="42"/>
                            <ColumnDefinition Width="34"/>
                        </Grid.ColumnDefinitions>
                        <Grid.RowDefinitions>
                            <RowDefinition Height="22"/><RowDefinition Height="22"/>
                            <RowDefinition Height="22"/><RowDefinition Height="22"/>
                            <RowDefinition Height="22"/>
                        </Grid.RowDefinitions>
                        <TextBlock x:Name="p0n" Grid.Row="0" Grid.Column="0" VerticalAlignment="Center" Foreground="#333" TextTrimming="CharacterEllipsis"/>
                        <TextBlock x:Name="p0m" Grid.Row="0" Grid.Column="1" HorizontalAlignment="Right" VerticalAlignment="Center" Foreground="#BB1100"/>
                        <TextBlock x:Name="p0p" Grid.Row="0" Grid.Column="2" HorizontalAlignment="Right" VerticalAlignment="Center" Foreground="#999" FontSize="10"/>
                        <Button   x:Name="k0"   Grid.Row="0" Grid.Column="3" Content="Kill" Tag="0" Padding="2,1" FontSize="10" Margin="2,1" Background="#FFEEEE" BorderBrush="#CC4444" Foreground="#AA0000" Cursor="Hand" Visibility="Collapsed"/>
                        <TextBlock x:Name="p1n" Grid.Row="1" Grid.Column="0" VerticalAlignment="Center" Foreground="#333" TextTrimming="CharacterEllipsis"/>
                        <TextBlock x:Name="p1m" Grid.Row="1" Grid.Column="1" HorizontalAlignment="Right" VerticalAlignment="Center" Foreground="#BB1100"/>
                        <TextBlock x:Name="p1p" Grid.Row="1" Grid.Column="2" HorizontalAlignment="Right" VerticalAlignment="Center" Foreground="#999" FontSize="10"/>
                        <Button   x:Name="k1"   Grid.Row="1" Grid.Column="3" Content="Kill" Tag="0" Padding="2,1" FontSize="10" Margin="2,1" Background="#FFEEEE" BorderBrush="#CC4444" Foreground="#AA0000" Cursor="Hand" Visibility="Collapsed"/>
                        <TextBlock x:Name="p2n" Grid.Row="2" Grid.Column="0" VerticalAlignment="Center" Foreground="#333" TextTrimming="CharacterEllipsis"/>
                        <TextBlock x:Name="p2m" Grid.Row="2" Grid.Column="1" HorizontalAlignment="Right" VerticalAlignment="Center" Foreground="#BB1100"/>
                        <TextBlock x:Name="p2p" Grid.Row="2" Grid.Column="2" HorizontalAlignment="Right" VerticalAlignment="Center" Foreground="#999" FontSize="10"/>
                        <Button   x:Name="k2"   Grid.Row="2" Grid.Column="3" Content="Kill" Tag="0" Padding="2,1" FontSize="10" Margin="2,1" Background="#FFEEEE" BorderBrush="#CC4444" Foreground="#AA0000" Cursor="Hand" Visibility="Collapsed"/>
                        <TextBlock x:Name="p3n" Grid.Row="3" Grid.Column="0" VerticalAlignment="Center" Foreground="#333" TextTrimming="CharacterEllipsis"/>
                        <TextBlock x:Name="p3m" Grid.Row="3" Grid.Column="1" HorizontalAlignment="Right" VerticalAlignment="Center" Foreground="#BB1100"/>
                        <TextBlock x:Name="p3p" Grid.Row="3" Grid.Column="2" HorizontalAlignment="Right" VerticalAlignment="Center" Foreground="#999" FontSize="10"/>
                        <Button   x:Name="k3"   Grid.Row="3" Grid.Column="3" Content="Kill" Tag="0" Padding="2,1" FontSize="10" Margin="2,1" Background="#FFEEEE" BorderBrush="#CC4444" Foreground="#AA0000" Cursor="Hand" Visibility="Collapsed"/>
                        <TextBlock x:Name="p4n" Grid.Row="4" Grid.Column="0" VerticalAlignment="Center" Foreground="#333" TextTrimming="CharacterEllipsis"/>
                        <TextBlock x:Name="p4m" Grid.Row="4" Grid.Column="1" HorizontalAlignment="Right" VerticalAlignment="Center" Foreground="#BB1100"/>
                        <TextBlock x:Name="p4p" Grid.Row="4" Grid.Column="2" HorizontalAlignment="Right" VerticalAlignment="Center" Foreground="#999" FontSize="10"/>
                        <Button   x:Name="k4"   Grid.Row="4" Grid.Column="3" Content="Kill" Tag="0" Padding="2,1" FontSize="10" Margin="2,1" Background="#FFEEEE" BorderBrush="#CC4444" Foreground="#AA0000" Cursor="Hand" Visibility="Collapsed"/>
                    </Grid>
                </GroupBox>

                <!-- REGISTRO -->
                <GroupBox Margin="0,0,0,2" Padding="4,2,4,4" BorderBrush="#AAAACC" Background="White">
                    <GroupBox.Header>
                        <TextBlock Text="Registro de acciones" FontWeight="SemiBold" Foreground="#003399" FontSize="11"/>
                    </GroupBox.Header>
                    <TextBox x:Name="txtLog" Height="56" IsReadOnly="True"
                             FontFamily="Consolas" FontSize="10"
                             Background="White" BorderThickness="0"
                             VerticalScrollBarVisibility="Auto"
                             HorizontalScrollBarVisibility="Disabled"
                             TextWrapping="Wrap" Foreground="#333" Padding="2"/>
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

$lblRamPct    = Get-C "lblRamPct";    $lblRamFree   = Get-C "lblRamFree"
$lblRamTotal  = Get-C "lblRamTotal";  $barRam       = Get-C "barRam"
$lblVirtPct   = Get-C "lblVirtPct";   $lblVirtFree  = Get-C "lblVirtFree"
$lblVirtTotal = Get-C "lblVirtTotal"; $barVirt      = Get-C "barVirt"
$lblCacheMB   = Get-C "lblCacheMB";   $barCache     = Get-C "barCache"
$lblCpuPct    = Get-C "lblCpuPct";    $lblCpuName   = Get-C "lblCpuName"
$lblCpuTemp   = Get-C "lblCpuTemp";   $barCpu       = Get-C "barCpu"
$lblDiskFree  = Get-C "lblDiskFree";  $lblDiskUsed  = Get-C "lblDiskUsed"
$lblDiskTotal = Get-C "lblDiskTotal"; $barDisk      = Get-C "barDisk"
$lblNetRx     = Get-C "lblNetRx";     $lblNetTx     = Get-C "lblNetTx"
$graphCanvas  = Get-C "graphCanvas";  $graphCpu     = Get-C "graphCpu"; $graphRam = Get-C "graphRam"
$procN  = @(Get-C "p0n", Get-C "p1n", Get-C "p2n", Get-C "p3n", Get-C "p4n")
$procM  = @(Get-C "p0m", Get-C "p1m", Get-C "p2m", Get-C "p3m", Get-C "p4m")
$procP  = @(Get-C "p0p", Get-C "p1p", Get-C "p2p", Get-C "p3p", Get-C "p4p")
$killB  = @(Get-C "k0",  Get-C "k1",  Get-C "k2",  Get-C "k3",  Get-C "k4")
$txtLog      = Get-C "txtLog";      $txtStatus   = Get-C "txtStatus"
$btnOptimize = Get-C "btnOptimize"; $btnFreeRam  = Get-C "btnFreeRam"
$miExit      = Get-C "miExit";     $miAlwaysTop = Get-C "miAlwaysTop"
$miRefresh   = Get-C "miRefresh";  $miOptimize  = Get-C "miOptimize"
$miFreeRam   = Get-C "miFreeRam";  $miCleanTemp = Get-C "miCleanTemp"
$miStartup   = Get-C "miStartup";  $miPowerPlan = Get-C "miPowerPlan"
$miAbout     = Get-C "miAbout";    $miGithub    = Get-C "miGithub"
$miMinTray   = Get-C "miMinTray"
$miAutoOff   = Get-C "miAutoOff";  $miAuto5     = Get-C "miAuto5"
$miAuto15    = Get-C "miAuto15";   $miAuto30    = Get-C "miAuto30"

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
function FmtNet([long]$bps) {
    if ($bps -ge 1MB) { return "{0:F1} MB/s" -f ($bps / 1MB) }
    if ($bps -ge 1KB) { return "{0:F0} KB/s" -f ($bps / 1KB) }
    return "$bps B/s"
}
function SafeLog($msg) {
    try { $t = (Get-Date).ToString("HH:mm:ss"); $txtLog.AppendText("[$t] $msg`r`n"); $txtLog.ScrollToEnd() } catch {}
}
function SafeStatus($msg) { try { $txtStatus.Text = $msg } catch {} }

# ============================================================
#  GRAFICO
# ============================================================
function Update-Graph {
    try {
        $w = $graphCanvas.ActualWidth; $h = $graphCanvas.ActualHeight
        if ($w -lt 2 -or $h -lt 2) { return }
        $cArr = $script:d['CpuHistory']; $rArr = $script:d['RamHistory']
        if (-not $cArr -or $cArr.Length -lt 2) { return }
        $n = $cArr.Length; $pad = 3.0
        $cPts = New-Object System.Windows.Media.PointCollection
        $rPts = New-Object System.Windows.Media.PointCollection
        for ($i = 0; $i -lt $n; $i++) {
            $x  = [double]$i / ($n - 1) * $w
            $cy = $h - $pad - [double]$cArr[$i] / 100.0 * ($h - 2 * $pad)
            $ry = $h - $pad - [double]$rArr[$i] / 100.0 * ($h - 2 * $pad)
            $cPts.Add([System.Windows.Point]::new($x, $cy))
            $rPts.Add([System.Windows.Point]::new($x, $ry))
        }
        $graphCpu.Points = $cPts; $graphRam.Points = $rPts
    } catch {}
}

# ============================================================
#  ACTUALIZAR UI
# ============================================================
function Update-UI {
    try {
        $freeMB = $script:d['FreeMB']; $totMB = $script:d['TotalMB']
        $usedMB = $totMB - $freeMB
        $ramPct = if ($totMB -gt 0) { [int]($usedMB * 100 / $totMB) } else { 0 }
        $lblRamPct.Text   = "$ramPct%  /  $(FmtMB $usedMB)"
        $lblRamFree.Text  = FmtMB $freeMB
        $lblRamTotal.Text = FmtMB $totMB
        $barRam.Value     = [Math]::Min($ramPct, 100)
    } catch {}
    try {
        $vPct = $script:d['VirtPct']
        $lblVirtPct.Text   = "$vPct%  /  $(FmtMB $script:d['VirtUsedMB'])"
        $lblVirtFree.Text  = FmtMB $script:d['VirtFreeMB']
        $lblVirtTotal.Text = FmtMB $script:d['VirtTotalMB']
        $barVirt.Value     = [Math]::Min($vPct, 100)
    } catch {}
    try {
        $cMB = $script:d['CacheMB']; $tot = $script:d['TotalMB']
        $lblCacheMB.Text = FmtMB $cMB
        $barCache.Value  = [Math]::Min((if ($tot -gt 0) { [int]($cMB * 100 / $tot) } else { 0 }), 100)
    } catch {}
    try {
        $cpu = $script:d['CpuPct']
        $lblCpuPct.Text  = "$cpu%"
        $lblCpuName.Text = $script:d['CpuName']
        $barCpu.Value    = [Math]::Min($cpu, 100)
        $t = $script:d['CpuTempC']
        $lblCpuTemp.Text = if ($t -gt 0) { "$t C" } else { "No disponible" }
    } catch {}
    try {
        $df = $script:d['DiskFree']; $dt = $script:d['DiskTotal']
        $du = $dt - $df; $dp = if ($dt -gt 0) { [int]($du * 100 / $dt) } else { 0 }
        $lblDiskFree.Text  = Fmt $df; $lblDiskUsed.Text  = Fmt $du
        $lblDiskTotal.Text = Fmt $dt; $barDisk.Value     = [Math]::Min($dp, 100)
    } catch {}
    try {
        $lblNetRx.Text = FmtNet $script:d['NetRxBps']
        $lblNetTx.Text = FmtNet $script:d['NetTxBps']
    } catch {}
    try {
        # Top procesos — leer arrays string[]/int[] (no hashtables anidadas)
        $names = $script:d['TopProcNames']
        $mbs   = $script:d['TopProcMBs']
        $pids2 = $script:d['TopProcPIDs']
        for ($i = 0; $i -lt 5; $i++) {
            $nm = if ($names -and $i -lt $names.Length) { [string]$names[$i] } else { '' }
            $mb = if ($mbs   -and $i -lt $mbs.Length)   { [int]$mbs[$i] }     else { 0  }
            $pd = if ($pids2 -and $i -lt $pids2.Length) { [int]$pids2[$i] }   else { 0  }
            $procN[$i].Text = $nm
            $procM[$i].Text = if ($nm -ne '') { "$mb MB" } else { '' }
            $procP[$i].Text = if ($nm -ne '') { "PID $pd" } else { '' }
            $killB[$i].Tag        = $pd
            $killB[$i].Visibility = if ($nm -ne '') {
                [System.Windows.Visibility]::Visible
            } else { [System.Windows.Visibility]::Collapsed }
        }
    } catch {}
    Update-Graph
    try {
        $c2 = $script:d['CpuPct']; $tm = $script:d['TotalMB']; $fm = $script:d['FreeMB']
        $rp = if ($tm -gt 0) { [int](($tm-$fm)*100/$tm) } else { 0 }
        SafeStatus "Act. $((Get-Date).ToString('HH:mm:ss'))   CPU: $c2%   RAM: $rp%   Disco: $(Fmt $script:d['DiskFree']) libre"
    } catch {}
    try {
        if ($script:trayIcon) {
            $tip = "WinOptimizer — CPU: $($script:d['CpuPct'])%"
            $script:trayIcon.Text = $tip.Substring(0,[Math]::Min($tip.Length,127))
        }
    } catch {}
}

# ============================================================
#  ACCIONES
# ============================================================
function Free-RAM {
    try {
        SafeStatus "Liberando RAM..."
        $before = $script:d['FreeMB']
        [System.GC]::Collect(2,[System.GCCollectionMode]::Forced)
        [System.GC]::WaitForPendingFinalizers(); [System.GC]::Collect()
        $skip = @('System','smss','csrss','wininit','winlogon','lsass','services',
                  'svchost','Registry','MsMpEng','dwm','fontdrvhost','Idle')
        $n = 0
        Get-Process -EA SilentlyContinue |
            Where-Object { $_.WorkingSet64 -gt 10MB -and $skip -notcontains $_.ProcessName } |
            Sort-Object WorkingSet64 -Descending | Select-Object -First 40 |
            ForEach-Object { try { $_.MinWorkingSet=[IntPtr]1; $_.MaxWorkingSet=[IntPtr]1; $n++ } catch {} }
        Start-Sleep -Milliseconds 600
        $freed = ($script:d['FreeMB'] - $before) * 1MB
        if ($freed -lt 0) { $freed = 0 }
        $msg = if ($freed -gt 1MB) { "RAM liberada: $(Fmt $freed) ($n procesos)" }
               else                { "RAM optimizada ($n procesos ajustados)" }
        SafeLog $msg; SafeStatus "Listo — $msg"
    } catch { SafeStatus "Error al liberar RAM" }
}

function Clean-Temp {
    try {
        SafeStatus "Limpiando temporales..."
        $total = 0L; $files = 0; $errs = 0
        foreach ($p in @($env:TEMP, "$env:SystemRoot\Temp")) {
            if (-not (Test-Path $p)) { continue }
            Get-ChildItem $p -Recurse -Force -EA SilentlyContinue |
                Where-Object { -not $_.PSIsContainer } |
                ForEach-Object { try { $total+=$_.Length; Remove-Item $_.FullName -Force -EA Stop; $files++ } catch { $errs++ } }
        }
        $msg = "Temporales: $(Fmt $total) ($files archivos$(if ($errs) { ", $errs en uso" }))"
        SafeLog $msg; SafeStatus "Listo — $msg"
    } catch { SafeStatus "Error al limpiar temporales" }
}

function Quick-Optimize {
    try {
        SafeLog "=== Optimizacion rapida ==="; SafeStatus "Optimizando..."
        [System.GC]::Collect(2,[System.GCCollectionMode]::Forced); [System.GC]::WaitForPendingFinalizers()
        $total = 0L; $files = 0
        foreach ($p in @($env:TEMP, "$env:SystemRoot\Temp")) {
            if (-not (Test-Path $p)) { continue }
            Get-ChildItem $p -Recurse -Force -EA SilentlyContinue |
                Where-Object { -not $_.PSIsContainer } |
                ForEach-Object { try { $total+=$_.Length; Remove-Item $_.FullName -Force -EA Stop; $files++ } catch {} }
        }
        $skip = @('System','smss','csrss','wininit','winlogon','lsass','services',
                  'svchost','Registry','MsMpEng','dwm','fontdrvhost','Idle')
        $n = 0
        Get-Process -EA SilentlyContinue |
            Where-Object { $_.WorkingSet64 -gt 10MB -and $skip -notcontains $_.ProcessName } |
            Sort-Object WorkingSet64 -Descending | Select-Object -First 40 |
            ForEach-Object { try { $_.MinWorkingSet=[IntPtr]1; $_.MaxWorkingSet=[IntPtr]1; $n++ } catch {} }
        SafeLog "Temporales: $(Fmt $total) ($files archivos)"; SafeLog "RAM: $n procesos ajustados"
        SafeLog "=== Completado ==="
        SafeStatus "Listo — $(Fmt $total) + $n procesos"
    } catch { SafeStatus "Error en optimizacion" }
}

function Kill-Proc($pid2, $name) {
    try {
        $r = [System.Windows.MessageBox]::Show(
            "Terminar '$name' (PID $pid2)?`n`nEsto puede causar perdida de datos no guardados.",
            "Confirmar", [System.Windows.MessageBoxButton]::YesNo,
            [System.Windows.MessageBoxImage]::Warning)
        if ($r -eq [System.Windows.MessageBoxResult]::Yes) {
            Stop-Process -Id $pid2 -Force -EA Stop
            SafeLog "Proceso terminado: $name (PID $pid2)"
            SafeStatus "Proceso $name terminado"
        }
    } catch { SafeLog "No se pudo terminar $name (PID $pid2)" }
}

# ============================================================
#  AUTO-OPTIMIZACION
# ============================================================
$script:autoTimer   = $null
$script:autoMiItems = @($miAutoOff, $miAuto5, $miAuto15, $miAuto30)

function Set-AutoOptimize($minutes) {
    if ($script:autoTimer) { $script:autoTimer.Stop(); $script:autoTimer = $null }
    foreach ($mi in $script:autoMiItems) { $mi.IsChecked = $false }
    switch ($minutes) {
        0  { $miAutoOff.IsChecked = $true; SafeLog "Auto-optimizacion desactivada" }
        5  { $miAuto5.IsChecked   = $true }
        15 { $miAuto15.IsChecked  = $true }
        30 { $miAuto30.IsChecked  = $true }
    }
    if ($minutes -gt 0) {
        $script:autoTimer = [System.Windows.Threading.DispatcherTimer]::new()
        $script:autoTimer.Interval = [TimeSpan]::FromMinutes($minutes)
        $script:autoTimer.Add_Tick({ Quick-Optimize })
        $script:autoTimer.Start()
        SafeLog "Auto-optimizacion cada $minutes min activada"
    }
}

# ============================================================
#  BANDEJA DEL SISTEMA
# ============================================================
function Init-Tray {
    try {
        $script:trayIcon = New-Object System.Windows.Forms.NotifyIcon
        $icoPath = Join-Path $script:AppDir "icon.ico"
        if (Test-Path $icoPath) {
            try { $script:trayIcon.Icon = New-Object System.Drawing.Icon($icoPath) } catch {
                $script:trayIcon.Icon = [System.Drawing.SystemIcons]::Application
            }
        } else {
            try {
                $exeFile = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
                if ($exeFile -and (Test-Path $exeFile)) {
                    $script:trayIcon.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon($exeFile)
                } else { $script:trayIcon.Icon = [System.Drawing.SystemIcons]::Application }
            } catch { $script:trayIcon.Icon = [System.Drawing.SystemIcons]::Application }
        }
        $script:trayIcon.Visible = $true
        $script:trayIcon.Text    = "WinOptimizer"
        $ctxMenu = New-Object System.Windows.Forms.ContextMenuStrip
        $itmOpen     = $ctxMenu.Items.Add("Abrir WinOptimizer")
        $itmOptimize = $ctxMenu.Items.Add("Optimizar sistema")
        $itmFreeRam  = $ctxMenu.Items.Add("Liberar RAM")
        $null        = $ctxMenu.Items.Add("-")
        $itmExit     = $ctxMenu.Items.Add("Salir")
        $itmOpen.Add_Click({
            $window.Show(); $window.WindowState=[System.Windows.WindowState]::Normal; $window.Activate()
        })
        $itmOptimize.Add_Click({ Quick-Optimize })
        $itmFreeRam.Add_Click({  Free-RAM })
        $itmExit.Add_Click({
            $script:forceClose = $true
            try { $script:trayIcon.Visible=$false; $script:trayIcon.Dispose() } catch {}
            try { $script:timer.Stop() } catch {}
            try { if ($script:autoTimer) { $script:autoTimer.Stop() } } catch {}
            try { $script:bgPS.Stop() } catch {}; try { $script:bgRS.Close() } catch {}
            $window.Close()
        })
        $script:trayIcon.ContextMenuStrip = $ctxMenu
        $script:trayIcon.Add_DoubleClick({
            $window.Show(); $window.WindowState=[System.Windows.WindowState]::Normal; $window.Activate()
        })
    } catch {}
}

# ============================================================
#  EVENTOS
# ============================================================
$script:forceClose = $false
$btnOptimize.Add_Click({ Quick-Optimize }); $btnFreeRam.Add_Click({ Free-RAM })
$miOptimize.Add_Click({  Quick-Optimize }); $miFreeRam.Add_Click({  Free-RAM })
$miCleanTemp.Add_Click({ Clean-Temp });     $miRefresh.Add_Click({  Update-UI })
$miAutoOff.Add_Click({  Set-AutoOptimize 0  })
$miAuto5.Add_Click({    Set-AutoOptimize 5  })
$miAuto15.Add_Click({   Set-AutoOptimize 15 })
$miAuto30.Add_Click({   Set-AutoOptimize 30 })

# Kill buttons — closure por indice
for ($ki = 0; $ki -lt 5; $ki++) {
    $idx = $ki
    $killB[$idx].Add_Click({
        $pd  = [int]$killB[$idx].Tag
        $nm  = [string]$procN[$idx].Text
        if ($pd -gt 0 -and $nm -ne '') { Kill-Proc $pd $nm }
    }.GetNewClosure())
}

$miMinTray.Add_Click({
    $window.Hide()
    try { $script:trayIcon.ShowBalloonTip(2000,"WinOptimizer",
        "Minimizado. Doble clic para restaurar.",[System.Windows.Forms.ToolTipIcon]::Info) } catch {}
})
$miAlwaysTop.Add_Checked({   $window.Topmost = $true  })
$miAlwaysTop.Add_Unchecked({ $window.Topmost = $false })
$miStartup.Add_Click({
    try { Start-Process "taskmgr.exe" -ArgumentList "/7" } catch {
        try { Start-Process "ms-settings:startupapps" } catch {} }
})
$miPowerPlan.Add_Click({ try { Start-Process "powercfg.cpl" } catch {} })
$miAbout.Add_Click({
    $msg = "WinOptimizer v2.2.0`r`n"
    $msg += "Optimizador de rendimiento para Windows 10/11`r`n`r`n"
    $msg += "  RAM fisica, virtual y cache del sistema`r`n"
    $msg += "  CPU con temperatura + Disco + Red`r`n"
    $msg += "  Top 5 procesos con opcion Kill`r`n"
    $msg += "  Historial grafico 2 min + Bandeja`r`n"
    $msg += "  Auto-optimizacion programada`r`n`r`n"
    $msg += "Desarrollado por Enmanuel Gil`r`n"
    $msg += "github.com/EnMaNueL-G  —  MIT License"
    [System.Windows.MessageBox]::Show($msg,"Acerca de",
        [System.Windows.MessageBoxButton]::OK,[System.Windows.MessageBoxImage]::Information)
})
$miGithub.Add_Click({ try { Start-Process "https://github.com/EnMaNueL-G/WinOptimizer" } catch {} })
$miExit.Add_Click({
    $script:forceClose = $true
    try { $script:trayIcon.Visible=$false; $script:trayIcon.Dispose() } catch {}
    try { $script:timer.Stop() } catch {}
    try { if ($script:autoTimer) { $script:autoTimer.Stop() } } catch {}
    try { $script:bgPS.Stop() } catch {}; try { $script:bgRS.Close() } catch {}
    $window.Close()
})

# ============================================================
#  TIMER + ARRANQUE + CIERRE
# ============================================================
$script:timer          = [System.Windows.Threading.DispatcherTimer]::new()
$script:timer.Interval = [TimeSpan]::FromSeconds(2)
$script:timer.Add_Tick({ Update-UI })
$graphCanvas.Add_SizeChanged({ try { Update-Graph } catch {} })

$window.Add_Loaded({
    try { Init-Tray } catch {}
    Start-Worker
    $script:timer.Start()
    SafeLog "WinOptimizer v2.2.0 iniciado"
    SafeStatus "Cargando datos del sistema..."
})
$window.Add_Closing({
    if (-not $script:forceClose) {
        $_.Cancel = $true; $window.Hide()
        try { $script:trayIcon.ShowBalloonTip(2000,"WinOptimizer",
            "Sigue activo en la bandeja. Doble clic para abrir.",
            [System.Windows.Forms.ToolTipIcon]::Info) } catch {}
    }
})
$window.Add_Closed({
    try { $script:timer.Stop() } catch {}
    try { if ($script:autoTimer) { $script:autoTimer.Stop() } } catch {}
    try { $script:trayIcon.Dispose() } catch {}
    try { $script:bgPS.Stop() } catch {}; try { $script:bgRS.Close() } catch {}
})
$window.Add_KeyDown({
    if ($_.Key -eq [System.Windows.Input.Key]::F5) { Update-UI }
})

$window.ShowDialog() | Out-Null
