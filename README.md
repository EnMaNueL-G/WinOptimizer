# WinOptimizer

Optimizador de rendimiento para Windows 10 y Windows 11.
Monitorea el sistema en tiempo real, gestiona el inicio de Windows, libera memoria y limpia archivos temporales — sin instalación, sin publicidad, sin telemetría.

> Desarrollado por **Enmanuel Gil** — Código abierto, gratuito, auditable.

---

## Funciones

### Monitoreo en tiempo real (cada 2 segundos)

| Sección | Qué muestra |
|---|---|
| **Memoria física** | En uso %, libre, total + barra de progreso |
| **Memoria virtual** | Committed bytes vs. commit limit (pagefile) |
| **Caché del sistema** | Bytes residentes en RAM |
| **CPU** | Uso % + temperatura (si el hardware lo reporta) + modelo |
| **Almacenamiento C:** | Libre, usado, total + barra de progreso |
| **Red** | Velocidad de descarga y subida del adaptador activo |

### Inicio de Windows — integrado en la GUI

- Lista todos los programas configurados para arrancar con Windows (registro HKCU y HKLM)
- Muestra el estado actual: activo o inactivo
- **Recomendaciones automáticas** por categoría:
  - `Sistema` — componente del SO, no modificar
  - `No esencial` — programas que ralentizan el arranque sin ser necesarios
  - `Revisar` — controladores y software de terceros
  - `Desconocido` — entrada no clasificada
- **Activar / Desactivar** con un clic (usa la clave `StartupApproved` del registro, igual que el Administrador de tareas de Windows)

### Procesos activos
- **Top 5 por RAM** — nombre, MB en uso, PID
- **Botón Kill** con confirmación para terminar cualquier proceso de la lista

### Historial gráfico
- Sparklines de 2 minutos para CPU (azul) y RAM (rojo) — 60 muestras en Canvas WPF

### Bandeja del sistema
- La app se minimiza a la bandeja al cerrar la ventana
- Menú contextual: Abrir / Optimizar / Liberar RAM / Salir
- Tooltip con métricas sin abrir la ventana

### Acciones
- **Optimizar sistema** — libera Working Set + limpia temporales + GC forzado
- **Liberar RAM** — reduce Working Set de procesos activos
- **Limpiar temporales** — elimina archivos de `%TEMP%` y `C:\Windows\Temp`
- **Auto-optimización** — programada cada 5, 15 o 30 minutos desde el menú
- **Plan de energía** — acceso directo a Opciones de energía

---

## Instalación

### Opción A — Ejecutable (recomendado)

