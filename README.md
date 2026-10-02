# Spectrum

Host de plugins Audio Unit para macOS que escucha **el audio del sistema** (o cualquier entrada de audio), lo pasa en tiempo real por una cadena de plugins AU (por ejemplo FabFilter Pro‑Q 4) y lo reproduce por la salida que elijas. Así puedes usar Pro‑Q 4 "stand alone" sobre Spotify, YouTube, Logic, lo que sea.

```
Otras apps ──► Core Audio tap ──► Spectrum ──► Pro‑Q 4 ──► (más plugins) ──► Altavoces / Auriculares
```

Mientras Spectrum está en marcha, el audio original de las demás apps se silencia (opcional) y solo oyes la señal procesada. Al detener Spectrum o cerrarlo, todo vuelve a la normalidad.

## Requisitos

- **macOS 14.2 (Sonoma) o superior.** Usa Core Audio *process taps*, así que no necesita BlackHole ni drivers virtuales. Funciona en Apple Silicon e Intel.
- **Plugins AU instalados** en `/Library/Audio/Plug-Ins/Components` (con su licencia activada en ese Mac).
- Para compilar desde código: **Xcode Command Line Tools** (`xcode-select --install`). No hace falta Xcode completo.

## Instalar en otro Mac

### Opción A: compilar desde el código (recomendada)

```bash
xcode-select --install          # solo la primera vez, si no están instaladas
git clone https://github.com/ekomeme/Spectrum.git
cd Spectrum
./build.sh --install            # compila, firma ad-hoc y copia a /Applications
```

Luego abre Spectrum desde Launchpad o Spotlight.

### Opción B: descargar la app ya compilada

En la pestaña **Releases** del repositorio hay un `Spectrum.zip` universal (Apple Silicon + Intel). Descomprímelo y arrastra `Spectrum.app` a Aplicaciones.

Como la app está firmada ad-hoc y no notarizada, al descargarla de internet macOS la bloqueará la primera vez ("no se puede abrir porque no se puede verificar el desarrollador"). Dos formas de resolverlo:

- Clic derecho sobre la app → **Abrir** → **Abrir** en el diálogo. Solo hace falta una vez.
- O quitar la cuarentena desde la Terminal: `xattr -dr com.apple.quarantine /Applications/Spectrum.app`

### Permisos

La primera vez que pulses **Iniciar**, macOS pedirá permiso de **Grabación de audio del sistema** (y de **Micrófono** si eliges una entrada física). Acéptalos. Si los rechazaste por error: Ajustes del Sistema → Privacidad y seguridad → Grabación de pantalla y audio del sistema → activa Spectrum.

## Compilar y ejecutar en desarrollo

```bash
./build.sh                 # build/Spectrum.app para este Mac
./build.sh --universal --zip   # binario universal + zip para distribuir
open build/Spectrum.app
```

> La app se firma *ad‑hoc*. Cada vez que recompilas cambia la firma y macOS puede volver a pedir el permiso. Si tienes un certificado de desarrollador puedes firmar con él:
> `CODESIGN_IDENTITY="Apple Development: Tu Nombre (TEAMID)" ./build.sh`

## Uso

1. **Fuente**: "Audio del sistema (todas las apps)" o un dispositivo de entrada concreto (micrófono, interfaz, BlackHole…).
2. **Salida**: el dispositivo por el que quieres escuchar. Puede ser distinto del predeterminado del sistema.
3. **Buffer**: 64–1024 frames. Menor = menos latencia, más CPU. 256 va bien en general.
4. **Silenciar el audio original**: con la fuente "Audio del sistema", silencia el sonido directo de las otras apps para que solo oigas la señal procesada. Desactívalo si prefieres oír ambas.
5. **Añadir plugin…**: busca "Pro-Q" y añádelo. Se abre su interfaz automáticamente; puedes reabrirla con **Interfaz**.
6. Puedes encadenar varios plugins, reordenarlos (▲ ▼), hacer *bypass* o quitarlos.
7. **Iniciar / Detener**.
8. Al cerrar la ventana con la X, Spectrum sigue funcionando desde el icono de la barra de menús (forma de onda). Desde ahí puedes mostrar la ventana, iniciar/detener o salir.

Al cerrar Spectrum se guarda la cadena de plugins con su estado completo (curva del EQ, presets…), los dispositivos elegidos y si estaba en marcha. Al abrirlo de nuevo se restaura todo. La sesión vive en `~/Library/Application Support/Spectrum/session.plist`.

## Cómo funciona

- `SystemAudioTap` crea un *process tap* global estéreo (`CATapDescription`) que excluye al propio proceso de Spectrum, para que la señal procesada nunca se vuelva a capturar (sin realimentación). Con `muteBehavior = .mutedWhenTapped` el sistema silencia el audio original mientras el tap está activo.
- `AggregateDevice` construye un dispositivo agregado privado con el dispositivo de salida como reloj, más el tap (o el dispositivo de entrada elegido). Un solo dispositivo para entrada y salida = sin deriva entre relojes.
- `AudioEngineController` abre un `IOProc` sobre ese dispositivo y usa `AVAudioEngine` en modo de renderizado manual *realtime*: en cada callback, `RealtimeRenderer` deinterlea la entrada, renderiza la cadena `inputNode → mixer → [AU…] → mainMixer → outputNode` y escribe el resultado en los dos primeros canales de salida (los del dispositivo elegido). Latencia total ≈ un buffer + la latencia propia de los plugins.
- Los plugins se cargan en proceso con `AVAudioUnit.instantiate` y su interfaz se obtiene con `AUAudioUnit.requestViewController` (vista genérica como respaldo). La ventana sigue los cambios de tamaño del plugin.

## Diagnóstico desde terminal

```bash
.build/release/Spectrum --list                     # dispositivos y plugins AU instalados
.build/release/Spectrum --probe "pro-q"            # instancia un plugin y comprueba formato/UI/estado
.build/release/Spectrum --selftest <uidEntrada> <uidSalida> [--with-proq] [--tone]
```

`--selftest` arranca la cadena real durante dos segundos y reporta callbacks, canales y pico de salida. Con `--tone` sustituye la entrada por un tono a −34 dB para verificar el recorrido completo.

## Estructura

```
Sources/Spectrum/
  main.swift                      Entrada y modos de diagnóstico
  AppDelegate.swift               Menús, ciclo de vida, guardado de sesión
  Audio/AudioDevice.swift         Enumeración de dispositivos y helpers de Core Audio
  Audio/SystemAudioTap.swift      Process tap + dispositivo agregado
  Audio/RealtimeRenderer.swift    Puente IOProc ↔ AVAudioEngine (hilo de tiempo real)
  Audio/AudioEngineController.swift  Grafo, plugins, persistencia
  Audio/PluginCatalog.swift       Listado de AU
  Audio/PluginSlot.swift          Un plugin cargado + modelos de sesión
  UI/MainWindowController.swift   Panel de control
  UI/PluginPickerController.swift Selector de plugins con búsqueda
  UI/PluginWindowController.swift Ventana con la interfaz del plugin
Resources/Info.plist, AppIcon.icns
build.sh                          Compila y crea build/Spectrum.app
```
