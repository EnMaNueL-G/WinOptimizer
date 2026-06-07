#Requires -Version 5.1
<#
.SYNOPSIS
    WinOptimizer v1.0.0 — Optimizador de rendimiento para Windows 10/11
    Desarrollado por Enmanuel Gil | github.com/EnMaNueL-G
#>

Set-StrictMode -Off
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

# ── XAML simplificado — sin ControlTemplate (carga rapida) ─────────────────────
[xml]$xaml = @"
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="WinOptimizer - Enmanuel Gil"
    Width="900" Height="640"
    MinWidth="780" MinHeight="560"
    WindowStartupLocation="CenterScreen"
    Background="#0C0C0C"
    FontFamily="Segoe UI">

    <Grid>
        <Grid.RowDefinitions>
            <RowDefinition Height="52"/>
            <RowDefinition Height="42"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="32"/>
        </Grid.RowDefinitions>

        <!-- HEADER -->
        <Border Grid.Row="0" Background="#111111">
            <Grid Margin="18,0">
                <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                    <Border Width="30" Height="30" CornerRadius="6" Background="#FF8C00" Margin="0,0,10,0">
                        <TextBlock Text="W" FontSize="17" FontWeight="Black"
                                   Foreground="#111111" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                    </Border>
                    <TextBlock Text="WinOptimizer" FontSize="16" FontWeight="Bold"
                               Foreground="#F0F0F0" VerticalAlignment="Center"/>
                    <TextBlock Text=" by Enmanuel Gil" FontSize="11" Foreground="#666666"
                               VerticalAlignment="Center"/>
                </StackPanel>
                <TextBlock x:Name="txtSysInfo" Text="Cargando..." FontSize="12"
                           Foreground="#888888" VerticalAlignment="Center"
                           HorizontalAlignment="Right"/>
            </Grid>
        </Border>

        <!-- TABS BAR -->
        <Border Grid.Row="1" Background="#0F0F0F">
            <StackPanel Orientation="Horizontal" VerticalAlignment="Center" Margin="10,0">
                <Button x:Name="tabDash"    Content="Dashboard"          Margin="2,0"
                        Background="#FF8C00" Foreground="#111111" FontWeight="Bold"
                        BorderThickness="0" Padding="16,6" FontSize="12" Cursor="Hand"/>
                <Button x:Name="tabRam"     Content="Memoria RAM"        Margin="2,0"
                        Background="Transparent" Foreground="#888888"
                        BorderThickness="0" Padding="16,6" FontSize="12" Cursor="Hand"/>
                <Button x:Name="tabTemp"    Content="Archivos Temp"      Margin="2,0"
                        Background="Transparent" Foreground="#888888"
                        BorderThickness="0" Padding="16,6" FontSize="12" Cursor="Hand"/>
                <Button x:Name="tabStartup" Content="Inicio de Windows"  Margin="2,0"
                        Background="Transparent" Foreground="#888888"
                        BorderThickness="0" Padding="16,6" FontSize="12" Cursor="Hand"/>
                <Button x:Name="tabPower"   Content="Plan de Energia"    Margin="2,0"
                        Background="Transparent" Foreground="#888888"
                        BorderThickness="0" Padding="16,6" FontSize="12" Cursor="Hand"/>
            </StackPanel>
        </Border>

        <!-- CONTENT PANELS -->
        <Grid Grid.Row="2">

            <!-- ── PANEL DASHBOARD ──────────────────────────────────────────── -->
            <ScrollViewer x:Name="panDash" VerticalScrollBarVisibility="Auto" Padding="18">
                <StackPanel>
                    <TextBlock Text="Estado del sistema" FontSize="18" FontWeight="SemiBold"
                               Foreground="#F0F0F0" Margin="0,0,0,14"/>
                    <Grid Margin="0,0,0,14">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="8"/>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="8"/>
                            <ColumnDefinition Width="*"/>
                        </Grid.ColumnDefinitions>
                        <!-- CPU -->
                        <Border Grid.Column="0" Background="#161616" CornerRadius="10"
                                BorderBrush="#2A2A2A" BorderThickness="1" Padding="16">
                            <StackPanel>
                                <TextBlock Text="CPU" Foreground="#888888" FontSize="11"/>
                                <TextBlock x:Name="txtCpu" Text="--%" FontSize="30"
                                           FontWeight="Bold" Foreground="#FF8C00" Margin="0,4,0,0"/>
                                <TextBlock x:Name="txtCpuName" Text="..." FontSize="10"
                                           Foreground="#555555" TextWrapping="Wrap"/>
                            </StackPanel>
                        </Border>
                        <!-- RAM -->
                        <Border Grid.Column="2" Background="#161616" CornerRadius="10"
                                BorderBrush="#2A2A2A" BorderThickness="1" Padding="16">
                            <StackPanel>
                                <TextBlock Text="RAM usada" Foreground="#888888" FontSize="11"/>
                                <TextBlock x:Name="txtRam" Text="-- GB" FontSize="30"
                                           FontWeight="Bold" Foreground="#FFC107" Margin="0,4,0,0"/>
                                <TextBlock x:Name="txtRamOf" Text="de -- GB"
                                           FontSize="10" Foreground="#555555"/>
                            </StackPanel>
                        </Border>
                        <!-- Disco -->
                        <Border Grid.Column="4" Background="#161616" CornerRadius="10"
                                BorderBrush="#2A2A2A" BorderThickness="1" Padding="16">
                            <StackPanel>
                                <TextBlock Text="Disco libre (C:)" Foreground="#888888" FontSize="11"/>
                                <TextBlock x:Name="txtDisk" Text="-- GB" FontSize="30"
                                           FontWeight="Bold" Foreground="#4CAF50" Margin="0,4,0,0"/>
                                <TextBlock x:Name="txtDiskOf" Text="de -- GB"
                                           FontSize="10" Foreground="#555555"/>
                            </StackPanel>
                        </Border>
                    </Grid>

                    <!-- Optimizacion rapida -->
                    <Border Background="#161616" CornerRadius="10" BorderBrush="#2A2A2A"
                            BorderThickness="1" Padding="18" Margin="0,0,0,14">
                        <Grid>
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="Auto"/>
                            </Grid.ColumnDefinitions>
                            <StackPanel Grid.Column="0">
                                <TextBlock Text="Optimizacion rapida" FontSize="15"
                                           FontWeight="SemiBold" Foreground="#F0F0F0"/>
                                <TextBlock Text="Libera RAM, elimina temporales y optimiza procesos en un click."
                                           FontSize="12" Foreground="#888888" Margin="0,5,0,0"
                                           TextWrapping="Wrap"/>
                            </StackPanel>
                            <Button x:Name="btnQuickOpt" Grid.Column="1"
                                    Content="Optimizar ahora"
                                    Background="#FF8C00" Foreground="#111111"
                                    FontWeight="Bold" FontSize="13" BorderThickness="0"
                                    Padding="22,10" Cursor="Hand"
                                    VerticalAlignment="Center" Margin="20,0,0,0"/>
                        </Grid>
                    </Border>

                    <!-- Log -->
                    <Border Background="#161616" CornerRadius="10" BorderBrush="#2A2A2A"
                            BorderThickness="1" Padding="16">
                        <StackPanel>
                            <TextBlock Text="Registro de acciones" Foreground="#888888" FontSize="11" Margin="0,0,0,8"/>
                            <ScrollViewer Height="140" VerticalScrollBarVisibility="Auto">
                                <TextBlock x:Name="txtLog" FontFamily="Consolas" FontSize="12"
                                           Foreground="#CCCCCC" TextWrapping="Wrap"
                                           Text="Listo. Presiona 'Optimizar ahora' para comenzar."/>
                            </ScrollViewer>
                        </StackPanel>
                    </Border>
                    <TextBlock Height="60"/>
                </StackPanel>
            </ScrollViewer>

            <!-- ── PANEL RAM ─────────────────────────────────────────────────── -->
            <ScrollViewer x:Name="panRam" Visibility="Collapsed"
                          VerticalScrollBarVisibility="Auto" Padding="18">
                <StackPanel>
                    <TextBlock Text="Gestion de memoria RAM" FontSize="18" FontWeight="SemiBold"
                               Foreground="#F0F0F0" Margin="0,0,0,14"/>
                    <Border Background="#161616" CornerRadius="10" BorderBrush="#2A2A2A"
                            BorderThickness="1" Padding="16" Margin="0,0,0,12">
                        <Grid>
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="*"/>
                            </Grid.ColumnDefinitions>
                            <StackPanel Grid.Column="0">
                                <TextBlock Text="RAM total" Foreground="#888888" FontSize="11"/>
                                <TextBlock x:Name="txtRamTotal" Text="--" FontSize="22"
                                           FontWeight="Bold" Foreground="#F0F0F0" Margin="0,4,0,0"/>
                            </StackPanel>
                            <StackPanel Grid.Column="1">
                                <TextBlock Text="En uso" Foreground="#888888" FontSize="11"/>
                                <TextBlock x:Name="txtRamUsed" Text="--" FontSize="22"
                                           FontWeight="Bold" Foreground="#FF8C00" Margin="0,4,0,0"/>
                            </StackPanel>
                            <StackPanel Grid.Column="2">
                                <TextBlock Text="Disponible" Foreground="#888888" FontSize="11"/>
                                <TextBlock x:Name="txtRamFree" Text="--" FontSize="22"
                                           FontWeight="Bold" Foreground="#4CAF50" Margin="0,4,0,0"/>
                            </StackPanel>
                        </Grid>
                    </Border>
                    <!-- Barra RAM -->
                    <Border Background="#161616" CornerRadius="10" BorderBrush="#2A2A2A"
                            BorderThickness="1" Padding="16" Margin="0,0,0,12">
                        <StackPanel>
                            <Grid Margin="0,0,0,8">
                                <TextBlock Text="Uso de memoria" Foreground="#888888" FontSize="11"/>
                                <TextBlock x:Name="txtRamPct" Text="0%"
                                           Foreground="#FF8C00" FontSize="11" FontWeight="Bold"
                                           HorizontalAlignment="Right"/>
                            </Grid>
                            <Border Background="#2A2A2A" CornerRadius="4" Height="10">
                                <Border x:Name="barRam" Background="#FF8C00" CornerRadius="4"
                                        HorizontalAlignment="Left" Width="0" Height="10"/>
                            </Border>
                        </StackPanel>
                    </Border>
                    <!-- Liberar RAM -->
                    <Border Background="#161616" CornerRadius="10" BorderBrush="#2A2A2A"
                            BorderThickness="1" Padding="16" Margin="0,0,0,12">
                        <StackPanel>
                            <TextBlock Text="Liberar memoria RAM" FontSize="14"
                                       FontWeight="SemiBold" Foreground="#F0F0F0" Margin="0,0,0,6"/>
                            <TextBlock Foreground="#888888" FontSize="12" TextWrapping="Wrap" Margin="0,0,0,12"
                                       Text="Reduce el Working Set de procesos para devolver RAM al sistema. Seguro y reversible."/>
                            <StackPanel Orientation="Horizontal">
                                <Button x:Name="btnFreeRam" Content="Liberar RAM ahora"
                                        Background="#FF8C00" Foreground="#111111"
                                        FontWeight="Bold" BorderThickness="0"
                                        Padding="18,8" Cursor="Hand"/>
                                <TextBlock x:Name="txtRamResult" Text="" Foreground="#4CAF50"
                                           FontSize="13" FontWeight="SemiBold"
                                           VerticalAlignment="Center" Margin="14,0,0,0"/>
                            </StackPanel>
                        </StackPanel>
                    </Border>
                    <!-- Procesos -->
                    <Border Background="#161616" CornerRadius="10" BorderBrush="#2A2A2A"
                            BorderThickness="1" Padding="16">
                        <StackPanel>
                            <Grid Margin="0,0,0,10">
                                <TextBlock Text="Procesos por uso de RAM"
                                           Foreground="#888888" FontSize="11"/>
                                <Button x:Name="btnRefreshProc" Content="Actualizar"
                                        Background="Transparent" Foreground="#FF8C00"
                                        BorderBrush="#FF8C00" BorderThickness="1"
                                        Padding="10,3" FontSize="11" Cursor="Hand"
                                        HorizontalAlignment="Right"/>
                            </Grid>
                            <ListView x:Name="lstProc" Height="180"
                                      Background="Transparent" BorderThickness="0"
                                      Foreground="#F0F0F0">
                                <ListView.View>
                                    <GridView>
                                        <GridViewColumn Header="Proceso" Width="200"
                                            DisplayMemberBinding="{Binding Name}"/>
                                        <GridViewColumn Header="RAM (MB)" Width="90"
                                            DisplayMemberBinding="{Binding RamMB}"/>
                                        <GridViewColumn Header="PID" Width="70"
                                            DisplayMemberBinding="{Binding PID}"/>
                                    </GridView>
                                </ListView.View>
                            </ListView>
                        </StackPanel>
                    </Border>
                    <TextBlock Height="60"/>
                </StackPanel>
            </ScrollViewer>

            <!-- ── PANEL TEMP ─────────────────────────────────────────────────── -->
            <ScrollViewer x:Name="panTemp" Visibility="Collapsed"
                          VerticalScrollBarVisibility="Auto" Padding="18">
                <StackPanel>
                    <TextBlock Text="Archivos temporales" FontSize="18" FontWeight="SemiBold"
                               Foreground="#F0F0F0" Margin="0,0,0,14"/>
                    <Border Background="#161616" CornerRadius="10" BorderBrush="#2A2A2A"
                            BorderThickness="1" Padding="16" Margin="0,0,0,12">
                        <StackPanel>
                            <TextBlock Text="Selecciona que limpiar" FontSize="13"
                                       FontWeight="SemiBold" Foreground="#F0F0F0" Margin="0,0,0,10"/>
                            <CheckBox x:Name="chkTemp"      IsChecked="True" Foreground="#F0F0F0"
                                      FontSize="13" Margin="0,0,0,7"
                                      Content="%TEMP% - archivos temporales del usuario"/>
                            <CheckBox x:Name="chkWinTemp"   IsChecked="True" Foreground="#F0F0F0"
                                      FontSize="13" Margin="0,0,0,7"
                                      Content="C:\Windows\Temp - temporales del sistema"/>
                            <CheckBox x:Name="chkPrefetch"  IsChecked="False" Foreground="#F0F0F0"
                                      FontSize="13" Margin="0,0,0,7"
                                      Content="C:\Windows\Prefetch (requiere admin)"/>
                            <CheckBox x:Name="chkRecycle"   IsChecked="False" Foreground="#F0F0F0"
                                      FontSize="13" Content="Papelera de reciclaje"/>
                        </StackPanel>
                    </Border>
                    <Border Background="#161616" CornerRadius="10" BorderBrush="#2A2A2A"
                            BorderThickness="1" Padding="16" Margin="0,0,0,12">
                        <StackPanel>
                            <StackPanel Orientation="Horizontal" Margin="0,0,0,10">
                                <Button x:Name="btnScanTemp" Content="Analizar"
                                        Background="Transparent" Foreground="#FF8C00"
                                        BorderBrush="#FF8C00" BorderThickness="1"
                                        Padding="14,7" Cursor="Hand" Margin="0,0,10,0"/>
                                <Button x:Name="btnCleanTemp" Content="Limpiar seleccionados"
                                        Background="#FF8C00" Foreground="#111111"
                                        FontWeight="Bold" BorderThickness="0"
                                        Padding="14,7" Cursor="Hand" IsEnabled="False"/>
                            </StackPanel>
                            <TextBlock x:Name="txtTempResult"
                                       Text="Presiona Analizar para ver el espacio recuperable."
                                       Foreground="#888888" FontSize="13" TextWrapping="Wrap"/>
                        </StackPanel>
                    </Border>
                    <Border x:Name="borderTempDetail" Background="#161616" CornerRadius="10"
                            BorderBrush="#2A2A2A" BorderThickness="1" Padding="16"
                            Visibility="Collapsed">
                        <StackPanel>
                            <TextBlock Text="Desglose" FontSize="12" FontWeight="SemiBold"
                                       Foreground="#F0F0F0" Margin="0,0,0,10"/>
                            <ItemsControl x:Name="lstTempDetail">
                                <ItemsControl.ItemTemplate>
                                    <DataTemplate>
                                        <Grid Margin="0,0,0,6">
                                            <Grid.ColumnDefinitions>
                                                <ColumnDefinition Width="*"/>
                                                <ColumnDefinition Width="Auto"/>
                                            </Grid.ColumnDefinitions>
                                            <TextBlock Grid.Column="0" Text="{Binding Label}"
                                                       Foreground="#CCCCCC" FontSize="12"/>
                                            <TextBlock Grid.Column="1" Text="{Binding Size}"
                                                       Foreground="#FF8C00" FontSize="12"
                                                       FontWeight="SemiBold"/>
                                        </Grid>
                                    </DataTemplate>
                                </ItemsControl.ItemTemplate>
                            </ItemsControl>
                            <Border Background="#2A2A2A" Height="1" Margin="0,8"/>
                            <Grid>
                                <TextBlock Text="Total recuperable:" Foreground="#888888" FontSize="12"/>
                                <TextBlock x:Name="txtTempTotal" Text="0 MB"
                                           Foreground="#FFC107" FontSize="15"
                                           FontWeight="Bold" HorizontalAlignment="Right"/>
                            </Grid>
                        </StackPanel>
                    </Border>
                    <TextBlock Height="60"/>
                </StackPanel>
            </ScrollViewer>

            <!-- ── PANEL STARTUP ──────────────────────────────────────────────── -->
            <ScrollViewer x:Name="panStart" Visibility="Collapsed"
                          VerticalScrollBarVisibility="Auto" Padding="18">
                <StackPanel>
                    <TextBlock Text="Programas de inicio de Windows" FontSize="18" FontWeight="SemiBold"
                               Foreground="#F0F0F0" Margin="0,0,0,6"/>
                    <TextBlock Foreground="#888888" FontSize="12" Margin="0,0,0,14" TextWrapping="Wrap"
                               Text="Controla que programas se ejecutan al iniciar. Deshabilitar los innecesarios acelera el arranque."/>
                    <Border Background="#161616" CornerRadius="10" BorderBrush="#2A2A2A"
                            BorderThickness="1" Padding="16" Margin="0,0,0,12">
                        <StackPanel Orientation="Horizontal">
                            <Button x:Name="btnLoadStartup" Content="Cargar programas de inicio"
                                    Background="Transparent" Foreground="#FF8C00"
                                    BorderBrush="#FF8C00" BorderThickness="1"
                                    Padding="14,7" Cursor="Hand" Margin="0,0,12,0"/>
                            <TextBlock x:Name="txtStartCount" Text="" Foreground="#888888"
                                       FontSize="12" VerticalAlignment="Center"/>
                        </StackPanel>
                    </Border>
                    <Border Background="#161616" CornerRadius="10" BorderBrush="#2A2A2A"
                            BorderThickness="1" Padding="16">
                        <StackPanel>
                            <ListView x:Name="lstStartup" Height="280"
                                      Background="Transparent" BorderThickness="0"
                                      Foreground="#F0F0F0">
                                <ListView.View>
                                    <GridView>
                                        <GridViewColumn Header="Programa" Width="200"
                                            DisplayMemberBinding="{Binding Name}"/>
                                        <GridViewColumn Header="Ubicacion" Width="80"
                                            DisplayMemberBinding="{Binding Location}"/>
                                        <GridViewColumn Header="Estado" Width="80"
                                            DisplayMemberBinding="{Binding Status}"/>
                                        <GridViewColumn Header="Ruta" Width="230"
                                            DisplayMemberBinding="{Binding Path}"/>
                                    </GridView>
                                </ListView.View>
                            </ListView>
                            <StackPanel Orientation="Horizontal" Margin="0,10,0,0">
                                <Button x:Name="btnDisable" Content="Deshabilitar seleccionado"
                                        Background="#FF8C00" Foreground="#111111"
                                        FontWeight="Bold" BorderThickness="0"
                                        Padding="14,7" Cursor="Hand" IsEnabled="False"
                                        Margin="0,0,10,0"/>
                                <TextBlock x:Name="txtStartResult" Text=""
                                           Foreground="#4CAF50" FontSize="13"
                                           FontWeight="SemiBold" VerticalAlignment="Center"/>
                            </StackPanel>
                        </StackPanel>
                    </Border>
                    <TextBlock Height="60"/>
                </StackPanel>
            </ScrollViewer>

            <!-- ── PANEL POWER ────────────────────────────────────────────────── -->
            <ScrollViewer x:Name="panPower" Visibility="Collapsed"
                          VerticalScrollBarVisibility="Auto" Padding="18">
                <StackPanel>
                    <TextBlock Text="Plan de energia de Windows" FontSize="18" FontWeight="SemiBold"
                               Foreground="#F0F0F0" Margin="0,0,0,6"/>
                    <TextBlock Foreground="#888888" FontSize="12" Margin="0,0,0,14" TextWrapping="Wrap"
                               Text="El plan de energia afecta directamente el rendimiento del CPU."/>
                    <Border Background="#161616" CornerRadius="10" BorderBrush="#2A2A2A"
                            BorderThickness="1" Padding="14" Margin="0,0,0,16">
                        <StackPanel Orientation="Horizontal">
                            <TextBlock Text="Plan activo: " Foreground="#888888" FontSize="13"/>
                            <TextBlock x:Name="txtActivePlan" Text="Leyendo..."
                                       Foreground="#FF8C00" FontSize="13" FontWeight="Bold"/>
                        </StackPanel>
                    </Border>
                    <Grid>
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="10"/>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="10"/>
                            <ColumnDefinition Width="*"/>
                        </Grid.ColumnDefinitions>
                        <Border Grid.Column="0" Background="#161616" CornerRadius="10"
                                BorderBrush="#2A2A2A" BorderThickness="1" Padding="16">
                            <StackPanel>
                                <TextBlock Text="Equilibrado" FontSize="16" FontWeight="SemiBold"
                                           Foreground="#F0F0F0" Margin="0,0,0,6"/>
                                <TextBlock Foreground="#888888" FontSize="12" TextWrapping="Wrap" Margin="0,0,0,14"
                                           Text="Ajusta CPU segun la carga actual. Mejor equilibrio."/>
                                <Button x:Name="btnBal" Content="Activar"
                                        Background="Transparent" Foreground="#FF8C00"
                                        BorderBrush="#FF8C00" BorderThickness="1"
                                        Padding="14,7" Cursor="Hand"/>
                            </StackPanel>
                        </Border>
                        <Border Grid.Column="2" Background="#1A1200" CornerRadius="10"
                                BorderBrush="#FF8C00" BorderThickness="1" Padding="16">
                            <StackPanel>
                                <TextBlock Text="Alto rendimiento" FontSize="16" FontWeight="SemiBold"
                                           Foreground="#F0F0F0" Margin="0,0,0,6"/>
                                <TextBlock Foreground="#888888" FontSize="12" TextWrapping="Wrap" Margin="0,0,0,14"
                                           Text="CPU siempre al maximo. Mejor velocidad del sistema."/>
                                <Button x:Name="btnHigh" Content="Activar"
                                        Background="#FF8C00" Foreground="#111111"
                                        FontWeight="Bold" BorderThickness="0"
                                        Padding="14,7" Cursor="Hand"/>
                            </StackPanel>
                        </Border>
                        <Border Grid.Column="4" Background="#161616" CornerRadius="10"
                                BorderBrush="#2A2A2A" BorderThickness="1" Padding="16">
                            <StackPanel>
                                <TextBlock Text="Ahorro de energia" FontSize="16" FontWeight="SemiBold"
                                           Foreground="#F0F0F0" Margin="0,0,0,6"/>
                                <TextBlock Foreground="#888888" FontSize="12" TextWrapping="Wrap" Margin="0,0,0,14"
                                           Text="Reduce CPU para maximizar la duracion de la bateria."/>
                                <Button x:Name="btnSave" Content="Activar"
                                        Background="Transparent" Foreground="#FF8C00"
                                        BorderBrush="#FF8C00" BorderThickness="1"
                                        Padding="14,7" Cursor="Hand"/>
                            </StackPanel>
                        </Border>
                    </Grid>
                    <TextBlock x:Name="txtPlanResult" Text="" Foreground="#4CAF50"
                               FontSize="13" FontWeight="SemiBold"
                               Margin="0,16,0,0" HorizontalAlignment="Center"/>
                    <TextBlock Height="60"/>
                </StackPanel>
            </ScrollViewer>

        </Grid>

        <!-- STATUS BAR -->
        <Border Grid.Row="3" Background="#0F0F0F" BorderBrush="#222222" BorderThickness="0,1,0,0">
            <Grid Margin="18,0">
                <TextBlock x:Name="txtStatus" Text="Listo" Foreground="#666666"
                           FontSize="11" VerticalAlignment="Center"/>
                <TextBlock Text="v1.0.0 - github.com/EnMaNueL-G/WinOptimizer"
                           Foreground="#444444" FontSize="11"
                           VerticalAlignment="Center" HorizontalAlignment="Right"/>
            </Grid>
        </Border>
    </Grid>
