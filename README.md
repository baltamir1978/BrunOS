<div align="center">

<img src="brunos-icon.svg" width="128" alt="">

# brunOS\_

**Un escritorio en el monitor, servido por el iPhone.**

</div>

BrunOS convierte un iPhone en un ordenador de sobremesa: conectas un monitor, una tele o un
proyector por USB-C, emparejas ratón y teclado Bluetooth, y trabajas en una pantalla de verdad.

No es duplicar la pantalla del teléfono. BrunOS **dibuja directamente en la pantalla externa a su
resolución nativa**, con su propio escritorio de ventanas en mosaico, sin bandas negras y sin la
silueta de un iPhone en mitad del monitor. El teléfono se queda de mando: trackpad de emergencia,
teclado en pantalla, dictado y ajustes.

Es un proyecto personal. No está en la App Store ni va a estarlo.

## Funciones

| | Estado |
| --- | --- |
| **Pantalla externa** a resolución nativa, con escalas 1×–3×, overscan y perfiles por monitor | 🚧 Fase 1 |
| **Ratón y teclado** Bluetooth, cursor propio y atajos de ventanas | 🚧 Fase 1 |
| **Escritorio** en mosaico estilo i3, con 3 espacios de trabajo | 🚧 Fase 1 |
| **Terminal SSH** a través de Tailscale, con tmux y ratón | 🚧 Fase 2 |
| **Navegador** con pestañas y bloqueo de anuncios | 🚧 Fase 3 |
| **Gestor de ficheros**: iPhone, iCloud Drive, USB y SFTP | 🚧 Fase 4 |

Ahora mismo va por la **Fase 0**: el esqueleto compila, arranca y registra el accesorio de escena
externa de iOS 27.

## Requisitos

- **iPhone 15 o posterior con USB-C.** Los modelos **e** y el **Air** no valen.
- **iOS 27** o posterior.
- Un monitor, tele o proyector por USB-C, y ratón y teclado Bluetooth.
- **AssistiveTouch activado**: en el iPhone el ratón Bluetooth sólo funciona con él encendido, y
  ninguna app puede activarlo por API. BrunOS trae un asistente que guía para automatizarlo con
  Atajos.

## Compilar

Hace falta Xcode 27 y [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
brew install xcodegen
xcodebuild -downloadComponent MetalToolchain   # lo pide SwiftTerm y no viene con Xcode
./Tools/build.sh
```

El `.xcodeproj` **no está versionado**: lo genera XcodeGen desde `project.yml`. El equipo de firma
se configura en Xcode; `DEVELOPMENT_TEAM` se deja vacío a propósito para no meter datos de la
cuenta de desarrollador en un repositorio público.

## Limitaciones conocidas

Son de iOS, no del programa, y no hay intención de pelearse con ellas:

- **No se pueden mostrar otras apps de iOS** en la pantalla externa. Sólo BrunOS.
- **En segundo plano, iOS vuelve a duplicar la pantalla.** La app tiene que quedarse delante.
- **El círculo del puntero de AssistiveTouch no se puede ocultar.**
- **Los clics sintéticos no entran en iframes de otro dominio** (avisos de cookies, pasarelas de
  pago, logins de terceros). Para eso está "Traer ventana": la página se muestra en el iPhone para
  tocarla con el dedo y vuelve al monitor.
- **El contenido con DRM puede salir en negro** en la salida externa.

## Licencia

El código de BrunOS es [MIT](LICENSE).

Software de terceros:

- [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) — MIT
- [Citadel](https://github.com/orlandos-nl/Citadel) — MIT
- [JetBrains Mono](https://github.com/JetBrains/JetBrainsMono) — SIL Open Font License 1.1
- [IBM Plex Sans](https://github.com/IBM/plex) — SIL Open Font License 1.1

Las listas de bloqueo **EasyList** y **EasyPrivacy** tienen licencia propia y **no se redistribuyen
en este repositorio**: un script de `Tools/` las descarga y las convierte en local, y lo generado
está en `.gitignore`.
