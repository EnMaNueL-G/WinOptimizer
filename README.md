# WinOptimizer

Optimizador de rendimiento para Windows 10 y Windows 11. Monitorea CPU, RAM física, memoria virtual, caché del sistema, disco, red y procesos activos — todo en tiempo real, sin instalar nada.

> Desarrollado por **Enmanuel Gil** — Sin instalación, gratuito, código abierto.

---

## Capturas

| Vista principal |
|---|
| Secciones: RAM física, RAM virtual, Caché, CPU, Disco, Red, Historial, Top procesos |
| Icono en la bandeja del sistema con menú contextual |
| Historial gráfico de 2 minutos (CPU y RAM) |
| Barra de estado con métricas en tiempo real |

---

## Características

### Monitoreo en tiempo real (cada 2 segundos)
- **Memoria física** — En uso %, libre GB, total GB + barra de progreso
- **Memoria virtual (paginada)** — Committed bytes vs. commit limit
- **Caché del sistema** — Bytes residentes en RAM (System Cache)
- **Procesador CPU** — Porcentaje de uso + modelo detectado automáticamente
- **Almacenamiento C:** — Libre, usado y total + barra de progreso
- **Red** — Velocidad de descarga y subida del adaptador activo

### Análisis de procesos
- **Top 5 procesos por RAM** — Nombre, MB en uso y PID, actualizado en vivo

### Historial gráfico
- **Sparklines 2 minutos** — Gráfico visual de CPU (azul) y RAM (rojo) con 60 muestras

### Bandeja del sistema
- **Minimizar a la bandeja** — La ventana se oculta al cerrar o al usar el menú
- **Menú contextual** — Abrir, Optimizar, Liberar RAM, Salir
- **Tooltip** — CPU%, RAM% y espacio libre sin abrir la ventana

### Acciones de optimización
- **Liberar RAM** — Reduce Working Set de procesos activos + GC forzado
- **Limpiar temporales** — Elimina archivos de `%TEMP%` y `C:\Windows\Temp`
- **Optimización rápida** — Libera RAM + limpia temporales con un clic
- **Inicio de Windows** — Abre el Administrador de tareas en pestaña Inicio
- **Plan de energía** — Acceso directo a Opciones de energía del sistema
- **Siempre visible** — Opción para mantener la ventana sobre otras aplicaciones
- **Actualización manual** — Tecla `F5` o menú Ver → Actualizar

---

## Instalación y uso

### Opción A — Ejecutable (recomendado)

