# Gestor de ficheros

## Fase 4 — Ficheros

**Empezada: local y vista previa.** Bruno eligió interfaz estilo Finder (barra lateral de
ubicaciones más lista) en lugar de los dos paneles de Total Commander.

- `FileProvider`: el protocolo que cumplirán por igual el iPhone, iCloud, el USB y SFTP. El panel
  no sabe con cuál habla, que es lo que permitirá copiar de uno a otro sin casos especiales.
- `LocalProvider`: el contenedor de la app, con la carpeta `Descargas` creada de antemano —una
  carpeta que aparece sola al usar el navegador desconcierta más que ayuda.
- `FilesPane`: **sin `UITableView` ni `UIButton`**, como todo lo de la pantalla externa. Flechas
  para moverse, Intro para abrir, Retroceso para subir, espaciadora para la vista previa.
- **Ubicaciones del iPhone**: iOS no deja recorrer el teléfono entero. Cualquier carpeta que se
  vea en la app Archivos (En mi iPhone, las de otras apps, iCloud, USB) se añade una vez con el
  selector del sistema, que **sólo puede salir en la pantalla del iPhone**.
- **La cabecera enseña el nombre de la carpeta**, como la barra de título del Finder. «Nombre» no
  sale: se ordena por nombre al volver a pulsar Tamaño o Fecha, o desde el botón derecho.
- **Tres vistas**: lista, iconos pequeños e iconos grandes, con el selector en la cabecera o desde
  el clic derecho. Se recuerda la elegida. En iconos, las flechas se mueven en rejilla y las
  imágenes **locales** llevan miniatura (por SFTP habría que descargar cada foto entera).
- **Un clic selecciona; doble clic abre** (22-sep-2026, lo pidió Bruno). Se reconoce en el panel:
  dos clics sobre el mismo elemento en menos de 0,5 s y sin moverse más de 6 puntos. El margen es
  más generoso que el de macOS porque los clics pasan por AssistiveTouch. Intro sigue abriendo, y
  la flecha de la cabecera sube un nivel. **Sin probar en el iPhone**: si el doble clic falla, lo
  primero es mirar cuánto tardan en llegar los dos clics.

### La vista previa NO usa QuickLook

Estaba previsto usar `QLPreviewController`, pero **está pensado para presentarse como pantalla
modal y espera toques del sistema**; en la pantalla externa no hay ni una cosa ni la otra. Se
escribió un visor propio (`QuickLookView`) que se dibuja como una vista más del escritorio y recibe
el ratón por donde lo recibe todo lo demás.

Cubre imágenes, **GIF animados** —hay que animarlos cuadro a cuadro con `ImageIO`, porque `UIImage`
sólo se queda con el primero—, vídeo y audio con `AVPlayerLayer`, PDF con `PDFKit` y texto. Lo que
no entiende lo dice, en vez de enseñar un rectángulo vacío. De los ficheros de texto se leen sólo
los primeros 200 KB: un log de medio giga colgaría la interfaz al maquetarlo entero.

### Orígenes

- `LocalProvider`: el contenedor de la app, con `Descargas`.
- `ExternalFolderProvider`: iCloud, carpetas de Archivos y el USB. **En iOS las tres son lo mismo**:
  no hay API de «montar un USB», hay carpetas a las que el usuario da permiso con el selector en
  modo carpeta. **El marcador de seguridad no es opcional**: sin él, el permiso se pierde al cerrar
  la app. Y cada acceso va entre `startAccessingSecurityScopedResource()` y su pareja; olvidar el
  cierre agota los permisos del sistema y acaban fallando todos.
- `SFTPProvider`: reutiliza los perfiles y la autenticación de la Fase 2, incluido `known_hosts`.
  Las máquinas SSH **aparecen solas** en la barra lateral: si ya están configuradas para el
  terminal, no tiene sentido darlas de alta otra vez.

Copiar y pegar funciona igual dentro de un origen que entre dos distintos, **local ↔ SFTP
incluido**: se lee de uno y se escribe en el otro (`FileService.transfer`).

- **Carpetas enteras**: primero se recorren para saber cuántos ficheros y bytes hay, y luego se
  recrean carpeta a carpeta. Barra de progreso abajo del panel, con Cancelar (se mira entre
  fichero y fichero; lo ya copiado se queda). Si el nombre existe, la copia se llama «copia»,
  como en el Finder.
- **Borrar una carpeta con cosas dentro** por SFTP fallaba: `rmdir` sólo borra vacías. Ahora
  `deleteRecursively` vacía antes.
- **Arrastrar**: a una carpeta de la lista, a una ubicación de la barra lateral o a otro panel de
  Ficheros. El panel de origen lo empieza (más de 6 puntos con el botón pulsado) y a partir de ahí
  el escritorio lleva un «fantasma» bajo el cursor, porque el arrastre puede acabar en otro panel.
  **Dentro del mismo origen se mueve, entre orígenes se copia**, como en el Finder.
