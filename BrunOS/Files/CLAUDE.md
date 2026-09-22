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
- Los ficheros pasan enteros por memoria (`read` devuelve `Data`): un vídeo de varios gigas por
  SFTP puede ser demasiado. Si da problemas, hay que pasar a lectura por trozos.