</Window>
"@

# ── Cargar ventana ──────────────────────────────────────────────────────────────
$reader = [System.Xml.XmlNodeReader]::new($xaml)
$window = [System.Windows.Markup.XamlReader]::Load($reader)

function Get-C($n) { $window.FindName($n) }

$txtSysInfo   = Get-C "txtSysInfo"
$txtCpu       = Get-C "txtCpu"
$txtCpuName   = Get-C "txtCpuName"
$txtRam       = Get-C "txtRam"
$txtRamOf     = Get-C "txtRamOf"
$txtDisk      = Get-C "txtDisk"
$txtDiskOf    = Get-C "txtDiskOf"
$txtLog       = Get-C "txtLog"
$txtStatus    = Get-C "txtStatus"
$txtRamTotal  = Get-C "txtRamTotal"
$txtRamUsed   = Get-C "txtRamUsed"
$txtRamFree   = Get-C "txtRamFree"
$txtRamPct    = Get-C "txtRamPct"
$barRam       = Get-C "barRam"
$txtRamResult = Get-C "txtRamResult"
$lstProc      = Get-C "lstProc"
$chkTemp      = Get-C "chkTemp"
$chkWinTemp   = Get-C "chkWinTemp"
$chkPrefetch  = Get-C "chkPrefetch"
$chkRecycle   = Get-C "chkRecycle"
$txtTempResult= Get-C "txtTempResult"
$borderTempD  = Get-C "borderTempDetail"
$lstTempD     = Get-C "lstTempDetail"
$txtTempTotal = Get-C "txtTempTotal"
$lstStartup   = Get-C "lstStartup"
$txtStartCount= Get-C "txtStartCount"
$txtStartRes  = Get-C "txtStartResult"
$txtActivePlan= Get-C "txtActivePlan"
$txtPlanResult= Get-C "txtPlanResult"
$btnCleanTemp = Get-C "btnCleanTemp"
$btnDisable   = Get-C "btnDisable"

