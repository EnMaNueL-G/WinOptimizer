#Requires -Version 5.1
<#
.SYNOPSIS
    WinOptimizer v2.1.0
    Optimizador de rendimiento para Windows 10/11
    Enmanuel Gil — github.com/EnMaNueL-G
.NOTES
    Supera a Mem Reduct:
      IGUALA  : Memoria fisica, Memoria virtual, Cache del sistema, Bandeja
      AGREGA  : CPU, Disco, Red, Top procesos, Historial grafico, Limpiar Temp,
                Inicio de Windows, Plan de energia
#>

Set-StrictMode -Off
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ============================================================
#  DATOS COMPARTIDOS  UI <-> Worker  (thread-safe)
# ============================================================
$script:d = [hashtable]::Synchronized(@{
    # RAM fisica
    CpuPct      = 0;    FreeMB      = 0L;  TotalMB   = 32768L
    CpuName     = 'Detectando...'
    # RAM virtual (pagefile)
    VirtUsedMB  = 0L;   VirtFreeMB  = 0L;  VirtTotalMB = 64000L; VirtPct = 0
    # Cache del sistema
    CacheMB     = 0L
    # Disco
    DiskFree    = 0L;   DiskTotal   = 1L
    # Red
    NetRxBps    = 0L;   NetTxBps    = 0L
    # Top procesos (array de hashtables {N,MB})
    TopProcs    = @()
    # Historial (arrays de int, 0-100)
    CpuHistory  = @();  RamHistory  = @()
    # Estado
    Tick        = 0
})

