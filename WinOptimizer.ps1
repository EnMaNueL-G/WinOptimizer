#Requires -Version 5.1
<#
.SYNOPSIS
    WinOptimizer v2.3.0
    Optimizador de rendimiento para Windows 10/11
    Enmanuel Gil - github.com/EnMaNueL-G
#>
Set-StrictMode -Off

# Ruta segura (PSScriptRoot = null en EXE compilado)
if ($PSScriptRoot -and $PSScriptRoot -ne '') {
    $script:AppDir = $PSScriptRoot
} else {
    try { $script:AppDir = Split-Path -Parent ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) }
    catch { $script:AppDir = $env:TEMP }
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

# ============================================================
#  DATOS COMPARTIDOS (thread-safe, solo tipos primitivos)
# ============================================================
$script:d = [hashtable]::Synchronized(@{
    CpuPct=0; FreeMB=0L; TotalMB=32768L; CpuName='Detectando...'; CpuTempC=-1
    VirtUsedMB=0L; VirtFreeMB=0L; VirtTotalMB=64000L; VirtPct=0; CacheMB=0L
    DiskFree=0L; DiskTotal=1L; NetRxBps=0L; NetTxBps=0L
    TopProcNames=[string[]]@('','','','','')
    TopProcMBs=[int[]]@(0,0,0,0,0)
    TopProcPIDs=[int[]]@(0,0,0,0,0)
    CpuHistory=[int[]]@(); RamHistory=[int[]]@(); Tick=0
})

# ============================================================
#  BACKGROUND WORKER
# ============================================================
function Start-Worker {
    $rs = [RunspaceFactory]::CreateRunspace()
    $rs.ApartmentState='STA'; $rs.ThreadOptions='ReuseThread'; $rs.Open()
    $rs.SessionStateProxy.SetVariable('d', $script:d)
    $ps = [PowerShell]::Create(); $ps.Runspace = $rs
    $null = $ps.AddScript({
        try {
            $os  = Get-CimInstance Win32_OperatingSystem -EA Stop
            $cpu = Get-CimInstance Win32_Processor       -EA Stop | Select-Object -First 1
            $d['TotalMB'] = [long]($os.TotalVisibleMemorySize / 1KB)
            $d['CpuName'] = ($cpu.Name.Trim() -replace '\s+', ' ')
        } catch {}
        $cpuH = New-Object System.Collections.Generic.List[int]
        $ramH = New-Object System.Collections.Generic.List[int]
        while ($true) {
            try {
                $d['CpuPct'] = [int]((Get-Counter '\Procesador(_Total)\% de tiempo de procesador' -EA Stop).CounterSamples[0].CookedValue)
                $d['FreeMB'] = [long]((Get-Counter '\Memoria\Mbytes disponibles' -EA Stop).CounterSamples[0].CookedValue)
            } catch {}
            try {
                $pm = Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory -EA Stop
                $d['VirtUsedMB']  = [long]($pm.CommittedBytes / 1MB)
                $d['VirtTotalMB'] = [long]($pm.CommitLimit    / 1MB)
                $d['VirtFreeMB']  = [long](($pm.CommitLimit - $pm.CommittedBytes) / 1MB)
                $d['VirtPct']     = if ($pm.CommitLimit -gt 0) { [int](($pm.CommittedBytes/$pm.CommitLimit)*100) } else { 0 }
                $d['CacheMB']     = [long]($pm.SystemCacheResidentBytes / 1MB)
            } catch {}
            try {
                $t = Get-CimInstance -Namespace 'root/WMI' -ClassName MSAcpi_ThermalZoneTemperature -EA Stop | Select-Object -First 1
                $d['CpuTempC'] = if ($t) { [int](($t.CurrentTemperature - 2732) / 10) } else { -1 }
            } catch { $d['CpuTempC'] = -1 }
            try { $dr = Get-PSDrive C -EA Stop; $d['DiskFree']=$dr.Free; $d['DiskTotal']=$dr.Free+$dr.Used } catch {}
            try {
                $nic = Get-CimInstance Win32_PerfFormattedData_Tcpip_NetworkInterface -EA Stop |
                    Where-Object { $_.Name -notlike '*Loopback*' -and $_.Name -notlike '*Virtual*' } |
                    Sort-Object BytesTotalPersec -Descending | Select-Object -First 1
                if ($nic) { $d['NetRxBps']=[long]$nic.BytesReceivedPersec; $d['NetTxBps']=[long]$nic.BytesSentPersec }
            } catch {}
            try {
                $skip = @('System','smss','csrss','wininit','winlogon','lsass','services',
                          'svchost','Registry','MsMpEng','dwm','fontdrvhost','Idle','WmiPrvSE')
                $top = @(Get-Process -EA SilentlyContinue | Where-Object { $skip -notcontains $_.ProcessName } |
                    Sort-Object WorkingSet64 -Descending | Select-Object -First 5)
                $nm=[string[]]@('','','','',''); $mb=[int[]]@(0,0,0,0,0); $pd=[int[]]@(0,0,0,0,0)
                for ($i=0; $i -lt [Math]::Min($top.Count,5); $i++) {
                    $nm[$i]=[string]$top[$i].ProcessName; $mb[$i]=[int]($top[$i].WorkingSet64/1MB); $pd[$i]=[int]$top[$i].Id
                }
                $d['TopProcNames']=$nm; $d['TopProcMBs']=$mb; $d['TopProcPIDs']=$pd
            } catch {}
            try {
                $rp = if ($d['TotalMB'] -gt 0) { [int](($d['TotalMB']-$d['FreeMB'])*100/$d['TotalMB']) } else { 0 }
                $cpuH.Add($d['CpuPct']); $ramH.Add($rp)
                if ($cpuH.Count -gt 60) { $cpuH.RemoveAt(0) }
                if ($ramH.Count -gt 60) { $ramH.RemoveAt(0) }
                $d['CpuHistory']=[int[]]$cpuH.ToArray(); $d['RamHistory']=[int[]]$ramH.ToArray()
            } catch {}
            $d['Tick']++
            Start-Sleep -Seconds 2
        }
    })
    $null = $ps.BeginInvoke()
    $script:bgPS=$ps; $script:bgRS=$rs
}

