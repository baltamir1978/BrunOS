# Interfaz del iPhone

Sin monitor, la interfaz del iPhone es la app entera (SwiftUI dentro de
`PhoneRootViewController`, que es UIKit porque `registerSceneAccessory(_:)` es de
`UIViewController`). Con monitor, el iPhone queda de mando.

## Con monitor, el iPhone en negro (`RemoteModeView`)

Con AssistiveTouch, el clic izquierdo es **un toque en la pantalla del iPhone** donde esté el
puntero: si ahí había un botón de la interfaz del teléfono, se pulsaba ése y el escritorio ni se
enteraba (el diagnóstico lo dio Bruno). Así que con monitor el teléfono queda en negro, como
trackpad y nada más; el aviso de entrada se va a los 6 s y no acepta toques.

- **Por eso los ajustes, el alta de máquinas y de servidores viven en el monitor**
  (`SettingsWindow`, `FormWindow`).
- El trackpad y `RemoteModeView` van en negro fijo: con `Tokens.Color.background`, en modo claro
  salía casi blanco (el «iPhone en blanco»).
- **Al conectar** se cierra lo que haya presentado en el iPhone (salvo el selector de carpetas o
  de favoritos, que se piden desde el monitor) y se recupera el first responder del teclado.
- **Al desconectar**: `ExternalDisplayManager` es `@Observable` (si no, nada repintaba el
  iPhone), y `PhoneRootViewController.updateProperties()` mira también
  `UISceneAccessoryRegistration.isAvailable`, porque iOS puede tardar en llamar a
  `sceneDidDisconnect`. `detach()` aguanta que le lleguen las dos.
- **Al volver de otra app** (Atajos, para Tailscale), iOS puede reutilizar la escena externa sin
  llamar a `scene(_:willConnectTo:)`: `ExternalSceneDelegate.reattachIfNeeded()` vuelve a
  enganchar monitor y cursor si no hay ninguno, al volver al frente y cuando el accesorio vuelve a
  estar disponible. `EventLog` (Ajustes › Rendimiento) guarda lo último que pasó: sin Modo de
  desarrollador no hay log ni informes de fallo.
- **Los bordes, de la app** (30-sep-2026): el puntero de AssistiveTouch se para en los bordes del
  iPhone y el clic cae ahí. En modo mando `PhoneRootViewController` esconde la barra de estado y el
  indicador de inicio y aplaza los gestos de todos los bordes (`preferredScreenEdgesDeferring
  SystemGestures`), para que un clic arrastrado no abra el Centro de Control ni mande a Inicio.
  Se recalcula en `externalDisplayChanged`. El botón de AssistiveTouch no lo puede esconder la
  app: lo hace Bruno con «Mostrar siempre el menú» apagado (explicado en Ajustes › Ratón y
  teclado).
- **Bloquear el puntero** (`prefersPointerLocked`, interruptor de prueba en Ajustes › Ratón y
  teclado, con el estado que da `pointerLockState`): en iPhone casi seguro que iOS no lo acepta
  (Jump Desktop no lo ofrece en iPhone). Si lo aceptara, el ratón llegaría sólo por `GCMouse`.
- **Atenuar**: brillo al mínimo (`ScreenDimmer`) y un velo que no recibe toques; el brillo se
  devuelve al salir de la app.
- **Selectores del iPhone**: un solo `fileImporter` que cambia de tipo (`PickerKind`: carpetas o
  favoritos), porque SwiftUI sólo atiende uno por vista.

## El único puente a Objective-C del proyecto

`AVAudioNode.installTap(onBus:bufferSize:format:block:)` quedó obsoleta en iOS 27 en favor de
`installTapOnBus:bufferSize:format:error:block:`. **Esa sustituta no se puede llamar desde Swift**
en el SDK 27: el `error:` va en medio de la firma, Swift lo convierte en `throws`, y `throws` no
cuenta para distinguir sobrecargas. Las dos acaban con el mismo nombre y el mismo tipo, y la
resolución se queda con la obsoleta. Comprobado compilando contra `iphoneos27.0`: pasarle `error:`
da *"extra arguments at positions #4, #5"*.

**Desde Objective-C no hay ambigüedad**, y eso sí está comprobado compilando un `.m` de prueba. De
ahí `BrunOS/Phone/BrunOSAudioTap.{h,m}` y el bridging header en `BrunOS/App/`, que es **lo único
de Objective-C que hay en BrunOS**. Reexpone el método con el `NSError **` al final, que es donde
Swift sí lo convierte en `throws`.

Se gana algo más que quitar un aviso: **el error deja de perderse**. Con la API vieja, un tap que
no se instalaba fallaba en silencio.

Si algún día Apple arregla la importación, se borran los dos ficheros y la línea
`SWIFT_OBJC_BRIDGING_HEADER` de `project.yml`, y se llama a la API directamente.
