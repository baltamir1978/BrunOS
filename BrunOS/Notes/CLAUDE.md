# Notas y portapapeles

La cuarta app del dock (Cmd+4), pedida por Bruno el 24-sep-2026. Escrita en la nube, compilada en
el Mac y vista funcionando en el iPhone; el RTF y el formato, del 24-sep por la noche, **sin probar
en el iPhone**.

- `NotesStore`: **cada nota es un `.rtf` en `Documentos/Notas`** (24-sep-2026, lo pidió Bruno):
  se ve desde la app Archivos y desde Ficheros, y lo abre cualquier editor. Lo que el RTF no
  guarda (el id y si está fijada) va en `notes-index.json` de Application Support. Un `.rtf` o un
  `.txt` dejado en la carpeta sale como nota (un `.txt` se queda `.txt` mientras no lleve formato);
  se relee al volver a la app (`refreshFromDisk`). El fichero se llama como el título y se
  renombra con él. Las notas de antes (`notes.json`) se pasan a ficheros la primera vez, y el JSON
  se queda como `notes.json.migrado`. La primera línea es el título. Se guarda un segundo después
  del último cambio y al irse a segundo plano. Todas las ventanas de Notas comparten el almacén.
  **Comprobado en el simulador de iOS**: migración con el fijado, negrita y enlace tras releer,
  renombrado y un `.txt` de fuera con el mismo id al releer.
- **Texto enriquecido**: negrita, cursiva y subrayado (Cmd+B, Cmd+I, Cmd+U, y en el botón
  derecho), sobre lo seleccionado o para lo que se escriba. **Enlaces**: las direcciones se
  vuelven enlace solas en el párrafo que se escribe (`NSDataDetector`); Cmd+K pone uno a mano;
  un clic lo abre en el navegador (con Mayús, no, para poder seleccionar). **Helvetica Neue**, no
  IBM Plex: Plex no trae cursiva, y Helvetica la abre cualquier editor de RTF. **Los colores no se
  guardan** (`NoteStyle.stripped`): el del texto lo pone el modo claro u oscuro al enseñarlo.
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

**Visto funcionando en el iPhone** por Bruno el 24-sep-2026, en la 2609241157.