1. Descarga `WinOptimizer.zip` desde [Releases](https://github.com/EnMaNueL-G/WinOptimizer/releases/latest)
2. Extrae en cualquier carpeta
3. Ejecuta `WinOptimizer.exe` (doble clic)

> Windows puede mostrar SmartScreen la primera vez. Haz clic en **"Más información" → "Ejecutar de todas formas"**.

### Opción B — Script PowerShell

1. Descarga y extrae `WinOptimizer.zip`
2. Ejecuta `WinOptimizer.bat` como **administrador** para acceso completo

---

## Requisitos

| Requisito | Versión |
|---|---|
| Sistema operativo | Windows 10 (v1903) o Windows 11 |
| PowerShell | 5.1 (incluido en Windows) |
| .NET Framework | 4.7.2 (incluido en Windows 10+) |
| Arquitectura | x64 |

---

## Permisos

**Sin administrador:** todas las funciones de monitoreo, historial, top procesos, liberar RAM y limpiar temporales del usuario funcionan normalmente.

**Con administrador:** acceso completo para modificar entradas de inicio del sistema (HKLM), terminar procesos protegidos y limpiar `C:\Windows\Temp`.

---

## Arquitectura técnica

```
WinOptimizer.ps1
├── Background Worker (Runspace independiente — nunca bloquea la UI)
│   ├── Get-Counter cada 2s: CPU %, RAM libre
│   ├── CIM Win32_PerfFormattedData_PerfOS_Memory: virtual + cache
│   ├── CIM MSAcpi_ThermalZoneTemperature: temperatura CPU
│   ├── CIM Win32_PerfFormattedData_Tcpip_NetworkInterface: red
│   ├── Get-PSDrive C: espacio en disco
│   ├── Get-Process: Top 5 por WorkingSet64
│   │     Almacenados como string[]/int[] paralelos (thread-safe)
│   └── Historial: List[int] local -> int[] compartido (60 muestras)
│
├── DispatcherTimer cada 2s (hilo UI)
│   ├── Lee hashtable Synchronized (microsegundos, sin freeze)
│   └── Actualiza controles + sparklines (Canvas + Polyline)
│
├── Gestor de Inicio de Windows
│   ├── Lee HKCU/HKLM\...\Run para listar entradas
│   ├── Lee StartupApproved para estado activo/inactivo
│   ├── Escribe StartupApproved para activar/desactivar
│   ├── Motor de recomendaciones por nombre de entrada
│   └── UI dinámica: controles WPF creados en código (sin templates XAML)
│
├── System.Windows.Forms.NotifyIcon (bandeja — sin Add-Type/compilacion)
└── WPF XAML: ScrollViewer con 9 GroupBox, StatusBar, Menu
```

**Decisiones clave:**
- Sin `Add-Type -TypeDefinition` — inicio en 0ms (vs 10–30s de compilacion C#)
- Sin `ControlTemplate` inline — `XamlReader.Load()` instantaneo
- Top procesos como `string[]/int[]` paralelos — seguros entre runspaces
- `$PSScriptRoot` con fallback a `Process.MainModule.FileName` — funciona en EXE
- Todo el codigo de UI en bloques `try/catch` independientes — ningún error genera popup

---

## Compilar desde fuente

```powershell
git clone https://github.com/EnMaNueL-G/WinOptimizer.git
cd WinOptimizer
powershell -ExecutionPolicy Bypass -File _build.ps1
```

`_build.ps1` instala [PS2EXE](https://github.com/MScholtes/PS2EXE) automaticamente si no está disponible.

---

## Estructura del repositorio

```
WinOptimizer/
├── WinOptimizer.ps1     # Script principal
├── WinOptimizer.bat     # Launcher con elevacion UAC
├── WinOptimizer.exe     # Ejecutable compilado (ver Releases)
├── icon.ico             # Icono de la aplicacion
├── _build.ps1           # Script de compilacion
└── README.md            # Este archivo
```

---

## Changelog

### v2.3.1
- Correccion de error NULL al iniciar: `$stTimer` movido a scope de script para que el Tick closure lo encuentre correctamente tras retornar el handler `Loaded`
- Todos los bloques del handler `Loaded` envueltos en `try/catch` independientes

### v2.3.0
- **Inicio de Windows integrado** — lista, analiza y permite activar/desactivar entradas de inicio directamente en la GUI (sin abrir el Administrador de tareas)
- **Recomendaciones automaticas** por categoria para cada entrada de inicio
- Eliminado el acceso externo al Administrador de tareas

### v2.2.1
- Correccion de errores criticos de inicializacion (NULL, operadores sin espacios)
- Funcion `On()` con null-check para todos los eventos
- `SafeText` / `SafeBar` — wrappers protegidos en toda la UI

### v2.2.0
- Temperatura CPU, boton Kill en Top 5, auto-optimizacion programada

### v2.1.0
- Memoria virtual, cache del sistema, red, historial grafico, bandeja del sistema

### v2.0.0
- Reescritura completa con Background Runspace, interfaz compacta, compilacion a .exe

### v1.0.0
- Version inicial

---

## Donaciones

- **Binance Pay ID:** `1140153333`
- **BSC BEP20:** `0x0a9a0d8d816ede885d1d4a5c94369a72ef86b3c1`

---

## Licencia

MIT License — libre para usar, modificar y distribuir.

© 2026 Enmanuel Gil — [github.com/EnMaNueL-G](https://github.com/EnMaNueL-G)
