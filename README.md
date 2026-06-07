# WinOptimizer

Optimizador de rendimiento para Windows 10 y Windows 11. Monitorea CPU, RAM y disco en tiempo real, libera memoria, limpia archivos temporales y gestiona el inicio del sistema.

> Desarrollado por **Enmanuel Gil** — Sin instalación, gratuito, código abierto.

---

## Capturas

| Vista principal |
|---|
| Secciones compactas: Memoria, CPU, Disco y Registro de acciones |
| Barra de estado con métricas en tiempo real |
| Botones de acción rápida en la parte inferior |

---

## Características

- **Monitoreo en tiempo real** — CPU, RAM y disco actualizados cada 2 segundos sin bloquear la interfaz
- **Liberar RAM** — Reduce el Working Set de procesos activos y fuerza recolección de basura
- **Limpiar temporales** — Elimina archivos de `%TEMP%` y `C:\Windows\Temp`
- **Optimización rápida** — Ejecuta liberación de RAM + limpieza de temporales con un clic
- **Inicio de Windows** — Abre el Administrador de tareas en la pestaña Inicio (Win 10/11)
- **Plan de energía** — Acceso directo a Opciones de energía del sistema
- **Siempre visible** — Opción para mantener la ventana sobre otras aplicaciones
- **Actualización manual** — Tecla `F5` o menú Ver → Actualizar
- **Menú completo** — Archivo / Ver / Herramientas / Ayuda con todas las funciones

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

## Arquitectura técnica

```
WinOptimizer.ps1
├── Background Worker (Runspace independiente)
│   ├── Get-CimInstance → CPU model, RAM total (una sola vez)
│   └── Get-Counter cada 2s → CPU%, RAM libre, Disco
│       \Procesador(_Total)\% de tiempo de procesador
│       \Memoria\Mbytes disponibles
│       Get-PSDrive C → libre/usado
├── DispatcherTimer (hilo UI) cada 2s
│   └── Lee hashtable compartido → actualiza TextBlocks, ProgressBars
├── Funciones de acción (hilo UI)
│   ├── Free-RAM    → GC.Collect + MinWorkingSet/MaxWorkingSet
│   ├── Clean-Temp  → Remove-Item en %TEMP% y Windows\Temp
│   └── Quick-Optimize → Free-RAM + Clean-Temp
└── WPF XAML
    ├── Menu (Archivo, Ver, Herramientas, Ayuda)
    ├── GroupBox × 4 (RAM, CPU, Disco, Registro)
    ├── ProgressBar × 3 (sin ControlTemplate custom)
    └── StatusBar con métricas en tiempo real
```

**Decisiones de diseño:**
- Sin `Add-Type -TypeDefinition` → no hay compilación C# al arrancar
- Sin `ControlTemplate` inline → XamlReader.Load() es instantáneo
- `[hashtable]::Synchronized()` para comunicación cross-thread segura
- Performance Counters en español (Windows en ES: `\Procesador` en lugar de `\Processor`)

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

### v2.0.0
- Interfaz rediseñada: compacta, funcional, inspirada en herramientas de sistema clásicas
- Background Runspace para lecturas de contador sin bloquear la UI
- Menú completo (Archivo, Ver, Herramientas, Ayuda)
- Acceso directo a Inicio de Windows y Plan de energía
- Barra de progreso visual para RAM, CPU y disco
- Barra de estado persistente con métricas en tiempo real
- Compilación a .exe con ícono propio

### v1.0.0
- Versión inicial con 5 paneles (Dashboard, RAM, Temp, Startup, Power)
- Performance Counters en lugar de WMI para lecturas rápidas

---

## Donaciones

Si encuentras útil esta herramienta:

- **Binance Pay ID:** `1140153333`
- **BSC BEP20:** `0x0a9a0d8d816ede885d1d4a5c94369a72ef86b3c1`

---

## Licencia

MIT License — libre para usar, modificar y distribuir.

© 2026 Enmanuel Gil — [github.com/EnMaNueL-G](https://github.com/EnMaNueL-G)