- **Copiar va por trozos** (23-sep-2026): `download(_:to:)` y `upload(from:to:)` del protocolo,
  por un temporal en disco. SFTP en trozos de 256 KB, SMB con `downloadItem`/`uploadItem`, y los
  locales con `copyItem`, que no pasa por memoria. Antes un vídeo de varios gigas por SFTP se
  cargaba entero y iOS mataba la app. La vista previa también descarga así. `read` y `write`
  siguen para lo pequeño. Si uno de los dos es el propio iPhone no hay copia intermedia: un
  vídeo de 4 GB al servidor no necesita otros 4 GB libres.
- **Mover dentro de un origen** va por `move(_:to:)`, en el propio servidor o disco (SFTP
  `rename`, SMB `moveItem`); antes se bajaba y se volvía a subir todo. Si no se puede (SMB entre
  compartidas distintas), copia y borra.
- **La vista previa de lo remoto** se guarda en una carpeta por fichero y versión
  (`previewURL`: ruta, tamaño y fecha). Con sólo el nombre, dos `IMG_0001.jpg` de carpetas
  distintas se pisaban.

### Cada ventana con su ubicación, selección múltiple y progreso por bytes (24-sep-2026)

**Sin compilar ni probar** (escrito desde Linux, sin Xcode).

- **Todas las ventanas de Ficheros compartían ubicación**: miraban `FileService.currentProvider`,
  que es global. Con dos ventanas, cambiar de ubicación en una cambiaba lo que listaba la otra, y
  arrastrar de una a otra copiaba al sitio equivocado. Ahora cada `FilesPane` lleva la suya por
  clave (`locationKey`, resuelta con `FileService.provider(forKey:)`); `currentProvider` queda
  como «la última elegida», que es donde abre una ventana nueva. La vista previa recibe el origen.
- **Selección múltiple**, como en el Finder: Cmd+clic suma o quita, Mayús+clic coge el tramo,
  Mayús+flechas lo alarga, Cmd+A todo y un clic en el hueco la suelta. Copiar, cortar (Cmd+C,
  Cmd+X, Cmd+V), borrar (Cmd+⌫) y arrastrar van con todo lo seleccionado. Un clic sobre algo de la
  selección no la suelta hasta ver que no es un arrastre.
- **Los clics no traían modificadores**: con AssistiveTouch un clic es un toque, y el toque no sabe
  del teclado; todos llegaban con `[]`. Ahora `KeyboardRouter.heldModifiers` los lee con
  `GCKeyboard` (y si no hay, de las teclas que ha visto pasar), y `deliverPointer` los añade. Esto
  arregla también el Cmd+clic del navegador, que nunca funcionó.
- El portapapeles y `transfer` llevan varios elementos: **una sola barra para todo**. Lo copiado se
  puede pegar varias veces; lo cortado, una.
- **Progreso dentro de cada fichero**: un vídeo de 4 GB se quedaba en 0 % hasta el final. Va por un
  valor de tarea (`TransferProgress.report`) para no tocar el protocolo: SFTP informa a cada trozo
  y SMB con el aviso de AMSMB2 (se lee el valor antes, porque su aviso llega fuera de la tarea).
  `ProgressThrottle` deja pasar uno cada décima. Por un temporal (remoto → remoto), bajar es la
  primera mitad y subir la segunda. Los locales (`copyItem`) no informan.

### SMB: cliente propio con AMSMB2 (23-sep-2026)

**El SDK de iOS 27 no trae cliente SMB.** Comprobado: no hay NetFS ni nada equivalente. El 22-sep
se eligió pasar por la app Archivos (conectar allí y añadir la carpeta con el selector), sin
dependencias nuevas. **Bruno lo probó: funciona, pero conectarse así es demasiado complicado**, y
el 23-sep aprobó AMSMB2.

- `SMBServer` + `SMBServerStore` (en `smb-servers.json`) y la contraseña en el Keychain con
  `SMBKeychain`, sobre el mismo `PasswordVault` que las de SSH.
- `SMBProvider`: **las rutas empiezan por la compartida** (`/Fotos/2026/a.jpg`). Sin compartida
  en el alta, la raíz lista todas las del servidor (`listShares`, sin las ocultas con `$`). Una
  conexión (`SMB2Manager`) por compartida, porque cada una es su propio árbol. Tras un error de
  conexión se cierra y la siguiente petición abre otra; un «no existe» o un «sin permiso» no la
  tiran. **Dos peticiones a la vez a la misma compartida esperan a la misma conexión**
  (`connecting`): el actor no basta, porque entre mirar la caché y conectar hay un `await`.
- Espera 20 segundos a que conteste el servidor, no el minuto que trae AMSMB2.
- Alta y edición con `FormWindow`, que antes era el editor de máquinas SSH y ahora pinta
  cualquier `EditorForm`. Se puede pegar `smb://nas/Fotos` en el campo del servidor: al guardar se
  reparte entre servidor y compartida.