# ============================================================
#  BACKGROUND WORKER — todos los contadores en hilo separado
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
        # -- Inicializacion unica con CimInstance --
        try {
            $os  = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
            $cpu = Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1
            $d['TotalMB']  = [long]($os.TotalVisibleMemorySize / 1KB)
            $d['CpuName']  = $cpu.Name.Trim() -replace '\s+', ' '
        } catch { $d['CpuName'] = 'No disponible' }

        # -- Listas de historial locales al worker --
        $cpuH = New-Object System.Collections.Generic.List[int]
        $ramH = New-Object System.Collections.Generic.List[int]

        while ($true) {
            try {
                # CPU y RAM fisica via Performance Counters (rapidos)
                $cpuPct = [int]((Get-Counter '\Procesador(_Total)\% de tiempo de procesador' -ErrorAction Stop).CounterSamples[0].CookedValue)
                $freeMB = [long]((Get-Counter '\Memoria\Mbytes disponibles' -ErrorAction Stop).CounterSamples[0].CookedValue)

                $d['CpuPct'] = $cpuPct
                $d['FreeMB'] = $freeMB

                # RAM virtual + Cache via CIM Performance (rapido, basado en contadores)
                $pm = Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory -ErrorAction Stop
                $d['VirtUsedMB']  = [long]($pm.CommittedBytes / 1MB)
                $d['VirtTotalMB'] = [long]($pm.CommitLimit    / 1MB)
                $d['VirtFreeMB']  = [long](($pm.CommitLimit - $pm.CommittedBytes) / 1MB)
                $d['VirtPct']     = if ($pm.CommitLimit -gt 0) { [int](($pm.CommittedBytes / $pm.CommitLimit) * 100) } else { 0 }
                $d['CacheMB']     = [long]($pm.SystemCacheResidentBytes / 1MB)

                # Disco C:
                $dr = Get-PSDrive C -ErrorAction Stop
                $d['DiskFree']  = $dr.Free
                $d['DiskTotal'] = $dr.Free + $dr.Used

                # Red (adaptador activo con mas trafico)
                try {
                    $nic = Get-CimInstance Win32_PerfFormattedData_Tcpip_NetworkInterface -ErrorAction Stop |
                           Where-Object { $_.Name -notlike '*Loopback*' -and $_.Name -notlike '*Virtual*' } |
                           Sort-Object BytesTotalPersec -Descending | Select-Object -First 1
                    if ($nic) {
                        $d['NetRxBps'] = [long]$nic.BytesReceivedPersec
                        $d['NetTxBps'] = [long]$nic.BytesSentPersec
                    }
                } catch {}

                # Top 5 procesos por RAM fisica
                try {
                    $skip = @('System','smss','csrss','wininit','winlogon','Idle')
                    $top = Get-Process -ErrorAction SilentlyContinue |
                           Where-Object { $skip -notcontains $_.ProcessName } |
                           Sort-Object WorkingSet64 -Descending |
                           Select-Object -First 5 |
                           ForEach-Object { @{ N = $_.ProcessName; MB = [int]($_.WorkingSet64 / 1MB); PID = $_.Id } }
                    $d['TopProcs'] = @($top)
                } catch {}

                # Historial (max 60 muestras = 120 segundos)
                $ramPct = if ($d['TotalMB'] -gt 0) { [int](($d['TotalMB'] - $d['FreeMB']) * 100 / $d['TotalMB']) } else { 0 }
                $cpuH.Add($cpuPct)
                $ramH.Add($ramPct)
                if ($cpuH.Count -gt 60) { $cpuH.RemoveAt(0) }
                if ($ramH.Count -gt 60) { $ramH.RemoveAt(0) }
                $d['CpuHistory'] = $cpuH.ToArray()
                $d['RamHistory'] = $ramH.ToArray()

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
#  XAML — diseno compacto, superior a Mem Reduct
# ============================================================
[xml]$xaml = @"
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="WinOptimizer"
    Width="375" Height="700"
    MinWidth="320" MinHeight="500"
    WindowStartupLocation="CenterScreen"
    Background="#F0F0F0"
    FontFamily="Segoe UI" FontSize="12">

    <DockPanel LastChildFill="True">

        <!-- MENU -->
        <Menu DockPanel.Dock="Top" Background="#F0F0F0" Padding="2,2">
            <MenuItem Header="Archivo">
                <MenuItem x:Name="miMinTray" Header="Minimizar a bandeja"/>
                <Separator/>
                <MenuItem x:Name="miExit" Header="Salir"/>
            </MenuItem>
            <MenuItem Header="Ver">
                <MenuItem x:Name="miAlwaysTop" Header="Siempre visible" IsCheckable="True"/>
                <Separator/>
                <MenuItem x:Name="miRefresh" Header="Actualizar ahora  (F5)"/>
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

        <!-- STATUS BAR -->
        <StatusBar DockPanel.Dock="Bottom" Background="#DEDEDE">
            <StatusBarItem Padding="6,2">
                <TextBlock x:Name="txtStatus" Text="Iniciando..." FontSize="11" Foreground="#444"/>
            </StatusBarItem>
        </StatusBar>

        <!-- BOTONES -->
        <Border DockPanel.Dock="Bottom" Padding="8,6"
                Background="#EBEBEB" BorderBrush="#CCCCCC" BorderThickness="0,1,0,0">
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
                        BorderBrush="#005A9E" BorderThickness="1" Cursor="Hand"/>
                <Button x:Name="btnFreeRam" Grid.Column="2"
                        Content="Liberar RAM"
                        Padding="14,7" FontSize="12"
                        Background="#EBEBEB" Foreground="#1A1A1A"
                        BorderBrush="#ADADAD" BorderThickness="1" Cursor="Hand"/>
            </Grid>
        </Border>

        <!-- CONTENIDO PRINCIPAL -->
        <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
            <StackPanel Margin="8,4,8,4">

                <!-- 1. MEMORIA FISICA -->
                <GroupBox Margin="0,2,0,4" Padding="6,3,6,6" BorderBrush="#AAAACC" Background="White">
                    <GroupBox.Header>
                        <TextBlock Text="Memoria fisica" FontWeight="SemiBold" Foreground="#003399" FontSize="11"/>
                    </GroupBox.Header>
                    <Grid>
                        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="140"/></Grid.ColumnDefinitions>
                        <Grid.RowDefinitions>
                            <RowDefinition Height="20"/><RowDefinition Height="20"/>
                            <RowDefinition Height="20"/><RowDefinition Height="12"/>
                        </Grid.RowDefinitions>
                        <TextBlock Grid.Row="0" Grid.Column="0" Text="En uso"           VerticalAlignment="Center" Foreground="#555"/>
                        <TextBlock Grid.Row="1" Grid.Column="0" Text="Libre"            VerticalAlignment="Center" Foreground="#555"/>
                        <TextBlock Grid.Row="2" Grid.Column="0" Text="Total disponible" VerticalAlignment="Center" Foreground="#555"/>
                        <TextBlock x:Name="lblRamPct"   Grid.Row="0" Grid.Column="1" HorizontalAlignment="Right" VerticalAlignment="Center" FontWeight="Bold" Foreground="#BB1100" Text="--%  /  -- GB"/>
                        <TextBlock x:Name="lblRamFree"  Grid.Row="1" Grid.Column="1" HorizontalAlignment="Right" VerticalAlignment="Center" Text="-- GB"/>
                        <TextBlock x:Name="lblRamTotal" Grid.Row="2" Grid.Column="1" HorizontalAlignment="Right" VerticalAlignment="Center" Text="-- GB"/>
                        <ProgressBar x:Name="barRam" Grid.Row="3" Grid.ColumnSpan="2" Minimum="0" Maximum="100" Value="0" Height="6" Margin="0,3,0,0" Background="#E0E0E0" Foreground="#CC2200"/>
                    </Grid>
                </GroupBox>

                <!-- 2. MEMORIA VIRTUAL -->
                <GroupBox Margin="0,0,0,4" Padding="6,3,6,6" BorderBrush="#AAAACC" Background="White">
                    <GroupBox.Header>
                        <TextBlock Text="Memoria virtual (paginada)" FontWeight="SemiBold" Foreground="#003399" FontSize="11"/>
                    </GroupBox.Header>
                    <Grid>
                        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="140"/></Grid.ColumnDefinitions>
                        <Grid.RowDefinitions>
                            <RowDefinition Height="20"/><RowDefinition Height="20"/>
                            <RowDefinition Height="20"/><RowDefinition Height="12"/>
                        </Grid.RowDefinitions>
                        <TextBlock Grid.Row="0" Grid.Column="0" Text="En uso"           VerticalAlignment="Center" Foreground="#555"/>
                        <TextBlock Grid.Row="1" Grid.Column="0" Text="Libre"            VerticalAlignment="Center" Foreground="#555"/>
                        <TextBlock Grid.Row="2" Grid.Column="0" Text="Total disponible" VerticalAlignment="Center" Foreground="#555"/>
                        <TextBlock x:Name="lblVirtPct"   Grid.Row="0" Grid.Column="1" HorizontalAlignment="Right" VerticalAlignment="Center" FontWeight="Bold" Foreground="#BB1100" Text="--%  /  -- GB"/>
                        <TextBlock x:Name="lblVirtFree"  Grid.Row="1" Grid.Column="1" HorizontalAlignment="Right" VerticalAlignment="Center" Text="-- GB"/>
                        <TextBlock x:Name="lblVirtTotal" Grid.Row="2" Grid.Column="1" HorizontalAlignment="Right" VerticalAlignment="Center" Text="-- GB"/>
                        <ProgressBar x:Name="barVirt" Grid.Row="3" Grid.ColumnSpan="2" Minimum="0" Maximum="100" Value="0" Height="6" Margin="0,3,0,0" Background="#E0E0E0" Foreground="#9B59B6"/>
                    </Grid>
                </GroupBox>

                <!-- 3. CACHE DEL SISTEMA -->
                <GroupBox Margin="0,0,0,4" Padding="6,3,6,6" BorderBrush="#AAAACC" Background="White">
                    <GroupBox.Header>
                        <TextBlock Text="Cache del sistema" FontWeight="SemiBold" Foreground="#003399" FontSize="11"/>
                    </GroupBox.Header>
                    <Grid>
                        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="140"/></Grid.ColumnDefinitions>
                        <Grid.RowDefinitions><RowDefinition Height="20"/><RowDefinition Height="12"/></Grid.RowDefinitions>
                        <TextBlock Grid.Row="0" Grid.Column="0" Text="En uso (residente en RAM)" VerticalAlignment="Center" Foreground="#555"/>
                        <TextBlock x:Name="lblCacheMB" Grid.Row="0" Grid.Column="1" HorizontalAlignment="Right" VerticalAlignment="Center" FontWeight="Bold" Foreground="#007722" Text="-- MB"/>
                        <ProgressBar x:Name="barCache" Grid.Row="1" Grid.ColumnSpan="2" Minimum="0" Maximum="100" Value="0" Height="6" Margin="0,3,0,0" Background="#E0E0E0" Foreground="#22AA44"/>
                    </Grid>
                </GroupBox>

                <!-- 4. CPU -->
                <GroupBox Margin="0,0,0,4" Padding="6,3,6,6" BorderBrush="#AAAACC" Background="White">
                    <GroupBox.Header>
                        <TextBlock Text="Procesador (CPU)" FontWeight="SemiBold" Foreground="#003399" FontSize="11"/>
                    </GroupBox.Header>
                    <Grid>
                        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="140"/></Grid.ColumnDefinitions>
                        <Grid.RowDefinitions>
                            <RowDefinition Height="20"/><RowDefinition Height="20"/><RowDefinition Height="12"/>
                        </Grid.RowDefinitions>
                        <TextBlock Grid.Row="0" Grid.Column="0" Text="En uso"  VerticalAlignment="Center" Foreground="#555"/>
                        <TextBlock Grid.Row="1" Grid.Column="0" Text="Modelo"  VerticalAlignment="Center" Foreground="#555"/>
                        <TextBlock x:Name="lblCpuPct"  Grid.Row="0" Grid.Column="1" HorizontalAlignment="Right" VerticalAlignment="Center" FontWeight="Bold" Foreground="#BB1100" Text="--%"/>
                        <TextBlock x:Name="lblCpuName" Grid.Row="1" Grid.Column="1" HorizontalAlignment="Right" VerticalAlignment="Center" Foreground="#444" Text="..." TextTrimming="CharacterEllipsis"/>
                        <ProgressBar x:Name="barCpu" Grid.Row="2" Grid.ColumnSpan="2" Minimum="0" Maximum="100" Value="0" Height="6" Margin="0,3,0,0" Background="#E0E0E0" Foreground="#0078D4"/>
                    </Grid>
                </GroupBox>

                <!-- 5. ALMACENAMIENTO -->
                <GroupBox Margin="0,0,0,4" Padding="6,3,6,6" BorderBrush="#AAAACC" Background="White">
                    <GroupBox.Header>
                        <TextBlock Text="Almacenamiento (C:)" FontWeight="SemiBold" Foreground="#003399" FontSize="11"/>
                    </GroupBox.Header>
                    <Grid>
                        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="140"/></Grid.ColumnDefinitions>
                        <Grid.RowDefinitions>
                            <RowDefinition Height="20"/><RowDefinition Height="20"/>
                            <RowDefinition Height="20"/><RowDefinition Height="12"/>
                        </Grid.RowDefinitions>
                        <TextBlock Grid.Row="0" Grid.Column="0" Text="Libre"            VerticalAlignment="Center" Foreground="#555"/>
                        <TextBlock Grid.Row="1" Grid.Column="0" Text="Usado"            VerticalAlignment="Center" Foreground="#555"/>
                        <TextBlock Grid.Row="2" Grid.Column="0" Text="Total disponible" VerticalAlignment="Center" Foreground="#555"/>
                        <TextBlock x:Name="lblDiskFree"  Grid.Row="0" Grid.Column="1" HorizontalAlignment="Right" VerticalAlignment="Center" FontWeight="Bold" Foreground="#007722" Text="-- GB"/>
                        <TextBlock x:Name="lblDiskUsed"  Grid.Row="1" Grid.Column="1" HorizontalAlignment="Right" VerticalAlignment="Center" Text="-- GB"/>
                        <TextBlock x:Name="lblDiskTotal" Grid.Row="2" Grid.Column="1" HorizontalAlignment="Right" VerticalAlignment="Center" Text="-- GB"/>
                        <ProgressBar x:Name="barDisk" Grid.Row="3" Grid.ColumnSpan="2" Minimum="0" Maximum="100" Value="0" Height="6" Margin="0,3,0,0" Background="#E0E0E0" Foreground="#22AA44"/>
                    </Grid>
                </GroupBox>

                <!-- 6. RED -->
                <GroupBox Margin="0,0,0,4" Padding="6,3,6,6" BorderBrush="#AAAACC" Background="White">
                    <GroupBox.Header>
                        <TextBlock Text="Red" FontWeight="SemiBold" Foreground="#003399" FontSize="11"/>
                    </GroupBox.Header>
                    <Grid>
                        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="140"/></Grid.ColumnDefinitions>
                        <Grid.RowDefinitions><RowDefinition Height="20"/><RowDefinition Height="20"/></Grid.RowDefinitions>
                        <TextBlock Grid.Row="0" Grid.Column="0" Text="Recibiendo" VerticalAlignment="Center" Foreground="#555"/>
                        <TextBlock Grid.Row="1" Grid.Column="0" Text="Enviando"   VerticalAlignment="Center" Foreground="#555"/>
                        <TextBlock x:Name="lblNetRx" Grid.Row="0" Grid.Column="1" HorizontalAlignment="Right" VerticalAlignment="Center" FontWeight="Bold" Foreground="#0078D4" Text="-- KB/s"/>
                        <TextBlock x:Name="lblNetTx" Grid.Row="1" Grid.Column="1" HorizontalAlignment="Right" VerticalAlignment="Center" Foreground="#555" Text="-- KB/s"/>
                    </Grid>
                </GroupBox>

                <!-- 7. HISTORIAL GRAFICO -->
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

                <!-- 8. TOP PROCESOS -->
                <GroupBox Margin="0,0,0,4" Padding="6,3,6,6" BorderBrush="#AAAACC" Background="White">
                    <GroupBox.Header>
                        <TextBlock Text="Procesos (top 5 por RAM)" FontWeight="SemiBold" Foreground="#003399" FontSize="11"/>
                    </GroupBox.Header>
                    <Grid>
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="70"/>
                            <ColumnDefinition Width="55"/>
                        </Grid.ColumnDefinitions>
                        <Grid.RowDefinitions>
                            <RowDefinition Height="18"/><RowDefinition Height="18"/>
                            <RowDefinition Height="18"/><RowDefinition Height="18"/>
                            <RowDefinition Height="18"/>
                        </Grid.RowDefinitions>
                        <!-- proc0 -->
                        <TextBlock x:Name="p0n" Grid.Row="0" Grid.Column="0" VerticalAlignment="Center" Foreground="#333" TextTrimming="CharacterEllipsis"/>
                        <TextBlock x:Name="p0m" Grid.Row="0" Grid.Column="1" HorizontalAlignment="Right" VerticalAlignment="Center" Foreground="#BB1100"/>
                        <TextBlock x:Name="p0p" Grid.Row="0" Grid.Column="2" HorizontalAlignment="Right" VerticalAlignment="Center" Foreground="#999" FontSize="10"/>
                        <!-- proc1 -->
                        <TextBlock x:Name="p1n" Grid.Row="1" Grid.Column="0" VerticalAlignment="Center" Foreground="#333" TextTrimming="CharacterEllipsis"/>
                        <TextBlock x:Name="p1m" Grid.Row="1" Grid.Column="1" HorizontalAlignment="Right" VerticalAlignment="Center" Foreground="#BB1100"/>
                        <TextBlock x:Name="p1p" Grid.Row="1" Grid.Column="2" HorizontalAlignment="Right" VerticalAlignment="Center" Foreground="#999" FontSize="10"/>
                        <!-- proc2 -->
                        <TextBlock x:Name="p2n" Grid.Row="2" Grid.Column="0" VerticalAlignment="Center" Foreground="#333" TextTrimming="CharacterEllipsis"/>
                        <TextBlock x:Name="p2m" Grid.Row="2" Grid.Column="1" HorizontalAlignment="Right" VerticalAlignment="Center" Foreground="#BB1100"/>
                        <TextBlock x:Name="p2p" Grid.Row="2" Grid.Column="2" HorizontalAlignment="Right" VerticalAlignment="Center" Foreground="#999" FontSize="10"/>
                        <!-- proc3 -->
                        <TextBlock x:Name="p3n" Grid.Row="3" Grid.Column="0" VerticalAlignment="Center" Foreground="#333" TextTrimming="CharacterEllipsis"/>
                        <TextBlock x:Name="p3m" Grid.Row="3" Grid.Column="1" HorizontalAlignment="Right" VerticalAlignment="Center" Foreground="#BB1100"/>
                        <TextBlock x:Name="p3p" Grid.Row="3" Grid.Column="2" HorizontalAlignment="Right" VerticalAlignment="Center" Foreground="#999" FontSize="10"/>
                        <!-- proc4 -->
                        <TextBlock x:Name="p4n" Grid.Row="4" Grid.Column="0" VerticalAlignment="Center" Foreground="#333" TextTrimming="CharacterEllipsis"/>
                        <TextBlock x:Name="p4m" Grid.Row="4" Grid.Column="1" HorizontalAlignment="Right" VerticalAlignment="Center" Foreground="#BB1100"/>
                        <TextBlock x:Name="p4p" Grid.Row="4" Grid.Column="2" HorizontalAlignment="Right" VerticalAlignment="Center" Foreground="#999" FontSize="10"/>
                    </Grid>
                </GroupBox>

                <!-- 9. REGISTRO -->
                <GroupBox Margin="0,0,0,2" Padding="4,2,4,4" BorderBrush="#AAAACC" Background="White">
                    <GroupBox.Header>
                        <TextBlock Text="Registro de acciones" FontWeight="SemiBold" Foreground="#003399" FontSize="11"/>
                    </GroupBox.Header>
                    <TextBox x:Name="txtLog" Height="60" IsReadOnly="True"
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

# RAM
$lblRamPct    = Get-C "lblRamPct";   $lblRamFree  = Get-C "lblRamFree"
$lblRamTotal  = Get-C "lblRamTotal"; $barRam      = Get-C "barRam"
# Virtual
$lblVirtPct   = Get-C "lblVirtPct";  $lblVirtFree = Get-C "lblVirtFree"
$lblVirtTotal = Get-C "lblVirtTotal";$barVirt     = Get-C "barVirt"
# Cache
$lblCacheMB   = Get-C "lblCacheMB";  $barCache    = Get-C "barCache"
# CPU
$lblCpuPct    = Get-C "lblCpuPct";   $lblCpuName  = Get-C "lblCpuName"; $barCpu = Get-C "barCpu"
# Disco
$lblDiskFree  = Get-C "lblDiskFree"; $lblDiskUsed = Get-C "lblDiskUsed"
$lblDiskTotal = Get-C "lblDiskTotal";$barDisk     = Get-C "barDisk"
# Red
$lblNetRx     = Get-C "lblNetRx";    $lblNetTx    = Get-C "lblNetTx"
# Historial
$graphCanvas  = Get-C "graphCanvas"; $graphCpu    = Get-C "graphCpu"; $graphRam = Get-C "graphRam"
# Top procesos (arrays para iterar)
$procN = @(Get-C "p0n", Get-C "p1n", Get-C "p2n", Get-C "p3n", Get-C "p4n")
$procM = @(Get-C "p0m", Get-C "p1m", Get-C "p2m", Get-C "p3m", Get-C "p4m")
$procP = @(Get-C "p0p", Get-C "p1p", Get-C "p2p", Get-C "p3p", Get-C "p4p")
# Comunes
$txtLog    = Get-C "txtLog";  $txtStatus = Get-C "txtStatus"
$btnOptimize = Get-C "btnOptimize"; $btnFreeRam = Get-C "btnFreeRam"
# Menu
$miExit = Get-C "miExit";   $miAlwaysTop = Get-C "miAlwaysTop"; $miRefresh  = Get-C "miRefresh"
$miOptimize = Get-C "miOptimize"; $miFreeRam = Get-C "miFreeRam"
$miCleanTemp = Get-C "miCleanTemp"; $miStartup = Get-C "miStartup"; $miPowerPlan = Get-C "miPowerPlan"
$miAbout = Get-C "miAbout";  $miGithub = Get-C "miGithub"; $miMinTray = Get-C "miMinTray"

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
function Log($msg) {
    $t = (Get-Date).ToString("HH:mm:ss")
    $txtLog.AppendText("[$t] $msg`r`n")
    $txtLog.ScrollToEnd()
}
function Status($msg) { $txtStatus.Text = $msg }

# ============================================================
#  ACTUALIZAR GRAFICO
# ============================================================
function Update-Graph {
    $w = $graphCanvas.ActualWidth
    $h = $graphCanvas.ActualHeight
    if ($w -lt 2 -or $h -lt 2) { return }

    $cArr = $script:d['CpuHistory']
    $rArr = $script:d['RamHistory']
    $n    = if ($cArr) { $cArr.Count } else { 0 }
    if ($n -lt 2) { return }

    $pad = 3.0
    $cPts = New-Object System.Windows.Media.PointCollection
    $rPts = New-Object System.Windows.Media.PointCollection

    for ($i = 0; $i -lt $n; $i++) {
        $x  = [double]$i / ($n - 1) * $w
        $cy = $h - $pad - [double]$cArr[$i] / 100.0 * ($h - 2 * $pad)
        $ry = $h - $pad - [double]$rArr[$i] / 100.0 * ($h - 2 * $pad)
        $cPts.Add([System.Windows.Point]::new($x, $cy))
        $rPts.Add([System.Windows.Point]::new($x, $ry))
    }
    $graphCpu.Points = $cPts
    $graphRam.Points = $rPts
}

# ============================================================
#  ACTUALIZAR UI (llamado cada 2s desde DispatcherTimer)
# ============================================================
function Update-UI {
    # RAM fisica
    $freeMB  = $script:d['FreeMB']
    $totMB   = $script:d['TotalMB']
    $usedMB  = $totMB - $freeMB
    $ramPct  = if ($totMB -gt 0) { [int]($usedMB * 100 / $totMB) } else { 0 }
    $lblRamPct.Text   = "$ramPct%  /  $(FmtMB $usedMB)"
    $lblRamFree.Text  = FmtMB $freeMB
    $lblRamTotal.Text = FmtMB $totMB
    $barRam.Value     = [Math]::Min($ramPct, 100)

    # RAM virtual
    $vPct = $script:d['VirtPct']
    $lblVirtPct.Text   = "$vPct%  /  $(FmtMB $script:d['VirtUsedMB'])"
    $lblVirtFree.Text  = FmtMB $script:d['VirtFreeMB']
    $lblVirtTotal.Text = FmtMB $script:d['VirtTotalMB']
    $barVirt.Value     = [Math]::Min($vPct, 100)

    # Cache
    $cMB = $script:d['CacheMB']
    $lblCacheMB.Text = FmtMB $cMB
    $cachePct = if ($totMB -gt 0) { [int]($cMB * 100 / $totMB) } else { 0 }
    $barCache.Value  = [Math]::Min($cachePct, 100)

    # CPU
    $cpu = $script:d['CpuPct']
    $lblCpuPct.Text  = "$cpu%"
    $lblCpuName.Text = $script:d['CpuName']
    $barCpu.Value    = [Math]::Min($cpu, 100)

    # Disco
    $dfree  = $script:d['DiskFree']
    $dtotal = $script:d['DiskTotal']
    $dused  = $dtotal - $dfree
    $dpct   = if ($dtotal -gt 0) { [int]($dused * 100 / $dtotal) } else { 0 }
    $lblDiskFree.Text  = Fmt $dfree
    $lblDiskUsed.Text  = Fmt $dused
    $lblDiskTotal.Text = Fmt $dtotal
    $barDisk.Value     = [Math]::Min($dpct, 100)

    # Red
    $lblNetRx.Text = FmtNet $script:d['NetRxBps']
    $lblNetTx.Text = FmtNet $script:d['NetTxBps']

    # Top procesos
    $procs = $script:d['TopProcs']
    for ($i = 0; $i -lt 5; $i++) {
        if ($procs -and $i -lt $procs.Count) {
            $procN[$i].Text = $procs[$i]['N']
            $procM[$i].Text = "$($procs[$i]['MB']) MB"
            $procP[$i].Text = "PID $($procs[$i]['PID'])"
        } else {
            $procN[$i].Text = ""; $procM[$i].Text = ""; $procP[$i].Text = ""
        }
    }

    # Historial
    Update-Graph

    # Status bar
    $t = (Get-Date).ToString("HH:mm:ss")
    Status "Act. $t   CPU: $cpu%   RAM: $ramPct%   Disco: $(Fmt $dfree) libre"

    # Tray tooltip
    if ($script:trayIcon) {
        $tip = "WinOptimizer — CPU: $cpu%  RAM: $ramPct%  Disco: $(Fmt $dfree)"
        $script:trayIcon.Text = $tip.Substring(0, [Math]::Min($tip.Length, 127))
    }
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
              'svchost','Registry','MsMpEng','WmiPrvSE','dwm','fontdrvhost','Idle')
    $n = 0
    Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $_.WorkingSet64 -gt 10MB -and $skip -notcontains $_.ProcessName } |
        Sort-Object WorkingSet64 -Descending | Select-Object -First 40 |
        ForEach-Object {
            try { $_.MinWorkingSet = [IntPtr]1; $_.MaxWorkingSet = [IntPtr]1; $n++ } catch {}
        }

    Start-Sleep -Milliseconds 600
    $after = $script:d['FreeMB']
    $freed = ($after - $before) * 1MB
    if ($freed -lt 0) { $freed = 0 }

    $msg = if ($freed -gt 1MB) { "RAM liberada: $(Fmt $freed) ($n procesos ajustados)" }
           else                { "RAM optimizada ($n procesos ajustados)" }
    Log $msg
    Status "Listo — $msg"
}