# Panels
$panDash  = Get-C "panDash"
$panRam   = Get-C "panRam"
$panTemp  = Get-C "panTemp"
$panStart = Get-C "panStart"
$panPower = Get-C "panPower"

# Tab buttons
$tabDash    = Get-C "tabDash"
$tabRam     = Get-C "tabRam"
$tabTemp    = Get-C "tabTemp"
$tabStartup = Get-C "tabStartup"
$tabPower   = Get-C "tabPower"

# ── Navegacion entre tabs ────────────────────────────────────────────────────────
$allPanels = @($panDash, $panRam, $panTemp, $panStart, $panPower)
$allTabs   = @($tabDash, $tabRam, $tabTemp, $tabStartup, $tabPower)

function Switch-Tab($idx) {
    $vis  = [System.Windows.Visibility]::Visible
    $col  = [System.Windows.Visibility]::Collapsed
    $orange = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#FF8C00")
    $trans  = [System.Windows.Media.Brushes]::Transparent
    $gray   = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#888888")
    $dark   = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#111111")
    for ($i = 0; $i -lt $allPanels.Count; $i++) {
        if ($allPanels[$i] -ne $null) {
            $allPanels[$i].Visibility = if ($i -eq $idx) { $vis } else { $col }
        }
        if ($allTabs[$i] -ne $null) {
            $allTabs[$i].Background = if ($i -eq $idx) { $orange } else { $trans }
            $allTabs[$i].Foreground = if ($i -eq $idx) { $dark }   else { $gray }
            $allTabs[$i].FontWeight = if ($i -eq $idx) { "Bold" }  else { "Normal" }
        }
    }
}