# ============================================================
#  XAML
# ============================================================
[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="WinOptimizer" Width="390" Height="780"
        MinWidth="340" MinHeight="500"
        WindowStartupLocation="CenterScreen"
        Background="#F0F0F0" FontFamily="Segoe UI" FontSize="12">
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
        <MenuItem x:Name="miRefresh"   Header="Actualizar ahora (F5)"/>
      </MenuItem>
      <MenuItem Header="Herramientas">
        <MenuItem x:Name="miOptimize"  Header="Optimizar sistema"/>
        <MenuItem x:Name="miFreeRam"   Header="Liberar RAM"/>
        <Separator/>
        <MenuItem x:Name="miCleanTemp" Header="Limpiar archivos temporales"/>
        <MenuItem x:Name="miPowerPlan" Header="Plan de energia..."/>
        <Separator/>
        <MenuItem x:Name="miAutoOff"   Header="Auto-opt: Desactivada"     IsCheckable="True" IsChecked="True"/>
        <MenuItem x:Name="miAuto5"     Header="Auto-opt: Cada 5 minutos"  IsCheckable="True"/>
        <MenuItem x:Name="miAuto15"    Header="Auto-opt: Cada 15 minutos" IsCheckable="True"/>
        <MenuItem x:Name="miAuto30"    Header="Auto-opt: Cada 30 minutos" IsCheckable="True"/>
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

    <Border DockPanel.Dock="Bottom" Padding="8,6" Background="#EBEBEB" BorderBrush="#CCCCCC" BorderThickness="0,1,0,0">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/><ColumnDefinition Width="5"/><ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <Button x:Name="btnOptimize" Grid.Column="0" Content="Optimizar sistema"
                Padding="0,7" FontWeight="SemiBold" FontSize="12"
                Background="#0078D4" Foreground="White" BorderBrush="#005A9E" BorderThickness="1" Cursor="Hand"/>
        <Button x:Name="btnFreeRam"  Grid.Column="2" Content="Liberar RAM"
                Padding="14,7" FontSize="12"
                Background="#EBEBEB" Foreground="#1A1A1A" BorderBrush="#ADADAD" BorderThickness="1" Cursor="Hand"/>
      </Grid>
    </Border>

    <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
      <StackPanel Margin="8,4,8,4">

        <!-- MEMORIA FISICA -->
        <GroupBox Margin="0,2,0,4" Padding="6,3,6,6" BorderBrush="#AAAACC" Background="White">
          <GroupBox.Header><TextBlock Text="Memoria fisica" FontWeight="SemiBold" Foreground="#003399" FontSize="11"/></GroupBox.Header>
          <Grid>
            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="150"/></Grid.ColumnDefinitions>
            <Grid.RowDefinitions><RowDefinition Height="20"/><RowDefinition Height="20"/><RowDefinition Height="20"/><RowDefinition Height="12"/></Grid.RowDefinitions>
            <TextBlock Grid.Row="0" Grid.Column="0" Text="En uso"           VerticalAlignment="Center" Foreground="#555"/>
            <TextBlock Grid.Row="1" Grid.Column="0" Text="Libre"            VerticalAlignment="Center" Foreground="#555"/>
            <TextBlock Grid.Row="2" Grid.Column="0" Text="Total disponible" VerticalAlignment="Center" Foreground="#555"/>
            <TextBlock x:Name="lblRamPct"   Grid.Row="0" Grid.Column="1" HorizontalAlignment="Right" VerticalAlignment="Center" FontWeight="Bold" Foreground="#BB1100" Text="--"/>
            <TextBlock x:Name="lblRamFree"  Grid.Row="1" Grid.Column="1" HorizontalAlignment="Right" VerticalAlignment="Center" Text="--"/>
            <TextBlock x:Name="lblRamTotal" Grid.Row="2" Grid.Column="1" HorizontalAlignment="Right" VerticalAlignment="Center" Text="--"/>
            <ProgressBar x:Name="barRam" Grid.Row="3" Grid.ColumnSpan="2" Minimum="0" Maximum="100" Value="0" Height="6" Margin="0,3,0,0" Background="#E0E0E0" Foreground="#CC2200"/>
          </Grid>
        </GroupBox>

        <!-- MEMORIA VIRTUAL -->
        <GroupBox Margin="0,0,0,4" Padding="6,3,6,6" BorderBrush="#AAAACC" Background="White">
          <GroupBox.Header><TextBlock Text="Memoria virtual (paginada)" FontWeight="SemiBold" Foreground="#003399" FontSize="11"/></GroupBox.Header>
          <Grid>
            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="150"/></Grid.ColumnDefinitions>
            <Grid.RowDefinitions><RowDefinition Height="20"/><RowDefinition Height="20"/><RowDefinition Height="20"/><RowDefinition Height="12"/></Grid.RowDefinitions>
            <TextBlock Grid.Row="0" Grid.Column="0" Text="En uso"           VerticalAlignment="Center" Foreground="#555"/>
            <TextBlock Grid.Row="1" Grid.Column="0" Text="Libre"            VerticalAlignment="Center" Foreground="#555"/>
            <TextBlock Grid.Row="2" Grid.Column="0" Text="Total disponible" VerticalAlignment="Center" Foreground="#555"/>
            <TextBlock x:Name="lblVirtPct"   Grid.Row="0" Grid.Column="1" HorizontalAlignment="Right" VerticalAlignment="Center" FontWeight="Bold" Foreground="#BB1100" Text="--"/>
            <TextBlock x:Name="lblVirtFree"  Grid.Row="1" Grid.Column="1" HorizontalAlignment="Right" VerticalAlignment="Center" Text="--"/>
            <TextBlock x:Name="lblVirtTotal" Grid.Row="2" Grid.Column="1" HorizontalAlignment="Right" VerticalAlignment="Center" Text="--"/>
            <ProgressBar x:Name="barVirt" Grid.Row="3" Grid.ColumnSpan="2" Minimum="0" Maximum="100" Value="0" Height="6" Margin="0,3,0,0" Background="#E0E0E0" Foreground="#9B59B6"/>
          </Grid>
        </GroupBox>

        <!-- CACHE -->
        <GroupBox Margin="0,0,0,4" Padding="6,3,6,6" BorderBrush="#AAAACC" Background="White">
          <GroupBox.Header><TextBlock Text="Cache del sistema" FontWeight="SemiBold" Foreground="#003399" FontSize="11"/></GroupBox.Header>
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
          <GroupBox.Header><TextBlock Text="Procesador (CPU)" FontWeight="SemiBold" Foreground="#003399" FontSize="11"/></GroupBox.Header>
          <Grid>
            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="150"/></Grid.ColumnDefinitions>
            <Grid.RowDefinitions><RowDefinition Height="20"/><RowDefinition Height="20"/><RowDefinition Height="20"/><RowDefinition Height="12"/></Grid.RowDefinitions>
            <TextBlock Grid.Row="0" Grid.Column="0" Text="En uso"      VerticalAlignment="Center" Foreground="#555"/>
            <TextBlock Grid.Row="1" Grid.Column="0" Text="Temperatura" VerticalAlignment="Center" Foreground="#555"/>
            <TextBlock Grid.Row="2" Grid.Column="0" Text="Modelo"      VerticalAlignment="Center" Foreground="#555"/>
            <TextBlock x:Name="lblCpuPct"  Grid.Row="0" Grid.Column="1" HorizontalAlignment="Right" VerticalAlignment="Center" FontWeight="Bold" Foreground="#BB1100" Text="--"/>
            <TextBlock x:Name="lblCpuTemp" Grid.Row="1" Grid.Column="1" HorizontalAlignment="Right" VerticalAlignment="Center" Foreground="#555" Text="--"/>
            <TextBlock x:Name="lblCpuName" Grid.Row="2" Grid.Column="1" HorizontalAlignment="Right" VerticalAlignment="Center" Foreground="#444" Text="..." TextTrimming="CharacterEllipsis"/>
            <ProgressBar x:Name="barCpu" Grid.Row="3" Grid.ColumnSpan="2" Minimum="0" Maximum="100" Value="0" Height="6" Margin="0,3,0,0" Background="#E0E0E0" Foreground="#0078D4"/>
          </Grid>
        </GroupBox>

        <!-- DISCO -->
        <GroupBox Margin="0,0,0,4" Padding="6,3,6,6" BorderBrush="#AAAACC" Background="White">
          <GroupBox.Header><TextBlock Text="Almacenamiento (C:)" FontWeight="SemiBold" Foreground="#003399" FontSize="11"/></GroupBox.Header>
          <Grid>
            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="150"/></Grid.ColumnDefinitions>
            <Grid.RowDefinitions><RowDefinition Height="20"/><RowDefinition Height="20"/><RowDefinition Height="20"/><RowDefinition Height="12"/></Grid.RowDefinitions>
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
          <GroupBox.Header><TextBlock Text="Red" FontWeight="SemiBold" Foreground="#003399" FontSize="11"/></GroupBox.Header>
          <Grid>
            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="150"/></Grid.ColumnDefinitions>
            <Grid.RowDefinitions><RowDefinition Height="20"/><RowDefinition Height="20"/></Grid.RowDefinitions>
            <TextBlock Grid.Row="0" Grid.Column="0" Text="Recibiendo" VerticalAlignment="Center" Foreground="#555"/>
            <TextBlock Grid.Row="1" Grid.Column="0" Text="Enviando"   VerticalAlignment="Center" Foreground="#555"/>
            <TextBlock x:Name="lblNetRx" Grid.Row="0" Grid.Column="1" HorizontalAlignment="Right" VerticalAlignment="Center" FontWeight="Bold" Foreground="#0078D4" Text="--"/>
            <TextBlock x:Name="lblNetTx" Grid.Row="1" Grid.Column="1" HorizontalAlignment="Right" VerticalAlignment="Center" Foreground="#555" Text="--"/>
          </Grid>
        </GroupBox>

        <!-- HISTORIAL -->
        <GroupBox Margin="0,0,0,4" Padding="6,3,6,4" BorderBrush="#AAAACC" Background="White">
          <GroupBox.Header><TextBlock Text="Historial (2 min)" FontWeight="SemiBold" Foreground="#003399" FontSize="11"/></GroupBox.Header>
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

        <!-- TOP PROCESOS -->
        <GroupBox Margin="0,0,0,4" Padding="6,3,6,6" BorderBrush="#AAAACC" Background="White">
          <GroupBox.Header><TextBlock Text="Procesos (top 5 por RAM)" FontWeight="SemiBold" Foreground="#003399" FontSize="11"/></GroupBox.Header>
          <Grid>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/><ColumnDefinition Width="60"/>
              <ColumnDefinition Width="44"/><ColumnDefinition Width="34"/>
            </Grid.ColumnDefinitions>
            <Grid.RowDefinitions>
              <RowDefinition Height="22"/><RowDefinition Height="22"/><RowDefinition Height="22"/>
              <RowDefinition Height="22"/><RowDefinition Height="22"/>
            </Grid.RowDefinitions>
            <TextBlock x:Name="p0n" Grid.Row="0" Grid.Column="0" VerticalAlignment="Center" Foreground="#333" TextTrimming="CharacterEllipsis"/>
            <TextBlock x:Name="p0m" Grid.Row="0" Grid.Column="1" HorizontalAlignment="Right" VerticalAlignment="Center" Foreground="#BB1100"/>
            <TextBlock x:Name="p0p" Grid.Row="0" Grid.Column="2" HorizontalAlignment="Right" VerticalAlignment="Center" Foreground="#999" FontSize="10"/>
            <Button   x:Name="k0"  Grid.Row="0" Grid.Column="3" Content="Kill" Tag="0" Padding="2,1" FontSize="10" Margin="2,1" Background="#FFEEEE" BorderBrush="#CC4444" Foreground="#AA0000" Cursor="Hand" Visibility="Collapsed"/>
            <TextBlock x:Name="p1n" Grid.Row="1" Grid.Column="0" VerticalAlignment="Center" Foreground="#333" TextTrimming="CharacterEllipsis"/>
            <TextBlock x:Name="p1m" Grid.Row="1" Grid.Column="1" HorizontalAlignment="Right" VerticalAlignment="Center" Foreground="#BB1100"/>
            <TextBlock x:Name="p1p" Grid.Row="1" Grid.Column="2" HorizontalAlignment="Right" VerticalAlignment="Center" Foreground="#999" FontSize="10"/>
            <Button   x:Name="k1"  Grid.Row="1" Grid.Column="3" Content="Kill" Tag="0" Padding="2,1" FontSize="10" Margin="2,1" Background="#FFEEEE" BorderBrush="#CC4444" Foreground="#AA0000" Cursor="Hand" Visibility="Collapsed"/>
            <TextBlock x:Name="p2n" Grid.Row="2" Grid.Column="0" VerticalAlignment="Center" Foreground="#333" TextTrimming="CharacterEllipsis"/>
            <TextBlock x:Name="p2m" Grid.Row="2" Grid.Column="1" HorizontalAlignment="Right" VerticalAlignment="Center" Foreground="#BB1100"/>
            <TextBlock x:Name="p2p" Grid.Row="2" Grid.Column="2" HorizontalAlignment="Right" VerticalAlignment="Center" Foreground="#999" FontSize="10"/>
            <Button   x:Name="k2"  Grid.Row="2" Grid.Column="3" Content="Kill" Tag="0" Padding="2,1" FontSize="10" Margin="2,1" Background="#FFEEEE" BorderBrush="#CC4444" Foreground="#AA0000" Cursor="Hand" Visibility="Collapsed"/>
            <TextBlock x:Name="p3n" Grid.Row="3" Grid.Column="0" VerticalAlignment="Center" Foreground="#333" TextTrimming="CharacterEllipsis"/>
            <TextBlock x:Name="p3m" Grid.Row="3" Grid.Column="1" HorizontalAlignment="Right" VerticalAlignment="Center" Foreground="#BB1100"/>
            <TextBlock x:Name="p3p" Grid.Row="3" Grid.Column="2" HorizontalAlignment="Right" VerticalAlignment="Center" Foreground="#999" FontSize="10"/>
            <Button   x:Name="k3"  Grid.Row="3" Grid.Column="3" Content="Kill" Tag="0" Padding="2,1" FontSize="10" Margin="2,1" Background="#FFEEEE" BorderBrush="#CC4444" Foreground="#AA0000" Cursor="Hand" Visibility="Collapsed"/>
            <TextBlock x:Name="p4n" Grid.Row="4" Grid.Column="0" VerticalAlignment="Center" Foreground="#333" TextTrimming="CharacterEllipsis"/>
            <TextBlock x:Name="p4m" Grid.Row="4" Grid.Column="1" HorizontalAlignment="Right" VerticalAlignment="Center" Foreground="#BB1100"/>
            <TextBlock x:Name="p4p" Grid.Row="4" Grid.Column="2" HorizontalAlignment="Right" VerticalAlignment="Center" Foreground="#999" FontSize="10"/>
            <Button   x:Name="k4"  Grid.Row="4" Grid.Column="3" Content="Kill" Tag="0" Padding="2,1" FontSize="10" Margin="2,1" Background="#FFEEEE" BorderBrush="#CC4444" Foreground="#AA0000" Cursor="Hand" Visibility="Collapsed"/>
          </Grid>
        </GroupBox>

        <!-- INICIO DE WINDOWS (integrado) -->
        <GroupBox Margin="0,0,0,4" Padding="6,3,6,6" BorderBrush="#AAAACC" Background="White">
          <GroupBox.Header>
            <StackPanel Orientation="Horizontal">
              <TextBlock Text="Inicio de Windows" FontWeight="SemiBold" Foreground="#003399" FontSize="11" VerticalAlignment="Center"/>
              <Button x:Name="btnRefreshStartup" Content="Actualizar" Margin="8,0,0,0"
                      Padding="6,1" FontSize="10" Background="#E8E8E8"
                      BorderBrush="#BBBBBB" BorderThickness="1" Cursor="Hand"/>
            </StackPanel>
          </GroupBox.Header>
          <StackPanel>
            <StackPanel Orientation="Horizontal" Margin="0,0,0,4">
              <Rectangle Width="10" Height="10" Fill="#22AA44" Margin="0,0,4,0" VerticalAlignment="Center"/>
              <TextBlock Text="Activo" FontSize="10" Foreground="#555" Margin="0,0,10,0"/>
              <Rectangle Width="10" Height="10" Fill="#AAAAAA" Margin="0,0,4,0" VerticalAlignment="Center"/>
              <TextBlock Text="Inactivo" FontSize="10" Foreground="#555" Margin="0,0,10,0"/>
              <Rectangle Width="10" Height="10" Fill="#E67E22" Margin="0,0,4,0" VerticalAlignment="Center"/>
              <TextBlock Text="No esencial" FontSize="10" Foreground="#555" Margin="0,0,10,0"/>
              <Rectangle Width="10" Height="10" Fill="#CC2200" Margin="0,0,4,0" VerticalAlignment="Center"/>
              <TextBlock Text="Revisar" FontSize="10" Foreground="#555"/>
            </StackPanel>
            <ScrollViewer MaxHeight="180" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
              <StackPanel x:Name="startupList"/>
            </ScrollViewer>
            <TextBlock x:Name="lblStartupInfo" Text="Cargando..." FontSize="10" Foreground="#888" Margin="0,4,0,0"/>
          </StackPanel>
        </GroupBox>

        <!-- REGISTRO -->
        <GroupBox Margin="0,0,0,2" Padding="4,2,4,4" BorderBrush="#AAAACC" Background="White">
          <GroupBox.Header><TextBlock Text="Registro de acciones" FontWeight="SemiBold" Foreground="#003399" FontSize="11"/></GroupBox.Header>
          <TextBox x:Name="txtLog" Height="52" IsReadOnly="True"
                   FontFamily="Consolas" FontSize="10" Background="White" BorderThickness="0"
                   VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled"
                   TextWrapping="Wrap" Foreground="#333" Padding="2"/>
        </GroupBox>

      </StackPanel>
    </ScrollViewer>
  </DockPanel>
</Window>
"@

# ============================================================
#  CARGAR XAML
# ============================================================
$reader = [System.Xml.XmlNodeReader]::new($xaml)
$window = [System.Windows.Markup.XamlReader]::Load($reader)
function Get-C($n) { try { $window.FindName($n) } catch { $null } }
function On($ctrl, $evt, $sb) { if ($null -ne $ctrl) { try { $ctrl."Add_$evt"($sb) } catch {} } }

# Referencias
$lblRamPct=$null; $lblRamFree=$null; $lblRamTotal=$null; $barRam=$null
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
$procN = @(Get-C "p0n",Get-C "p1n",Get-C "p2n",Get-C "p3n",Get-C "p4n")
$procM = @(Get-C "p0m",Get-C "p1m",Get-C "p2m",Get-C "p3m",Get-C "p4m")
$procP = @(Get-C "p0p",Get-C "p1p",Get-C "p2p",Get-C "p3p",Get-C "p4p")
$killB = @(Get-C "k0", Get-C "k1", Get-C "k2", Get-C "k3", Get-C "k4")
$txtLog=$null; $txtStatus=$null; $btnOptimize=$null; $btnFreeRam=$null
$txtLog           = Get-C "txtLog";         $txtStatus      = Get-C "txtStatus"
$btnOptimize      = Get-C "btnOptimize";    $btnFreeRam     = Get-C "btnFreeRam"
$miExit           = Get-C "miExit";         $miAlwaysTop    = Get-C "miAlwaysTop"
$miRefresh        = Get-C "miRefresh";      $miOptimize     = Get-C "miOptimize"
$miFreeRam        = Get-C "miFreeRam";      $miCleanTemp    = Get-C "miCleanTemp"
$miPowerPlan      = Get-C "miPowerPlan";    $miAbout        = Get-C "miAbout"
$miGithub         = Get-C "miGithub";       $miMinTray      = Get-C "miMinTray"
$miAutoOff        = Get-C "miAutoOff";      $miAuto5        = Get-C "miAuto5"
$miAuto15         = Get-C "miAuto15";       $miAuto30       = Get-C "miAuto30"
$startupList      = Get-C "startupList";    $btnRefreshStartup = Get-C "btnRefreshStartup"
$lblStartupInfo   = Get-C "lblStartupInfo"

# ============================================================
#  UTILIDADES
# ============================================================
function Fmt([long]$b) {
    if ($b -ge 1GB) { return "{0:F1} GB" -f ($b/1GB) }
    if ($b -ge 1MB) { return "{0:F0} MB" -f ($b/1MB) }
    if ($b -gt 0)   { return "{0} KB"    -f [int]($b/1KB) }
    return "0 B"
}
function FmtMB([long]$m) { if ($m -ge 1024) { return "{0:F1} GB" -f ($m/1024.0) }; return "$m MB" }
function FmtNet([long]$b) {
    if ($b -ge 1MB) { return "{0:F1} MB/s" -f ($b/1MB) }
    if ($b -ge 1KB) { return "{0:F0} KB/s" -f ($b/1KB) }
    return "$b B/s"
}
function SafeLog($msg) {
    try { $t=(Get-Date).ToString("HH:mm:ss"); $txtLog.AppendText("[$t] $msg`r`n"); $txtLog.ScrollToEnd() } catch {}
}
function SafeStatus($msg) { try { if ($txtStatus) { $txtStatus.Text = $msg } } catch {} }
function SafeText($ctrl,$val) { try { if ($ctrl) { $ctrl.Text=[string]$val } } catch {} }
function SafeBar($ctrl,$val)  { try { if ($ctrl) { $ctrl.Value=[Math]::Max(0,[Math]::Min(100,[int]$val)) } } catch {} }

# ============================================================
#  INICIO DE WINDOWS — MOTOR
# ============================================================

# Categorias de recomendacion
$script:knownSystem = @(
    'SecurityHealth','SecurityHealthSystray','Windows Security','MicrosoftEdgeAutoLaunch',
    'ctfmon','InputPersonalization','BingSvc','OneDriveSetup','WinDefend'
)
$script:knownNonEssential = @(
    'OneDrive','Teams','MicrosoftTeams','Discord','Spotify','Steam','EpicGamesLauncher',
    'AdobeGCInvoker','AdobeUpdater','Skype','Zoom','Slack','iTunesHelper','QuickTime',
    'iCloudServices','Dropbox','GoogleDriveFS','Box','WhatsApp','Telegram',
    'CCleanerBrowser','Avast','AVG','McAfee','Norton','Cortana','XboxApp',
    'SteamBootStrapper','uTorrent','qBittorrent','Brave','Chrome','Firefox'
)
$script:knownRevisar = @(
    'Realtek','NVIDIA','AMD','Intel','AsusOptimizationStartupTask','MSIAfterburner',
    'RazerCentralService','SteelSeriesGG','LogiOptions'
)

function Get-StartupRec($name) {
    $n = $name.ToLower()
    foreach ($k in $script:knownSystem)       { if ($n -like "*$($k.ToLower())*") { return @{Text='Sistema';   Color='#555555'} } }
    foreach ($k in $script:knownNonEssential) { if ($n -like "*$($k.ToLower())*") { return @{Text='No esencial'; Color='#E67E22'} } }
    foreach ($k in $script:knownRevisar)      { if ($n -like "*$($k.ToLower())*") { return @{Text='Revisar';   Color='#CC2200'} } }
    return @{Text='Desconocido'; Color='#888888'}
}

function Get-StartupEnabled($source, $name) {
    try {
        $approvedPath = if ($source -eq 'HKCU') {
            'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
        } else {
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
        }
        if (Test-Path $approvedPath) {
            $val = Get-ItemPropertyValue -Path $approvedPath -Name $name -EA Stop
            if ($val -and $val.Length -ge 1) {
                return ($val[0] -eq 2)
            }
        }
    } catch {}
    return $true  # si no hay entrada en StartupApproved, esta activo
}

function Set-StartupEnabled($source, $name, $enabled) {
    try {
        $approvedPath = if ($source -eq 'HKCU') {
            'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
        } else {
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
        }
        if (-not (Test-Path $approvedPath)) {
            New-Item -Path $approvedPath -Force -EA Stop | Out-Null
        }
        $bytes = if ($enabled) {
            [byte[]](2,0,0,0,0,0,0,0,0,0,0,0)
        } else {
            [byte[]](3,0,0,0,0,0,0,0,0,0,0,0)
        }
        Set-ItemProperty -Path $approvedPath -Name $name -Value $bytes -Type Binary -EA Stop
        return $true
    } catch { return $false }
}

function Get-AllStartupItems {
    $items = New-Object System.Collections.Generic.List[hashtable]
    $regPaths = @(
        @{ Path='HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'; Source='HKCU' }
        @{ Path='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'; Source='HKLM' }
    )
    foreach ($rp in $regPaths) {
        try {
            if (-not (Test-Path $rp.Path)) { continue }
            $props = Get-ItemProperty -Path $rp.Path -EA Stop
            $props.PSObject.Properties |
                Where-Object { $_.Name -notlike 'PS*' } |
                ForEach-Object {
                    $enabled = Get-StartupEnabled $rp.Source $_.Name
                    $rec     = Get-StartupRec $_.Name
                    $cmd     = [string]$_.Value
                    $short   = if ($cmd.Length -gt 50) { $cmd.Substring(0,47) + '...' } else { $cmd }
                    $items.Add(@{
                        Name    = [string]$_.Name
                        Command = $short
                        Source  = [string]$rp.Source
                        Enabled = [bool]$enabled
                        RecText = [string]$rec.Text
                        RecColor= [string]$rec.Color
                    })
                }
        } catch {}
    }
    return $items.ToArray()
}

function Refresh-StartupUI {
    try {
        if (-not $startupList) { return }
        $startupList.Children.Clear()
        SafeText $lblStartupInfo "Cargando entradas de inicio..."
        $items = Get-AllStartupItems
        if (-not $items -or $items.Count -eq 0) {
            SafeText $lblStartupInfo "No se encontraron entradas de inicio."
            return
        }
        $enabledCount = ($items | Where-Object { $_.Enabled }).Count
        SafeText $lblStartupInfo "$($items.Count) entradas encontradas | $enabledCount activas | $($items.Count - $enabledCount) inactivas"

        foreach ($item in $items) {
            $itemCopy = $item  # closure-safe copy

            # Fila contenedora
            $border = New-Object System.Windows.Controls.Border
            $border.BorderThickness = [System.Windows.Thickness](0,0,0,1)
            $border.BorderBrush = [System.Windows.Media.SolidColorBrush]([System.Windows.Media.Color]::FromRgb(0xEE,0xEE,0xEE))
            $border.Padding = [System.Windows.Thickness](2,3,2,3)

            $grid = New-Object System.Windows.Controls.Grid
            $c1 = New-Object System.Windows.Controls.ColumnDefinition; $c1.Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
            $c2 = New-Object System.Windows.Controls.ColumnDefinition; $c2.Width = [System.Windows.GridLength]::new(68)
            $c3 = New-Object System.Windows.Controls.ColumnDefinition; $c3.Width = [System.Windows.GridLength]::new(58)
            $grid.ColumnDefinitions.Add($c1); $grid.ColumnDefinitions.Add($c2); $grid.ColumnDefinitions.Add($c3)
            $r1 = New-Object System.Windows.Controls.RowDefinition; $r1.Height = [System.Windows.GridLength]::new(18)
            $r2 = New-Object System.Windows.Controls.RowDefinition; $r2.Height = [System.Windows.GridLength]::new(15)
            $grid.RowDefinitions.Add($r1); $grid.RowDefinitions.Add($r2)

            # Nombre
            $tbName = New-Object System.Windows.Controls.TextBlock
            $tbName.Text = $itemCopy['Name']
            $tbName.FontWeight = [System.Windows.FontWeights]::SemiBold
            $tbName.FontSize = 11
            $tbName.Foreground = [System.Windows.Media.SolidColorBrush]([System.Windows.Media.Color]::FromRgb(0x22,0x22,0x22))
            $tbName.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis
            $tbName.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
            [System.Windows.Controls.Grid]::SetRow($tbName,0); [System.Windows.Controls.Grid]::SetColumn($tbName,0)
            $grid.Children.Add($tbName) | Out-Null

            # Comando
            $tbCmd = New-Object System.Windows.Controls.TextBlock
            $tbCmd.Text = $itemCopy['Command']
            $tbCmd.FontSize = 9
            $tbCmd.Foreground = [System.Windows.Media.SolidColorBrush]([System.Windows.Media.Color]::FromRgb(0x88,0x88,0x88))
            $tbCmd.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis
            $tbCmd.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
            [System.Windows.Controls.Grid]::SetRow($tbCmd,1); [System.Windows.Controls.Grid]::SetColumn($tbCmd,0)
            $grid.Children.Add($tbCmd) | Out-Null

            # Recomendacion
            $tbRec = New-Object System.Windows.Controls.TextBlock
            $tbRec.Text = $itemCopy['RecText']
            $tbRec.FontSize = 9
            $recColor = [System.Windows.Media.ColorConverter]::ConvertFromString($itemCopy['RecColor'])
            $tbRec.Foreground = [System.Windows.Media.SolidColorBrush]($recColor)
            $tbRec.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
            $tbRec.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
            [System.Windows.Controls.Grid]::SetRow($tbRec,0); [System.Windows.Controls.Grid]::SetRowSpan($tbRec,2)
            [System.Windows.Controls.Grid]::SetColumn($tbRec,1)
            $grid.Children.Add($tbRec) | Out-Null

            # Boton toggle
            $btnToggle = New-Object System.Windows.Controls.Button
            $btnToggle.Content = if ($itemCopy['Enabled']) { "Desactivar" } else { "Activar" }
            $btnToggle.FontSize = 9
            $btnToggle.Padding = [System.Windows.Thickness](3,2,3,2)
            $btnToggle.Margin  = [System.Windows.Thickness](3,1,0,1)
            $btnToggle.Cursor  = [System.Windows.Input.Cursors]::Hand
            $btnToggle.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
            if ($itemCopy['Enabled']) {
                $btnToggle.Background   = [System.Windows.Media.SolidColorBrush]([System.Windows.Media.Color]::FromRgb(0xFF,0xEE,0xEE))
                $btnToggle.Foreground   = [System.Windows.Media.SolidColorBrush]([System.Windows.Media.Color]::FromRgb(0xAA,0x00,0x00))
                $btnToggle.BorderBrush  = [System.Windows.Media.SolidColorBrush]([System.Windows.Media.Color]::FromRgb(0xCC,0x44,0x44))
            } else {
                $btnToggle.Background   = [System.Windows.Media.SolidColorBrush]([System.Windows.Media.Color]::FromRgb(0xEE,0xFF,0xEE))
                $btnToggle.Foreground   = [System.Windows.Media.SolidColorBrush]([System.Windows.Media.Color]::FromRgb(0x00,0x88,0x22))
                $btnToggle.BorderBrush  = [System.Windows.Media.SolidColorBrush]([System.Windows.Media.Color]::FromRgb(0x44,0xCC,0x44))
            }
            $btnToggle.BorderThickness = [System.Windows.Thickness](1)
            [System.Windows.Controls.Grid]::SetRow($btnToggle,0); [System.Windows.Controls.Grid]::SetRowSpan($btnToggle,2)
            [System.Windows.Controls.Grid]::SetColumn($btnToggle,2)
            $grid.Children.Add($btnToggle) | Out-Null

            # Indicador de color segun estado
            $border.Background = if ($itemCopy['Enabled']) {
                [System.Windows.Media.SolidColorBrush]([System.Windows.Media.Color]::FromArgb(0xFF,0xFF,0xFF,0xFF))
            } else {
                [System.Windows.Media.SolidColorBrush]([System.Windows.Media.Color]::FromArgb(0xFF,0xF8,0xF8,0xF8))
            }

            # Handler del toggle — closure sobre $itemCopy
            $btnToggle.Add_Click({
                try {
                    $newState = -not $itemCopy['Enabled']
                    if (Set-StartupEnabled $itemCopy['Source'] $itemCopy['Name'] $newState) {
                        $action = if ($newState) { "activado" } else { "desactivado" }
                        $iName = $itemCopy['Name']
                        SafeLog "Inicio $action`: $iName"
                        SafeStatus "Inicio de $iName $action. Reinicia para ver el efecto."
                        Refresh-StartupUI
                    } else {
                        SafeLog "Sin permisos para modificar: $($itemCopy['Name']) (prueba como administrador)"
                    }
                } catch {}
            }.GetNewClosure())

            $border.Child = $grid
            $startupList.Children.Add($border) | Out-Null
        }
    } catch { SafeText $lblStartupInfo "Error al leer entradas de inicio." }
}

# ============================================================
#  GRAFICO
# ============================================================
function Update-Graph {
    try {
        if (-not $graphCanvas -or -not $graphCpu -or -not $graphRam) { return }
        $w=$graphCanvas.ActualWidth; $h=$graphCanvas.ActualHeight
        if ($w -lt 2 -or $h -lt 2) { return }
        $cA=$script:d['CpuHistory']; $rA=$script:d['RamHistory']
        if (-not $cA -or $cA.Length -lt 2) { return }
        $n=$cA.Length; $pad=3.0
        $cP=New-Object System.Windows.Media.PointCollection
        $rP=New-Object System.Windows.Media.PointCollection
        for ($i=0;$i -lt $n;$i++) {
            $x=[double]$i/($n-1)*$w
            $cP.Add([System.Windows.Point]::new($x,$h-$pad-[double]$cA[$i]/100*($h-2*$pad)))
            $rP.Add([System.Windows.Point]::new($x,$h-$pad-[double]$rA[$i]/100*($h-2*$pad)))
        }
        $graphCpu.Points=$cP; $graphRam.Points=$rP
    } catch {}
}

# ============================================================
#  ACTUALIZAR UI
# ============================================================
function Update-UI {
    try {
        $fm=$script:d['FreeMB']; $tm=$script:d['TotalMB']; $um=$tm-$fm
        $rp=if($tm -gt 0){[int]($um*100/$tm)}else{0}
        SafeText $lblRamPct  ("$rp%  /  "+(FmtMB $um))
        SafeText $lblRamFree  (FmtMB $fm); SafeText $lblRamTotal (FmtMB $tm); SafeBar $barRam $rp
    } catch {}
    try {
        $vp=$script:d['VirtPct']
        SafeText $lblVirtPct   ("$vp%  /  "+(FmtMB $script:d['VirtUsedMB']))
        SafeText $lblVirtFree  (FmtMB $script:d['VirtFreeMB'])
        SafeText $lblVirtTotal (FmtMB $script:d['VirtTotalMB']); SafeBar $barVirt $vp
    } catch {}
    try {
        $cm=$script:d['CacheMB']; $tm2=$script:d['TotalMB']
        SafeText $lblCacheMB (FmtMB $cm)
        SafeBar $barCache (if($tm2 -gt 0){[int]($cm*100/$tm2)}else{0})
    } catch {}
    try {
        $cpu=$script:d['CpuPct']; $ct=$script:d['CpuTempC']
        SafeText $lblCpuPct  "$cpu%"; SafeText $lblCpuName $script:d['CpuName']
        SafeText $lblCpuTemp (if($ct -gt 0){"$ct C"}else{"No disponible"}); SafeBar $barCpu $cpu
    } catch {}
    try {
        $df=$script:d['DiskFree']; $dt=$script:d['DiskTotal']; $du=$dt-$df
        SafeText $lblDiskFree  (Fmt $df); SafeText $lblDiskUsed  (Fmt $du)
        SafeText $lblDiskTotal (Fmt $dt)
        SafeBar $barDisk (if($dt -gt 0){[int]($du*100/$dt)}else{0})
    } catch {}
    try { SafeText $lblNetRx (FmtNet $script:d['NetRxBps']); SafeText $lblNetTx (FmtNet $script:d['NetTxBps']) } catch {}
    try {
        $ns=$script:d['TopProcNames']; $ms=$script:d['TopProcMBs']; $ps2=$script:d['TopProcPIDs']
        for ($i=0;$i -lt 5;$i++) {
            $nm=if($ns -and $i -lt $ns.Length){[string]$ns[$i]}else{''}
            $mb=if($ms -and $i -lt $ms.Length){[int]$ms[$i]}else{0}
            $pd=if($ps2 -and $i -lt $ps2.Length){[int]$ps2[$i]}else{0}
            SafeText $procN[$i] $nm
            SafeText $procM[$i] (if($nm -ne ''){"$mb MB"}else{''})
            SafeText $procP[$i] (if($nm -ne ''){"PID $pd"}else{''})
            if ($killB[$i]) {
                $killB[$i].Tag=$pd
                $killB[$i].Visibility=if($nm -ne ''){[System.Windows.Visibility]::Visible}else{[System.Windows.Visibility]::Collapsed}
            }
        }
    } catch {}
    Update-Graph
    try {
        $c=$script:d['CpuPct']; $t=$script:d['TotalMB']; $f=$script:d['FreeMB']
        $r=if($t -gt 0){[int](($t-$f)*100/$t)}else{0}
        $ts=(Get-Date).ToString('HH:mm:ss'); $df2=Fmt $script:d['DiskFree']
        SafeStatus "Act. $ts   CPU: $c%   RAM: $r%   Disco: $df2 libre"
    } catch {}
    try {
        if ($script:trayIcon) {
            $tip="WinOptimizer | CPU: $($script:d['CpuPct'])%"
            $script:trayIcon.Text=$tip.Substring(0,[Math]::Min($tip.Length,127))
        }
    } catch {}
}

# ============================================================
#  ACCIONES
# ============================================================
function Free-RAM {
    try {
        SafeStatus "Liberando RAM..."
        $b=$script:d['FreeMB']
        [System.GC]::Collect(2,[System.GCCollectionMode]::Forced); [System.GC]::WaitForPendingFinalizers(); [System.GC]::Collect()
        $sk=@('System','smss','csrss','wininit','winlogon','lsass','services','svchost','Registry','MsMpEng','dwm','fontdrvhost','Idle')
        $n=0
        Get-Process -EA SilentlyContinue | Where-Object { $_.WorkingSet64 -gt 10MB -and $sk -notcontains $_.ProcessName } |
            Sort-Object WorkingSet64 -Descending | Select-Object -First 40 |
            ForEach-Object { try{$_.MinWorkingSet=[IntPtr]1;$_.MaxWorkingSet=[IntPtr]1;$n++}catch{} }
        Start-Sleep -Milliseconds 600
        $freed=($script:d['FreeMB']-$b)*1MB; if($freed -lt 0){$freed=0}
        $msg=if($freed -gt 1MB){"RAM liberada: $(Fmt $freed) ($n procesos)"}else{"RAM optimizada ($n procesos)"}
        SafeLog $msg; SafeStatus "Listo - $msg"
    } catch { SafeStatus "Error al liberar RAM" }
}
function Clean-Temp {
    try {
        SafeStatus "Limpiando temporales..."
        $total=0L; $files=0; $errs=0
        foreach ($p in @($env:TEMP,"$env:SystemRoot\Temp")) {
            if (-not (Test-Path $p)) { continue }
            Get-ChildItem $p -Recurse -Force -EA SilentlyContinue | Where-Object {-not $_.PSIsContainer} |
                ForEach-Object { try{$total+=$_.Length;Remove-Item $_.FullName -Force -EA Stop;$files++}catch{$errs++} }
        }
        $extra=if($errs -gt 0){", $errs en uso"}else{""}
        $msg="Temporales: $(Fmt $total) ($files archivos$extra)"
        SafeLog $msg; SafeStatus "Listo - $msg"
    } catch { SafeStatus "Error al limpiar" }
}
function Quick-Optimize {
    try {
        SafeLog "=== Optimizacion rapida ==="; SafeStatus "Optimizando..."
        [System.GC]::Collect(2,[System.GCCollectionMode]::Forced); [System.GC]::WaitForPendingFinalizers()
        $total=0L; $files=0
        foreach ($p in @($env:TEMP,"$env:SystemRoot\Temp")) {
            if (-not (Test-Path $p)) { continue }
            Get-ChildItem $p -Recurse -Force -EA SilentlyContinue | Where-Object {-not $_.PSIsContainer} |
                ForEach-Object {try{$total+=$_.Length;Remove-Item $_.FullName -Force -EA Stop;$files++}catch{}}
        }
        $sk=@('System','smss','csrss','wininit','winlogon','lsass','services','svchost','Registry','MsMpEng','dwm','fontdrvhost','Idle')
        $n=0
        Get-Process -EA SilentlyContinue | Where-Object { $_.WorkingSet64 -gt 10MB -and $sk -notcontains $_.ProcessName } |
            Sort-Object WorkingSet64 -Descending | Select-Object -First 40 |
            ForEach-Object {try{$_.MinWorkingSet=[IntPtr]1;$_.MaxWorkingSet=[IntPtr]1;$n++}catch{}}
        SafeLog ("Temporales: "+(Fmt $total)+" ($files archivos)"); SafeLog "RAM: $n procesos ajustados"
        SafeLog "=== Completado ==="; SafeStatus ("Listo - "+(Fmt $total)+" + $n procesos")
    } catch { SafeStatus "Error en optimizacion" }
}
function Kill-Proc($pid2,$name) {
    try {
        $r=[System.Windows.MessageBox]::Show("Terminar '$name' (PID $pid2)?`n`nPuede causar perdida de datos no guardados.",
            "Confirmar",[System.Windows.MessageBoxButton]::YesNo,[System.Windows.MessageBoxImage]::Warning)
        if ($r -eq [System.Windows.MessageBoxResult]::Yes) {
            Stop-Process -Id $pid2 -Force -EA Stop
            SafeLog "Proceso terminado: $name (PID $pid2)"; SafeStatus "Proceso $name terminado"
        }
    } catch { SafeLog "No se pudo terminar $name (PID $pid2)" }
}

# ============================================================
#  AUTO-OPTIMIZACION
# ============================================================
$script:autoTimer=$null
$script:autoItems=@($miAutoOff,$miAuto5,$miAuto15,$miAuto30)
function Set-AutoOptimize($min) {
    if ($script:autoTimer) { try{$script:autoTimer.Stop()}catch{}; $script:autoTimer=$null }
    foreach ($mi in $script:autoItems) { try{if($mi){$mi.IsChecked=$false}}catch{} }
    switch($min) {
        0  { try{if($miAutoOff){$miAutoOff.IsChecked=$true}}catch{}; SafeLog "Auto-opt desactivada" }
        5  { try{if($miAuto5) {$miAuto5.IsChecked =$true}}catch{} }
        15 { try{if($miAuto15){$miAuto15.IsChecked =$true}}catch{} }
        30 { try{if($miAuto30){$miAuto30.IsChecked =$true}}catch{} }
    }
    if ($min -gt 0) {
        $script:autoTimer=[System.Windows.Threading.DispatcherTimer]::new()
        $script:autoTimer.Interval=[TimeSpan]::FromMinutes($min)
        $script:autoTimer.Add_Tick({Quick-Optimize}); $script:autoTimer.Start()
        SafeLog "Auto-opt cada $min min activada"
    }
}

# ============================================================
#  BANDEJA
# ============================================================
function Init-Tray {
    try {
        $script:trayIcon=New-Object System.Windows.Forms.NotifyIcon
        $icoPath=Join-Path $script:AppDir "icon.ico"
        if (Test-Path $icoPath) {
            try{$script:trayIcon.Icon=New-Object System.Drawing.Icon($icoPath)}catch{$script:trayIcon.Icon=[System.Drawing.SystemIcons]::Application}
        } else {
            try {
                $ef=[System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
                if($ef -and (Test-Path $ef)){$script:trayIcon.Icon=[System.Drawing.Icon]::ExtractAssociatedIcon($ef)}
                else{$script:trayIcon.Icon=[System.Drawing.SystemIcons]::Application}
            } catch{$script:trayIcon.Icon=[System.Drawing.SystemIcons]::Application}
        }
        $script:trayIcon.Visible=$true; $script:trayIcon.Text="WinOptimizer"
        $ctx=New-Object System.Windows.Forms.ContextMenuStrip
        $iO=$ctx.Items.Add("Abrir WinOptimizer"); $iR=$ctx.Items.Add("Optimizar sistema")
        $iF=$ctx.Items.Add("Liberar RAM"); $null=$ctx.Items.Add("-"); $iE=$ctx.Items.Add("Salir")
        $iO.Add_Click({$window.Show();$window.WindowState=[System.Windows.WindowState]::Normal;$window.Activate()})
        $iR.Add_Click({Quick-Optimize}); $iF.Add_Click({Free-RAM})
        $iE.Add_Click({
            $script:forceClose=$true
            try{$script:trayIcon.Visible=$false;$script:trayIcon.Dispose()}catch{}
            try{$script:timer.Stop()}catch{}
            try{if($script:autoTimer){$script:autoTimer.Stop()}}catch{}
            try{$script:bgPS.Stop()}catch{}; try{$script:bgRS.Close()}catch{}
            $window.Close()
        })
        $script:trayIcon.ContextMenuStrip=$ctx
        $script:trayIcon.Add_DoubleClick({$window.Show();$window.WindowState=[System.Windows.WindowState]::Normal;$window.Activate()})
    } catch {}
}

# ============================================================
#  EVENTOS
# ============================================================
$script:forceClose=$false
On $btnOptimize      Click { Quick-Optimize }; On $btnFreeRam   Click { Free-RAM    }
On $miOptimize       Click { Quick-Optimize }; On $miFreeRam    Click { Free-RAM    }
On $miCleanTemp      Click { Clean-Temp     }; On $miRefresh    Click { Update-UI   }
On $btnRefreshStartup Click { Refresh-StartupUI }
On $miAutoOff  Click { Set-AutoOptimize 0  }; On $miAuto5  Click { Set-AutoOptimize 5  }
On $miAuto15   Click { Set-AutoOptimize 15 }; On $miAuto30 Click { Set-AutoOptimize 30 }
On $miMinTray  Click {
    $window.Hide()
    try{$script:trayIcon.ShowBalloonTip(2000,"WinOptimizer","Minimizado. Doble clic para restaurar.",[System.Windows.Forms.ToolTipIcon]::Info)}catch{}
}
On $miAlwaysTop Checked   { $window.Topmost=$true  }
On $miAlwaysTop Unchecked { $window.Topmost=$false }
On $miPowerPlan Click { try{Start-Process "powercfg.cpl"}catch{} }
On $miGithub    Click { try{Start-Process "https://github.com/EnMaNueL-G/WinOptimizer"}catch{} }
On $miAbout     Click {
    $msg="WinOptimizer v2.3.0`r`n"
    $msg+="Optimizador para Windows 10/11`r`n`r`n"
    $msg+="  RAM fisica, virtual, cache, CPU, Disco, Red`r`n"
    $msg+="  Top 5 procesos con Kill`r`n"
    $msg+="  Inicio de Windows integrado (activar/desactivar)`r`n"
    $msg+="  Historial grafico 2 min, Bandeja, Auto-opt`r`n`r`n"
    $msg+="Desarrollado por Enmanuel Gil`r`n"
    $msg+="github.com/EnMaNueL-G - MIT License"
    [System.Windows.MessageBox]::Show($msg,"Acerca de",[System.Windows.MessageBoxButton]::OK,[System.Windows.MessageBoxImage]::Information)
}
On $miExit Click {
    $script:forceClose=$true
    try{$script:trayIcon.Visible=$false;$script:trayIcon.Dispose()}catch{}
    try{$script:timer.Stop()}catch{}
    try{if($script:autoTimer){$script:autoTimer.Stop()}}catch{}
    try{$script:bgPS.Stop()}catch{}; try{$script:bgRS.Close()}catch{}
    $window.Close()
}
for ($ki=0;$ki -lt 5;$ki++) {
    $idx=$ki
    if ($killB[$idx]) {
        $killB[$idx].Add_Click({
            try {
                $pd=[int]$killB[$idx].Tag; $nm=[string]$procN[$idx].Text
                if ($pd -gt 0 -and $nm -ne '') { Kill-Proc $pd $nm }
            } catch {}
        }.GetNewClosure())
    }
}

# ============================================================
#  TIMER + ARRANQUE + CIERRE
# ============================================================
$script:timer=[System.Windows.Threading.DispatcherTimer]::new()
$script:timer.Interval=[TimeSpan]::FromSeconds(2)
$script:timer.Add_Tick({Update-UI})
if ($graphCanvas) { $graphCanvas.Add_SizeChanged({try{Update-Graph}catch{}}) }

$window.Add_Loaded({
    try{Init-Tray}catch{}
    Start-Worker
    $script:timer.Start()
    SafeLog "WinOptimizer v2.3.0 iniciado"
    SafeStatus "Cargando datos del sistema..."
    # Cargar startup con un breve delay para no bloquear el Loaded
    $stTimer=[System.Windows.Threading.DispatcherTimer]::new()
    $stTimer.Interval=[TimeSpan]::FromSeconds(1)
    $stTimer.Add_Tick({ try{Refresh-StartupUI}catch{}; $stTimer.Stop() })
    $stTimer.Start()
})
$window.Add_Closing({
    if (-not $script:forceClose) {
        $_.Cancel=$true; $window.Hide()
        try{$script:trayIcon.ShowBalloonTip(2000,"WinOptimizer","Sigue activo en la bandeja.",[System.Windows.Forms.ToolTipIcon]::Info)}catch{}
    }
})
$window.Add_Closed({
    try{$script:timer.Stop()}catch{}
    try{if($script:autoTimer){$script:autoTimer.Stop()}}catch{}
    try{$script:trayIcon.Dispose()}catch{}
    try{$script:bgPS.Stop()}catch{}; try{$script:bgRS.Close()}catch{}
})
$window.Add_KeyDown({ if($_.Key -eq [System.Windows.Input.Key]::F5){Update-UI} })

$window.ShowDialog() | Out-Null
