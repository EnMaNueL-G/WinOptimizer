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

### Salud de discos
- Estado de cada disco (SSD / disco duro): **Buena**, **Atención** o **Mal estado**
- Con administrador: temperatura, horas encendido, desgaste y errores de lectura (contadores de fiabilidad de Windows + SMART)
- Avisa si un disco anuncia un fallo próximo, está muy caliente, muy desgastado o tiene muchas horas de uso

### Información del equipo
- Placa base, BIOS, procesador, RAM (módulos, velocidad y ranuras libres), gráficos y driver, versión de Windows, fecha de instalación, tiempo encendido y batería (salud real en portátiles)
- **Copiar informe**: copia todo el equipo + discos + uso actual al portapapeles, listo para pegar en un chat de soporte

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
- **Auto-optimización** — programada cada 15 o 30 minutos desde el menú (vaciar la memoria muy a menudo puede ralentizar el PC; se recomienda 30 min)
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

**Con administrador:** acceso completo para modificar entradas de inicio del sistema (HKLM), terminar procesos protegidos, limpiar `C:\Windows\Temp` y ver temperatura, horas de uso y desgaste de los discos.

---

## Arquitectura técnica

```
WinOptimizer.ps1
├── Background Worker (Runspace independiente — nunca bloquea la UI)
│   ├── Una muestra cada 2s (funciona en Windows de cualquier idioma)
│   ├── CIM Win32_Processor.LoadPercentage: CPU %
│   ├── CIM Win32_OperatingSystem: RAM libre + memoria virtual (commit)
│   ├── CIM Win32_PerfFormattedData_PerfOS_Memory: cache
│   ├── CIM MSAcpi_ThermalZoneTemperature: temperatura (si el equipo la ofrece)
│   ├── .NET NetworkInterface: velocidad de red por diferencia de bytes
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
│   ├── Lee HKCU/HKLM\...\Run, WOW6432Node\...\Run y las carpetas "Inicio"
│   ├── Lee StartupApproved (Run, Run32, StartupFolder) para estado activo/inactivo
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

### v2.4.0
- **Salud de discos**: estado de cada SSD / disco duro con avisos (fallo SMART, temperatura, desgaste, horas de uso, errores de lectura)
- **Información del equipo**: placa, BIOS, CPU, RAM (módulos y ranuras), gráficos y driver, Windows, batería
- **Copiar informe** del equipo al portapapeles (botón y menú Herramientas)
- Auto-optimización: eliminado el intervalo de 5 min (vaciar la memoria tan a menudo puede ralentizar); 30 min recomendado

### v2.3.2
Revision completa, probada en Windows 11 real:
- **Gestor de Inicio de Windows**: ahora funciona (no se podia mostrar la lista: siempre salia "Error al leer entradas de inicio"). Incluye tambien los programas de 32 bits y las carpetas "Inicio", como el Administrador de tareas, y lee bien el estado activo/inactivo
- **Procesos (top 5) y boton Kill**: ahora se muestran (la lista salia vacia)
- **Barras de CPU, cache y disco y temperatura**: ahora se actualizan (se quedaban a 0 / "--")
- **Red**: muestra la velocidad real (antes siempre 0 B/s)
- **Windows en cualquier idioma**: CPU y RAM ya no dependen de contadores en espanol (en Windows en ingles salia CPU 0% y RAM 100%)
- **Liberar RAM**: el contador de procesos ya es correcto (siempre decia 0) y mide lo liberado de verdad
- **Limpiar temporales**: solo borra archivos de mas de 24 h (no rompe instaladores en marcha) y solo cuenta lo que realmente se borro
- Datos visibles desde los primeros segundos y historial de exactamente 2 min

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

- **Binance Pay ID:** `1165745950`
- **BSC BEP20:** `0xb6f6731a4ea87f8e1fd6f44f48b5bc4204571f08`

---

## Licencia

MIT License — libre para usar, modificar y distribuir.

© 2026 Enmanuel Gil — [github.com/EnMaNueL-G](https://github.com/EnMaNueL-G)