$tabDash.Add_Click(    { Switch-Tab 0 })
$tabRam.Add_Click(     { Switch-Tab 1 })
$tabTemp.Add_Click(    { Switch-Tab 2 })
$tabStartup.Add_Click( { Switch-Tab 3 })
$tabPower.Add_Click(   { Switch-Tab 4 })

# ── Helpers ──────────────────────────────────────────────────────────────────────
function Fmt([long]$b) {
    if ($b -ge 1GB)  { "{0:F1} GB" -f ($b/1GB) }
    elseif ($b -ge 1MB)  { "{0:F1} MB" -f ($b/1MB) }
    elseif ($b -ge 1KB)  { "{0:F1} KB" -f ($b/1KB) }
    else { "$b B" }
}
function Log($m) {
    $t = (Get-Date).ToString("HH:mm:ss")
    $txtLog.Text = "[$t] $m`n" + $txtLog.Text
}
function Status($m) { $txtStatus.Text = $m }

# ── Cache info del sistema (se llena una vez, background) ────────────────────────
$script:totalRamMB = 32768
$script:cpuNameStr = ""
$script:initialized = $false

function Init-SysInfo {
    if ($script:initialized) { return }
    try {
        $os  = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $script:totalRamMB = [long]($os.TotalVisibleMemorySize / 1KB)
        $cpu = Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1
        $script:cpuNameStr = $cpu.Name.Trim() -replace '\s+',' '
        $txtCpuName.Text   = $script:cpuNameStr
        $script:initialized = $true
    } catch {}
}