# ============================================================
#  LIMPIAR TEMPORALES
# ============================================================
function Clean-Temp {
    Status "Limpiando archivos temporales..."
    $paths  = @($env:TEMP, "$env:SystemRoot\Temp")
    $total  = 0L; $files = 0; $errs = 0
    foreach ($p in $paths) {
        if (-not (Test-Path $p)) { continue }
        Get-ChildItem $p -Recurse -Force -ErrorAction SilentlyContinue |
            Where-Object { -not $_.PSIsContainer } |
            ForEach-Object {
                try   { $total += $_.Length; Remove-Item $_.FullName -Force -ErrorAction Stop; $files++ }
                catch { $errs++ }
            }
    }
    $msg = "Temporales: $(Fmt $total) ($files archivos"
    if ($errs -gt 0) { $msg += ", $errs en uso" }
    $msg += ")"
    Log $msg
    Status "Listo — $msg"
}

# ============================================================
#  OPTIMIZACION RAPIDA
# ============================================================
function Quick-Optimize {
    Log "=== Optimizacion rapida iniciada ==="
    Status "Optimizando..."
    [System.GC]::Collect(2, [System.GCCollectionMode]::Forced)
    [System.GC]::WaitForPendingFinalizers()
    Log "GC completado"
    $paths = @($env:TEMP, "$env:SystemRoot\Temp")
    $total = 0L; $files = 0
    foreach ($p in $paths) {
        if (-not (Test-Path $p)) { continue }
        Get-ChildItem $p -Recurse -Force -ErrorAction SilentlyContinue |
            Where-Object { -not $_.PSIsContainer } |
            ForEach-Object { try { $total += $_.Length; Remove-Item $_.FullName -Force -ErrorAction Stop; $files++ } catch {} }
    }
    Log "Temporales: $(Fmt $total) ($files archivos)"
    Log "=== Completado ==="
    Status "Optimizacion completa — $(Fmt $total) liberados"
}