1. Descarga `WinOptimizer.zip` desde [Releases](https://github.com/EnMaNueL-G/WinOptimizer/releases)
2. Extrae en cualquier carpeta
3. Ejecuta `WinOptimizer.exe` (doble clic)

> **Nota:** Windows puede mostrar una advertencia SmartScreen la primera vez. Haz clic en "Más información" → "Ejecutar de todas formas".

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

> No requiere instalación de SDK, runtime de .NET adicional ni dependencias externas.

---

## Permisos recomendados

Ejecutar como administrador permite:
- Reducir Working Set de procesos del sistema
- Limpiar `C:\Windows\Temp` y `C:\Windows\Prefetch`
- Acceso completo al gestor de inicio de Windows

Sin permisos de administrador: todas las funciones de usuario funcionan normalmente.

---

## Comparación con herramientas similares

| Función | WinOptimizer | Mem Reduct |
|---|:---:|:---:|
| Memoria física | ✅ | ✅ |
| Memoria virtual | ✅ | ✅ |
| Caché del sistema | ✅ | ✅ |
| Bandeja del sistema | ✅ | ✅ |
| CPU en tiempo real | ✅ | ❌ |
| Disco en tiempo real | ✅ | ❌ |
| Velocidad de red | ✅ | ❌ |
| Top procesos por RAM | ✅ | ❌ |
| Historial gráfico | ✅ | ❌ |
| Limpiar temporales | ✅ | ❌ |
| Gestión de inicio | ✅ | ❌ |
| Sin instalación | ✅ | ❌ |
| Código abierto | ✅ | ❌ |

---

## Arquitectura técnica

```
WinOptimizer.ps1
├── Background Worker (Runspace independiente)
│   ├── CimInstance (una vez): modelo CPU, RAM total
│   ├── Get-Counter cada 2s: CPU%, RAM libre
│   │     \Procesador(_Total)\% de tiempo de procesador
│   │     \Memoria\Mbytes disponibles
│   ├── CimInstance PerfOS_Memory: Memoria virtual + Caché
│   │     CommittedBytes, CommitLimit, SystemCacheResidentBytes
│   ├── CimInstance Tcpip_NetworkInterface: Velocidad de red
│   │     BytesReceivedPersec, BytesSentPersec
│   ├── Get-PSDrive C: espacio en disco
│   ├── Get-Process: Top 5 por WorkingSet64
│   └── Historial (List[int] local → array compartido)
├── DispatcherTimer (hilo UI) cada 2s
│   ├── Lee hashtable compartido (thread-safe, microsegundos)
│   ├── Actualiza: TextBlocks, ProgressBars, Labels
│   ├── Dibuja sparklines (WPF Canvas + Polyline)
│   └── Actualiza tooltip de la bandeja
├── System.Windows.Forms.NotifyIcon
│   ├── Minimize-to-tray al cerrar ventana
│   └── ContextMenuStrip: Abrir / Optimizar / Liberar RAM / Salir
└── WPF XAML
    ├── Menu (Archivo, Ver, Herramientas, Ayuda)
    ├── ScrollViewer con 9 GroupBox
    │   RAM física, RAM virtual, Caché, CPU, Disco, Red,
    │   Historial gráfico, Top procesos, Registro
    ├── ProgressBar × 5 (sin ControlTemplate custom)
    └── StatusBar con métricas en tiempo real
```

**Decisiones de diseño:**
- Sin `Add-Type -TypeDefinition` → sin compilación C# al arrancar (0ms vs 10-30s)
- Sin `ControlTemplate` inline → `XamlReader.Load()` instantáneo
- `[hashtable]::Synchronized()` para comunicación cross-thread segura
- Performance Counters en español (Windows en ES: `\Procesador` en lugar de `\Processor`)
- `NotifyIcon` cargado como assembly, sin Add-Type (sin compilación)

---

## Compilar desde fuente

```powershell
# Clonar repositorio
git clone https://github.com/EnMaNueL-G/WinOptimizer.git
cd WinOptimizer

# Ejecutar build (genera icon.ico + WinOptimizer.exe)
powershell -ExecutionPolicy Bypass -File _build.ps1
```

El script `_build.ps1` instala automáticamente [PS2EXE](https://github.com/MScholtes/PS2EXE) si no está disponible.

---

## Estructura del repositorio

```
WinOptimizer/
├── WinOptimizer.ps1    # Script principal (PowerShell + WPF)
├── WinOptimizer.bat    # Launcher con elevación UAC automática
├── WinOptimizer.exe    # Ejecutable compilado (ver Releases)
├── icon.ico            # Ícono de la aplicación
├── _build.ps1          # Script de compilación
└── README.md           # Este archivo
```

---

## Changelog

### v2.1.0
- **Memoria virtual** — Sección dedicada con CommittedBytes vs CommitLimit
- **Caché del sistema** — SystemCacheResidentBytes en tiempo real
- **Red** — Velocidad de descarga y subida del adaptador activo
- **Top 5 procesos** — Por RAM física, con PID y MB en uso
- **Historial gráfico** — Sparklines de 2 minutos para CPU y RAM
- **Bandeja del sistema** — Minimize-to-tray, menú contextual, tooltip
- Interfaz reestructurada con ScrollViewer para alojar todas las secciones

### v2.0.0
- Interfaz rediseñada: compacta, funcional, inspirada en herramientas de sistema clásicas
- Background Runspace para lecturas de contador sin bloquear la UI
- Menú completo (Archivo, Ver, Herramientas, Ayuda)
- Compilación a .exe con ícono propio

### v1.0.0
- Versión inicial con 5 paneles (Dashboard, RAM, Temp, Startup, Power)
- Performance Counters para lecturas en tiempo real

---

## Donaciones

Si encuentras útil esta herramienta:

- **Binance Pay ID:** `1140153333`
- **BSC BEP20:** `0x0a9a0d8d816ede885d1d4a5c94369a72ef86b3c1`

---

## Licencia

MIT License — libre para usar, modificar y distribuir.

© 2026 Enmanuel Gil — [github.com/EnMaNueL-G](https://github.com/EnMaNueL-G)