# ── Actualizar stats — solo contadores performance (rapidos) ─────────────────────
$script:tickN = 0
function Update-Stats {
    $script:tickN++
    try {
        # CPU via contador (no WMI)
        $cpuPct = [int](Get-Counter '\Procesador(_Total)\% de tiempo de procesador' -ErrorAction Stop
                       ).CounterSamples[0].CookedValue
        $txtCpu.Text = "$cpuPct%"

        # RAM
        $freeMB  = [long](Get-Counter '\Memoria\Mbytes disponibles' -ErrorAction Stop
                          ).CounterSamples[0].CookedValue
        $totalMB = $script:totalRamMB
        $usedMB  = $totalMB - $freeMB
        $pct     = [int](($usedMB / $totalMB) * 100)

        $txtRam.Text   = Fmt ($usedMB * 1MB)
        $txtRamOf.Text = "de $(Fmt ($totalMB*1MB))"
        $txtRamTotal.Text = Fmt ($totalMB * 1MB)
        $txtRamUsed.Text  = Fmt ($usedMB  * 1MB)
        $txtRamFree.Text  = Fmt ($freeMB  * 1MB)
        $txtRamPct.Text   = "$pct%"

        $bp = $barRam.Parent
        if ($bp -and $bp.ActualWidth -gt 0) { $barRam.Width = $bp.ActualWidth * ($pct/100.0) }

        # Disco
        $d  = Get-PSDrive C -ErrorAction Stop
        $df = $d.Free; $dt = $df + $d.Used
        $txtDisk.Text   = Fmt $df
        $txtDiskOf.Text = "de $(Fmt $dt)"

        $txtSysInfo.Text = "CPU $cpuPct% | RAM $pct% | $(Fmt $df) libres en C:"

        # Info CIM en tick 3 (ya se ve la ventana, no bloquea)
        if ($script:tickN -eq 3) { Init-SysInfo }
    } catch {}
}

