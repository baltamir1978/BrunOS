# Notas y portapapeles

La cuarta app del dock (Cmd+4), pedida por Bruno el 24-sep-2026. **Escrita sin Xcode, sin
compilar ni probar.**

- `NotesStore`: notas de texto plano en `notes.json` de Application Support (con protección de
  fichero completa). La primera línea es el título. Se guarda un segundo después del último cambio
  y al irse a segundo plano. Todas las ventanas de Notas comparten el almacén (`didChange`).
- `NotesPane`: lista a la izquierda (Notas | Portapapeles) y la nota a la derecha. Fijar arriba,
  copiar y borrar con el botón derecho. «Nota nueva» también en el lanzador.
- **El editor es un `UITextView` que no edita**: maqueta y pinta, pero el cursor, la selección y
  el teclado los lleva el panel, porque en la escena externa nunca será primer respondedor. Las
  posiciones salen de su `UITextInput` (`caretRect`, `closestPosition`, `selectionRects`,
  `position(from:in:offset:)` para arriba y abajo, el `tokenizer` para líneas y palabras). El
  cursor parpadea con una animación de capa, sin temporizador. **Si algo de eso no funcionara sin
  ser primer respondedor, es lo primero que mirar.**
- Teclas: flechas (con Mayús seleccionan), Cmd+flechas (principio/final de línea y del texto),
  Inicio/Fin, ⌫, Supr, Cmd+⌫ (hasta el principio de la línea), Cmd+A, Cmd+C, Cmd+X, Cmd+V. Con
  el ratón: clic, arrastrar para seleccionar, Mayús+clic y doble clic para una palabra.

## El portapapeles (`ClipboardHistory`)

- **Sólo se apunta lo que BrunOS copia o pega**: todas las copias de la app pasan por
  `AppServices.shared.clipboard.copy(_:)` y los pegados por `readForPaste()`. **No escribir en
  `UIPasteboard.general` a pelo**, o no quedará en el historial.
- Leer lo que ha dejado **otra app** hace que iOS pregunte «¿Permitir pegar?» en la pantalla del
  iPhone, en negro con monitor. Por eso no se lee solo: `changeCount` (que no avisa) dice que hay
  algo nuevo, y sale un aviso en la lista para guardarlo al pulsar. Pegar con Cmd+V también lo
  apunta.
- **No se guarda en disco**: por ahí pasan contraseñas y tokens del terminal. 50 como mucho, se
  pierde al cerrar la app y se puede vaciar. La clave privada que se pega en Ajustes no entra.