- `NSLocalNetworkUsageDescription` en el `Info.plist`: sin él iOS no deja hablar con la red local.
- **Cadena de suministro**: AMSMB2 es de Amir Abbas Mousavian desde siempre y trae libsmb2 copiada
  dentro, del propio autor de libsmb2 (Ronnie Sahlberg). Sus dependencias son sólo de Apple
  (swift-system para Linux, swift-atomics para los tests). LGPL 2.1, enlazada como librería
  dinámica. Fijada a la serie 4.0.

**Sin probar contra un servidor de verdad.**

La vía de la app Archivos sigue valiendo para lo ya montado allí: se añade con «Otra carpeta».

**De aquella vía quedó esto**: un servidor desmontado hace que el marcador de seguridad no
resuelva, y antes el proveedor ni se creaba, así que **la ubicación desaparecía de la barra
lateral** como si nunca se hubiera añadido. Ahora `ExternalFolderStore` guarda nombre y tipo junto
al marcador (`ExternalFolder`), el proveedor se crea igual y es `list` quien explica qué pasa; en
la barra lateral sale en gris. Los marcadores caducados (`isStale`) se renuevan solos al primer
acceso bueno, que es lo que evita tener que volver a añadir la carpeta tras un reinicio.

**Quitar ubicaciones** (24-sep-2026: se quedaban para siempre las que ya no respondían): botón
derecho en la barra lateral o Ajustes › Ubicaciones. Una carpeta se olvida (su marcador), un
servidor SMB se borra con su contraseña y una máquina SSH **sólo se esconde de Ficheros**
(`files.hiddenHosts`; sigue en el terminal y se vuelve a mostrar desde Ajustes). «Quitar las que no
responden» limpia de golpe las carpetas apagadas. `rebuild()` crea los proveedores de nuevo, así
que la ubicación que se está viendo se reconoce por `FileService.key(of:)`, no por el objeto ni
por el índice, que cambia al quitar una de más arriba.

El tipo se deduce de la ruta, que es lo único que da iOS: `smbclientd` → servidor,
`Mobile Documents` → iCloud, `/Volumes` → disco.

### SCP no aporta nada

Lo preguntó Bruno el 22-sep. Citadel ya da SFTP, que es el mismo canal SSH y permite listar,
renombrar y borrar; SCP sólo sabe copiar. Lo que faltaba era leer por trozos, y ya está.

### Barra lateral

180 puntos de ancho (antes 150) y los nombres con «…» al final: sin ancho, uno largo se salía y
quedaba cortado por el borde (Bruno, 24-sep-2026).

### iCloud y las nubes de Archivos: leer coordinado (24-sep-2026)

La vista previa de iCloud no funcionaba (Bruno): lo que no está bajado al iPhone es un marcador
sin contenido y `copyItem` no lo baja. `ExternalFolderProvider.coordinatedRead` lee con
`NSFileCoordinator`, como la app Archivos, y el sistema lo baja antes; lo usan `read` y
`download`, así que vale para la vista previa y para copiar, y para Google Drive u OneDrive
añadidos desde Archivos. Bloquea el hilo mientras baja: sólo desde las funciones `async`.
La vista previa dice «Bajando de iCloud… (tamaño)» mientras espera. **Sin progreso**: la lectura
coordinada no lo da. **Sin probar en el iPhone.**

**Ver un vídeo sin bajarlo entero no se puede en iCloud** con API pública: la única forma de
tener una dirección que AVFoundation pueda ir leyendo es `url(forPublishingUbiquitousItemAt:)`,
que **publica** un enlace que cualquiera con la dirección puede abrir. Por SFTP y SMB, sí: ver abajo.

### Vídeo por SFTP y SMB sin bajarlo entero (24-sep-2026)

`MediaStreamer` es un `AVAssetResourceLoaderDelegate`: el asset lleva una dirección
`brunos-stream://` que AVFoundation no conoce, así que le pregunta por cada rango de bytes y se lo
pide al servidor en trozos de 512 KB (`RangeReadableProvider.read(_:offset:length:)`: SFTP con
`file.read(from:length:)` de Citadel, SMB con `contents(atPath:range:)` de AMSMB2). Si el
reproductor cancela un rango (al saltar), se corta su tarea.

- **El asset sólo retiene al delegado débil**: `QuickLookView.streamer` lo guarda mientras se ve.
- **Comprobado en macOS** con un origen falso que sirve trozos de un fichero local con 20 ms de
  retraso: un vídeo de 91 MB empieza a los 0,5 s (11 MB leídos), el salto al minuto 1:30 tarda
  0,14 s y en total se leyeron 33 MB. **Sin probar contra un servidor de verdad ni en el iPhone.**
- En SFTP cada trozo abre y cierra el fichero: más idas y vueltas, pero sin estado que se quede
  colgado. Si va lento en la red de verdad, lo primero es mantenerlo abierto.

### Renombrar una ubicación

`FileService.rebuild()` avisa con `providersDidChange` y las barras laterales se repintan; antes
renombrar desde Ajustes no se veía hasta que otra cosa las repintaba.