# ── Liberar RAM ──────────────────────────────────────────────────────────────────
function Free-RAM {
    Status "Liberando RAM..."
    $before = [long](Get-Counter '\Memoria\Mbytes disponibles').CounterSamples[0].CookedValue

    [System.GC]::Collect(2, [System.GCCollectionMode]::Forced)
    [System.GC]::WaitForPendingFinalizers()

    $skip = @('System','smss','csrss','wininit','winlogon','lsass','services','svchost','Registry')
    $n = 0
    Get-Process | Where-Object { $_.WorkingSet64 -gt 20MB -and $skip -notcontains $_.ProcessName } |
        Sort-Object WorkingSet64 -Descending | Select-Object -First 30 |
        ForEach-Object {
            try { $_.MinWorkingSet = [IntPtr]1; $_.MaxWorkingSet = [IntPtr]1; $n++ } catch {}
        }

    Start-Sleep -Milliseconds 600
    $after = [long](Get-Counter '\Memoria\Mbytes disponibles').CounterSamples[0].CookedValue
    $freed = ($after - $before) * 1MB
    if ($freed -lt 0) { $freed = 0 }

    $msg = if ($freed -gt 1MB) { "OK $(Fmt $freed) liberados ($n procesos)" }
           else                 { "OK RAM optimizada ($n procesos)" }
    $txtRamResult.Text = $msg
    Log $msg
    Status "RAM liberada"
    Update-Stats
}