# ============================================================
#  BANDEJA DEL SISTEMA (System Tray)
# ============================================================
function Init-Tray {
    $script:trayIcon = New-Object System.Windows.Forms.NotifyIcon

    # Icono: intentar icon.ico junto al script, si no usar el exe
    $icoPath = Join-Path $PSScriptRoot "icon.ico"
    if (Test-Path $icoPath) {
        try { $script:trayIcon.Icon = New-Object System.Drawing.Icon($icoPath) } catch {
            $script:trayIcon.Icon = [System.Drawing.SystemIcons]::Application
        }
    } else {
        try {
            $exePath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
            $script:trayIcon.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon($exePath)
        } catch { $script:trayIcon.Icon = [System.Drawing.SystemIcons]::Application }
    }

    $script:trayIcon.Visible = $true
    $script:trayIcon.Text    = "WinOptimizer"

    # Menu contextual del tray
    $ctxMenu     = New-Object System.Windows.Forms.ContextMenuStrip
    $itmOpen     = $ctxMenu.Items.Add("Abrir WinOptimizer")
    $itmOptimize = $ctxMenu.Items.Add("Optimizar sistema")
    $itmFreeRam  = $ctxMenu.Items.Add("Liberar RAM")
    $null = $ctxMenu.Items.Add("-")
    $itmExit     = $ctxMenu.Items.Add("Salir")

    $itmOpen.Add_Click({
        $window.Show()
        $window.WindowState = [System.Windows.WindowState]::Normal
        $window.Activate()
    })
    $itmOptimize.Add_Click({ Quick-Optimize })
    $itmFreeRam.Add_Click({  Free-RAM       })
    $itmExit.Add_Click({
        $script:forceClose = $true
        $script:trayIcon.Visible = $false
        $script:trayIcon.Dispose()
        $script:timer.Stop()
        try { $script:bgPS.Stop() } catch {}
        try { $script:bgRS.Close() } catch {}
        $window.Close()
    })
    $script:trayIcon.ContextMenuStrip = $ctxMenu

    # Doble clic en icono de bandeja = mostrar ventana
    $script:trayIcon.Add_DoubleClick({
        $window.Show()
        $window.WindowState = [System.Windows.WindowState]::Normal
        $window.Activate()
    })
}

