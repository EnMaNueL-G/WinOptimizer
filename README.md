# WinOptimizer

Optimizador de rendimiento para Windows 10 y Windows 11. Monitorea CPU, RAM física, memoria virtual, caché del sistema, disco, red y procesos activos en tiempo real. Libera memoria, limpia temporales y permite terminar procesos — todo sin instalar nada.

> Desarrollado por **Enmanuel Gil** — Sin instalación, gratuito, código abierto.

---

## Funciones

### Monitoreo en tiempo real (cada 2 segundos)

| Métrica | Detalle |
|---|---|
| **Memoria física** | En uso %, libre, total + barra de progreso |
| **Memoria virtual** | Committed bytes vs. commit limit |
| **Caché del sistema** | Bytes residentes en RAM (system cache) |
| **CPU** | Porcentaje de uso + temperatura + modelo |
| **Almacenamiento C:** | Libre, usado, total + barra de progreso |
| **Red** | Descarga y subida del adaptador activo |

### Análisis de procesos
- **Top 5 procesos por RAM** — Nombre, MB y PID actualizados en vivo
- **Kill directo** — Botón para terminar cualquier proceso de la lista (con confirmación)

### Historial gráfico
- **Sparklines 2 minutos** — CPU (azul) y RAM (rojo) con 60 muestras en Canvas WPF

### Bandeja del sistema
- **Minimize-to-tray** — La ventana se oculta al cerrar; el icono permanece en la bandeja
- **Menú contextual** — Abrir / Optimizar / Liberar RAM / Salir desde la bandeja
- **Tooltip** — Métricas de CPU y RAM visibles sin abrir la ventana

### Acciones de optimización
- **Liberar RAM** — Reduce Working Set de procesos activos + GC forzado
- **Limpiar temporales** — Elimina archivos de `%TEMP%` y `C:\Windows\Temp`
- **Optimización rápida** — Combina ambas acciones con un solo clic
- **Auto-optimización** — Programada cada 5, 15 o 30 minutos
- **Inicio de Windows** — Abre la gestión de aplicaciones en arranque
- **Plan de energía** — Acceso directo a Opciones de energía
- **Siempre visible** — Mantiene la ventana sobre otras aplicaciones
- **Actualización manual** — Tecla `F5` o menú Ver → Actualizar

---

## Instalación y uso

### Opción A — Ejecutable (recomendado)