# ── Procesos ─────────────────────────────────────────────────────────────────────
function Load-Procs {
    $items = Get-Process | Where-Object { $_.WorkingSet64 -gt 10MB } |
             Sort-Object WorkingSet64 -Descending | Select-Object -First 20 |
             ForEach-Object { [PSCustomObject]@{ Name=$_.ProcessName; RamMB=[int]($_.WorkingSet64/1MB); PID=$_.Id } }
    $lstProc.ItemsSource = $items
}

# ── Archivos temporales ───────────────────────────────────────────────────────────
$script:tempData = @()
function Scan-Temp {
    Status "Analizando..."
    $btnCleanTemp.IsEnabled = $false
    $areas = @()
    if ($chkTemp.IsChecked)    { $sz=(Get-ChildItem $env:TEMP -Recurse -EA SilentlyContinue|Measure Length -Sum -EA SilentlyContinue).Sum; $areas += [PSCustomObject]@{Label="%TEMP%";Size=(Fmt $sz);Bytes=$sz;Key="temp"} }
    if ($chkWinTemp.IsChecked) { $sz=(Get-ChildItem "C:\Windows\Temp" -Recurse -EA SilentlyContinue|Measure Length -Sum -EA SilentlyContinue).Sum; $areas += [PSCustomObject]@{Label="Windows\Temp";Size=(Fmt $sz);Bytes=$sz;Key="wtemp"} }
    if ($chkPrefetch.IsChecked){ $sz=(Get-ChildItem "C:\Windows\Prefetch" -Recurse -EA SilentlyContinue|Measure Length -Sum -EA SilentlyContinue).Sum; $areas += [PSCustomObject]@{Label="Prefetch";Size=(Fmt $sz);Bytes=$sz;Key="pre"} }
    if ($chkRecycle.IsChecked) { $sz=(Get-ChildItem "C:\`$Recycle.Bin" -Recurse -Force -EA SilentlyContinue|Measure Length -Sum -EA SilentlyContinue).Sum; $areas += [PSCustomObject]@{Label="Papelera";Size=(Fmt $sz);Bytes=$sz;Key="rec"} }
    $script:tempData = $areas
    $lstTempD.ItemsSource = $areas
    $total = ($areas | Measure Bytes -Sum).Sum
    $txtTempTotal.Text = Fmt $total
    $borderTempD.Visibility = "Visible"
    $txtTempResult.Text = "Analisis completo. Recuperable: $(Fmt $total)"
    $txtTempResult.Foreground = "#FFC107"
    $btnCleanTemp.IsEnabled = ($total -gt 0)
    Status "Analisis completado"
}

function Clean-Temp {
    Status "Limpiando..."
    $freed = 0L
    foreach ($a in $script:tempData) {
        switch ($a.Key) {
            "temp"  { Get-ChildItem $env:TEMP -Recurse -EA SilentlyContinue | Remove-Item -Recurse -Force -EA SilentlyContinue; $freed += $a.Bytes }
            "wtemp" { Get-ChildItem "C:\Windows\Temp" -Recurse -EA SilentlyContinue | Remove-Item -Recurse -Force -EA SilentlyContinue; $freed += $a.Bytes }
            "pre"   { Get-ChildItem "C:\Windows\Prefetch" -Recurse -EA SilentlyContinue | Remove-Item -Recurse -Force -EA SilentlyContinue; $freed += $a.Bytes }
            "rec"   { Clear-RecycleBin -Force -EA SilentlyContinue; $freed += $a.Bytes }
        }
    }
    $msg = "OK $(Fmt $freed) eliminados"
    $txtTempResult.Text = $msg
    $txtTempResult.Foreground = "#4CAF50"
    Log $msg
    $btnCleanTemp.IsEnabled = $false
    $borderTempD.Visibility = "Collapsed"
    Status "Limpieza completada"
    Update-Stats
}

