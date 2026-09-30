# Ratón y teclado

## La regla del ratón: manda `GCMouse`

**Decisión de Bruno, para siempre** (24-sep-2026): `GCMouse` delante; el puntero indirecto de
AssistiveTouch sólo si no hay `GCMouse` (`MouseRouter.preferred`). Se probaron las dos:

- Con `GCMouse` delante (build 2609241727) el cursor iba suave y llegaba a los bordes.
- Con el indirecto delante (2609241832) iba errático y seguía las esquinas redondeadas del iPhone:
  es la posición del puntero de iOS, que no entra en ellas ni en el 6 % de arriba (la isla).

No darle más vueltas sin datos nuevos. El punto 5 de la 0.2.0 es afinar **aceleración, curva y
rueda** sin cambiar la fuente.

- **Movimiento**: sólo el de la fuente activa, para no mover el cursor al doble.
- **Rueda**: preferencia propia, `GCMouse` si la entrega (el sentido que Bruno confirmó); la del
  indirecto sólo si `GCMouse` lleva medio segundo sin dar rueda.
- **Botones**: pasan siempre, vengan de donde vengan. Un clic duplicado es un incordio; uno
  perdido deja la app inservible.
- **Indirecto como reserva**: va en absoluto (posición 0…1, el borde del iPhone es el del
  monitor), con el vertical estirado desde lo más alto que alcanza (`topReach`). La velocidad la
  pone iOS (Accesibilidad › Control del puntero). Sensibilidad y aceleración de BrunOS son para
  `GCMouse` y el trackpad táctil (`PointerController.move(by:)`, de 1× a 3,5×).
- **Diagnóstico** (Ajustes › Ratón y teclado): fuente activa, eventos por segundo de cada una y
  alcance del indirecto en cada eje. Es lo primero que hay que pedirle a Bruno si algo falla.

## El toque de AssistiveTouch es el botón

Con AssistiveTouch, el botón izquierdo llega como **un toque en la pantalla del iPhone** donde
esté el puntero, y mantenerlo mientras se mueve es un dedo que se desliza. En modo mando,
`TrackpadUIView` lo trata como el ratón: al tocar, botón pulsado **donde ya está el cursor**; al
mover, el cursor se desplaza lo mismo que el toque; al soltar, botón suelto.

- **La posición del toque no es fiable; su desplazamiento, sí.** Colocar el cursor en el punto del
  toque lo hacía saltar en cada clic.
- Si el toque es el ratón lo decide `pointerEverWorked` (`isMouseSession`), que no se apaga.
  `isPointerWorking` se apaga a los 3 s sin movimiento, y el toque se tomaba entonces por un dedo.
- Mientras el botón está pulsado se ignoran las posiciones del indirecto (también llegan durante
  un arrastre). El botón se suelta al dejar de estar activa la app y cuando la vista del trackpad
  sale de la ventana: si no, `isHoldingButton` se quedaba en `true` al volver de Atajos.

## AssistiveTouch: un solo criterio

`isAssistiveTouchRunning` no es fiable con AssistiveTouch puesto sólo para el puntero, y
`GCMouse` tampoco ve el ratón en ese caso. **En la interfaz, siempre
`AssistiveTouchMonitor.isActive` y `mouseDetected`**, que dan por bueno lo que diga iOS o que
lleguen eventos del puntero. Nunca `isRunning` o `hasMouse` a pelo.

- Los eventos se detectan también sobre las hojas del iPhone (`onContinuousHover`): el puntero no
  pasa por la vista raíz con una hoja delante.
- «Ratón conectado» se baja con `pointerMaybeGone()` si 3 s después de acabar el hover no ha
  llegado nada (el hover también acaba un instante con cada clic).
- `notePointerEvent()` sólo asigna si cambia: se llama en cada movimiento, y asignar el mismo
  valor repintaba la interfaz del iPhone a cada fotograma.

## Teclado

La escena externa no es interactiva: **todo el teclado entra por el first responder del iPhone**
(`KeyboardRouter`) y se reenvía a mano.

- Lo que lleva Cmd se mira en la tabla de atajos (`Shortcuts`, un solo sitio, de donde salen los
  `UIKeyCommand` y la ayuda). **Ctrl y Option no se tocan nunca**: son del terminal.
- Cmd+C y Cmd+V tienen que estar en la tabla: sin declararlos, el terminal mandaba una «c».
- iOS se reserva Cmd+Tab, Cmd+Espacio y Cmd+H.
- Con un campo de texto activo en el iPhone, el router no toca nada.
- **El puntero no trae modificadores** (un clic de AssistiveTouch es un toque): los clics con
  Cmd o Mayús leen `KeyboardRouter.heldModifiers`, que pregunta a `GCKeyboard`.
- Si un atajo cambia, cambiarlo también en la ayuda de la página de inicio
  (`BrowserTab.helpHTML()`).