1. Descarga `WinOptimizer.zip` desde [Releases](https://github.com/EnMaNueL-G/WinOptimizer/releases)
2. Extrae en cualquier carpeta
3. Ejecuta `WinOptimizer.exe` (doble clic)

> **Nota:** Windows puede mostrar SmartScreen la primera vez. Haz clic en "Más información" → "Ejecutar de todas formas".

### Opción B — Script PowerShell

1. Descarga `WinOptimizer.zip`
2. Extrae en cualquier carpeta
3. Ejecuta `WinOptimizer.bat` como **administrador** para acceso completo

---

## Requisitos

| Requisito | Versión mínima |
|---|---|
| Sistema operativo | Windows 10 (versión 1903) o Windows 11 |
| PowerShell | 5.1 (incluido en Windows) |
| .NET Framework | 4.7.2 (incluido en Windows 10+) |
| Arquitectura | x64 |

> No requiere SDK, runtime adicional ni dependencias externas.

---

## Permisos

Ejecutar como administrador permite:
- Reducir Working Set de procesos del sistema
- Limpiar `C:\Windows\Temp` y `C:\Windows\Prefetch`
- Terminar procesos protegidos desde la lista Top 5

Sin administrador: todas las funciones de usuario funcionan normalmente.

---

## Arquitectura técnica

```
WinOptimizer.ps1
├── Background Worker (Runspace separado)
│   ├── CimInstance (una vez): modelo CPU, RAM total
│   ├── Get-Counter cada 2s: CPU %, RAM libre
│   │     \Procesador(_Total)\% de tiempo de procesador
│   │     \Memoria\Mbytes disponibles
│   ├── CIM Win32_PerfFormattedData_PerfOS_Memory
│   │     CommittedBytes, CommitLimit, SystemCacheResidentBytes
│   ├── CIM MSAcpi_ThermalZoneTemperature: temperatura CPU
│   ├── CIM Win32_PerfFormattedData_Tcpip_NetworkInterface
│   │     BytesReceivedPersec, BytesSentPersec
│   ├── Get-PSDrive C: espacio en disco
│   ├── Get-Process: Top 5 por WorkingSet64
│   │     Almacenado como string[]/int[] paralelos (thread-safe)
│   └── Historial: List[int] → int[] compartido (60 muestras)
├── DispatcherTimer cada 2s (hilo UI)
│   ├── Lee hashtable Synchronized (microsegundos, sin freeze)
│   ├── Actualiza TextBlocks, ProgressBars, Labels
│   └── Redibuja sparklines en WPF Canvas + Polyline
├── System.Windows.Forms.NotifyIcon (bandeja)
│   ├── Minimize-to-tray al cerrar ventana
│   └── ContextMenuStrip: Abrir/Optimizar/Liberar/Salir
└── WPF XAML
    ├── Menu (Archivo, Ver, Herramientas, Ayuda)
    ├── ScrollViewer con 9 GroupBox
    └── StatusBar con métricas en tiempo real
```

**Decisiones de diseño:**
- Sin `Add-Type -TypeDefinition` → inicio instantáneo (0ms vs 10-30s de compilación C#)
- Sin `ControlTemplate` inline en XAML → `XamlReader.Load()` instantáneo
- Top procesos como arrays `string[]/int[]` paralelos → seguros entre runspaces (no hashtables anidadas)
- `$PSScriptRoot` con fallback a `Process.MainModule.FileName` → funciona en EXE compilado
- Todo el código de UI envuelto en `try/catch` independientes → ningún error produce popup modal

---

## Compilar desde fuente

```powershell
git clone https://github.com/EnMaNueL-G/WinOptimizer.git
cd WinOptimizer
powershell -ExecutionPolicy Bypass -File _build.ps1
```

`_build.ps1` instala [PS2EXE](https://github.com/MScholtes/PS2EXE) automáticamente si no está disponible.

---

## Estructura del repositorio

```
WinOptimizer/
├── WinOptimizer.ps1     # Script principal (PowerShell + WPF)
├── WinOptimizer.bat     # Launcher con elevación UAC
├── WinOptimizer.exe     # Ejecutable compilado (ver Releases)
├── icon.ico             # Ícono de la aplicación
├── _build.ps1           # Script de compilación (PS2EXE)
└── README.md            # Este archivo
```

---

## Changelog

### v2.2.0
- **Corrección crítica**: Top procesos ahora usa arrays `string[]/int[]` paralelos; eliminados errores de propiedad "Text no encontrada" en EXE compilado
- **Corrección crítica**: Detección de ruta robusta (`$PSScriptRoot` → fallback a proceso actual); eliminados errores de "Path nulo/vacío" en EXE
- **Corrección crítica**: Todo el código de UI en bloques `try/catch` independientes; fin de popups de error en bucle
- **Kill de procesos**: Botón directo en lista Top 5 (con confirmación)
- **Temperatura CPU**: Lectura via `MSAcpi_ThermalZoneTemperature` (si el hardware lo soporta)
- **Auto-optimización**: Programada cada 5, 15 o 30 minutos desde el menú

### v2.1.0
- Memoria virtual (CommittedBytes / CommitLimit)
- Caché del sistema (SystemCacheResidentBytes)
- Velocidad de red en tiempo real
- Top 5 procesos por RAM con PID
- Historial gráfico 2 minutos (sparklines CPU + RAM)
- Bandeja del sistema con menú contextual

### v2.0.0
- Reescritura completa con Background Runspace (UI nunca se congela)
- Interfaz compacta con GroupBox, ProgressBars y StatusBar
- Compilación a .exe con ícono propio
- Menú completo (Archivo, Ver, Herramientas, Ayuda)

### v1.0.0
- Versión inicial — 5 paneles, Performance Counters

---

## Donaciones

- **Binance Pay ID:** `1140153333`
- **BSC BEP20:** `0x0a9a0d8d816ede885d1d4a5c94369a72ef86b3c1`

---

## Licencia

MIT License — libre para usar, modificar y distribuir.

© 2026 Enmanuel Gil — [github.com/EnMaNueL-G](https://github.com/EnMaNueL-G)