# ── Startup ───────────────────────────────────────────────────────────────────────
function Load-Startup {
    Status "Leyendo inicio..."
    $items = @()
    $keys = @("HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run","HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run")
    foreach ($k in $keys) {
        if (Test-Path $k) {
            (Get-ItemProperty $k).PSObject.Properties | Where-Object { $_.Name -notlike "PS*" } |
            ForEach-Object { $items += [PSCustomObject]@{Name=$_.Name;Path=$_.Value;Location=($k -replace '.*\\Run$','Reg');Status="Habilitado";Key=$k} }
        }
    }
    $sf = [Environment]::GetFolderPath("Startup")
    if (Test-Path $sf) {
        Get-ChildItem $sf -EA SilentlyContinue |
        ForEach-Object { $items += [PSCustomObject]@{Name=$_.BaseName;Path=$_.FullName;Location="Carpeta";Status="Habilitado";Key=""} }
    }
    $lstStartup.ItemsSource = $items
    $txtStartCount.Text = "$($items.Count) programas"
    Status "Startup cargado"
}

function Disable-StartItem {
    $s = $lstStartup.SelectedItem
    if (-not $s) { return }
    try {
        if ($s.Location -eq "Carpeta") {
            Rename-Item $s.Path ([System.IO.Path]::ChangeExtension($s.Path,".disabled")) -EA Stop
        } else {
            Remove-ItemProperty -Path $s.Key -Name $s.Name -EA Stop
        }
        $txtStartRes.Text = "OK '$($s.Name)' deshabilitado"
        Log "Startup deshabilitado: $($s.Name)"
        Load-Startup
    } catch { $txtStartRes.Text = "Requiere administrador" }
}

# ── Plan de energia ───────────────────────────────────────────────────────────────
function Read-Plan {
    try {
        $out = & powercfg /getactivescheme 2>$null
        $txtActivePlan.Text = if ($out -match "Equilibrado|Balanced") { "Equilibrado" }
                              elseif ($out -match "Alto|High perf")   { "Alto rendimiento" }
                              elseif ($out -match "Ahorro|Saver")     { "Ahorro de energia" }
                              else { $out -replace '.*\(',''-replace'\).*','' }
    } catch { $txtActivePlan.Text = "No disponible" }
}

function Set-Plan($guid, $name) {
    try {
        & powercfg /setactive $guid 2>$null
        $txtPlanResult.Text = "OK Plan '$name' activado"
        Log "Plan energia: $name"
        Read-Plan
    } catch { $txtPlanResult.Text = "Error (intenta como admin)" }
}

# ── Optimizacion rapida ───────────────────────────────────────────────────────────
function Quick-Opt {
    (Get-C "btnQuickOpt").IsEnabled = $false
    Log "=== Optimizacion rapida ==="
    Status "Optimizando..."
    [System.GC]::Collect(2, [System.GCCollectionMode]::Forced)
    [System.GC]::WaitForPendingFinalizers()
    $t1 = (Get-ChildItem $env:TEMP -Recurse -EA SilentlyContinue | Measure Length -Sum -EA SilentlyContinue).Sum
    Get-ChildItem $env:TEMP -Recurse -EA SilentlyContinue | Remove-Item -Recurse -Force -EA SilentlyContinue
    $t2 = (Get-ChildItem "C:\Windows\Temp" -Recurse -EA SilentlyContinue | Measure Length -Sum -EA SilentlyContinue).Sum
    Get-ChildItem "C:\Windows\Temp" -Recurse -EA SilentlyContinue | Remove-Item -Recurse -Force -EA SilentlyContinue
    Log "RAM: GC completado"
    Log "Temp: $(Fmt ($t1+$t2)) eliminados"
    Log "=== Completado OK ==="
    Status "Optimizacion completada"
    Update-Stats
    (Get-C "btnQuickOpt").IsEnabled = $true
}

# ── Eventos ───────────────────────────────────────────────────────────────────────
(Get-C "btnQuickOpt").Add_Click(    { Quick-Opt })
(Get-C "btnFreeRam").Add_Click(     { Free-RAM })
(Get-C "btnRefreshProc").Add_Click( { Load-Procs })
(Get-C "btnScanTemp").Add_Click(    { Scan-Temp })
$btnCleanTemp.Add_Click(            { Clean-Temp })
(Get-C "btnLoadStartup").Add_Click( { Load-Startup })
$btnDisable.Add_Click(              { Disable-StartItem })
(Get-C "btnBal").Add_Click(  { Set-Plan "381b4222-f694-41f0-9685-ff5bb260df2e" "Equilibrado" })
(Get-C "btnHigh").Add_Click( { Set-Plan "8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c" "Alto rendimiento" })
(Get-C "btnSave").Add_Click( { Set-Plan "a1841308-3541-4fab-bc81-f71556f20b4a" "Ahorro de energia" })
$lstStartup.Add_SelectionChanged({ $btnDisable.IsEnabled = ($lstStartup.SelectedItem -ne $null) })

# ── Timer — actualiza cada 4s ────────────────────────────────────────────────────
$timer = [System.Windows.Threading.DispatcherTimer]::new()
$timer.Interval = [TimeSpan]::FromSeconds(4)
$timer.Add_Tick({ Update-Stats })

# ── Arranque ─────────────────────────────────────────────────────────────────────
$window.Add_Loaded({
    Status "Iniciando..."
    Load-Procs
    Read-Plan
    $timer.Start()
    # Primera actualizacion de stats (contadores — rapidos)
    Update-Stats
    Status "Listo - WinOptimizer v1.0.0"
})

$window.Add_Closed({ $timer.Stop() })
$window.ShowDialog() | Out-Null