# ============================================================
#  HANDLERS DE EVENTOS
# ============================================================
$script:forceClose = $false

$btnOptimize.Add_Click({ Quick-Optimize })
$btnFreeRam.Add_Click({  Free-RAM       })

$miOptimize.Add_Click({  Quick-Optimize })
$miFreeRam.Add_Click({   Free-RAM       })
$miCleanTemp.Add_Click({ Clean-Temp     })
$miRefresh.Add_Click({   Update-UI      })

$miMinTray.Add_Click({
    $window.Hide()
    if ($script:trayIcon) {
        $script:trayIcon.ShowBalloonTip(2000, "WinOptimizer",
            "Minimizado a la bandeja del sistema. Doble clic para restaurar.",
            [System.Windows.Forms.ToolTipIcon]::Info)
    }
})

$miAlwaysTop.Add_Checked({   $window.Topmost = $true  })
$miAlwaysTop.Add_Unchecked({ $window.Topmost = $false })

$miStartup.Add_Click({
    try { Start-Process "taskmgr.exe" -ArgumentList "/7" } catch {
        try { Start-Process "ms-settings:startupapps" } catch {}
    }
})
$miPowerPlan.Add_Click({ Start-Process "powercfg.cpl" -ErrorAction SilentlyContinue })
$miAbout.Add_Click({
    $msg  = "WinOptimizer v2.1.0`r`n"
    $msg += "Optimizador de rendimiento para Windows 10/11`r`n`r`n"
    $msg += "Funciones principales:`r`n"
    $msg += "  Memoria fisica, virtual y cache del sistema`r`n"
    $msg += "  CPU, Disco, Red, Top procesos, Historial`r`n"
    $msg += "  Liberar RAM, Limpiar temp, Inicio, Plan energia`r`n`r`n"
    $msg += "Desarrollado por Enmanuel Gil`r`n"
    $msg += "github.com/EnMaNueL-G  —  Licencia MIT"
    [System.Windows.MessageBox]::Show($msg, "Acerca de WinOptimizer",
        [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
})
$miGithub.Add_Click({ Start-Process "https://github.com/EnMaNueL-G/WinOptimizer" })
$miExit.Add_Click({
    $script:forceClose = $true
    if ($script:trayIcon) { $script:trayIcon.Visible = $false; $script:trayIcon.Dispose() }
    $script:timer.Stop()
    try { $script:bgPS.Stop() } catch {}
    try { $script:bgRS.Close() } catch {}
    $window.Close()
})

# ============================================================
#  TIMER + ARRANQUE + CIERRE
# ============================================================
$script:timer = [System.Windows.Threading.DispatcherTimer]::new()
$script:timer.Interval = [TimeSpan]::FromSeconds(2)
$script:timer.Add_Tick({ Update-UI })

$graphCanvas.Add_SizeChanged({ Update-Graph })

$window.Add_Loaded({
    Init-Tray
    Start-Worker
    $script:timer.Start()
    Log "WinOptimizer v2.1.0 iniciado"
    Status "Cargando datos del sistema..."
})

$window.Add_Closing({
    if (-not $script:forceClose) {
        $_.Cancel = $true
        $window.Hide()
        if ($script:trayIcon) {
            $script:trayIcon.ShowBalloonTip(2000, "WinOptimizer",
                "Sigue activo en la bandeja. Doble clic para abrir.",
                [System.Windows.Forms.ToolTipIcon]::Info)
        }
    }
})

$window.Add_Closed({
    $script:timer.Stop()
    if ($script:trayIcon) { try { $script:trayIcon.Dispose() } catch {} }
    try { $script:bgPS.Stop() } catch {}
    try { $script:bgRS.Close() } catch {}
})

$window.Add_KeyDown({
    if ($_.Key -eq [System.Windows.Input.Key]::F5) { Update-UI }
})

$window.ShowDialog() | Out-Null
