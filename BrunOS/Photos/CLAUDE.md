# Fotos

La quinta app del dock (Cmd+5), pedida por Bruno el 24-sep-2026: **un visor de imágenes y un
reproductor de vídeo basados en una carpeta**, con un icono parecido al de Fotos de macOS.
**Escrita desde Linux; compila sin cambios en el Mac. Sin probar en el iPhone.**

- **`PhotosPane`**: la rejilla de una carpeta de **cualquier ubicación de Ficheros** (iPhone,
  iCloud, USB, SFTP, SMB). Primero las subcarpetas, luego fotos y vídeos, por nombre. Doble clic o
  Intro abre; Retroceso o la flecha de la cabecera sube; la píldora de la derecha de la cabecera
  cambia de ubicación. Cada ventana lleva su ubicación por clave (`FileService.key(of:)`), como
  Ficheros, y se recuerda al arrancar (`location`/`path` de `SavedDesktop.Window`).
- **Desde Ficheros**, botón derecho: «Abrir en Fotos» sobre una carpeta, una foto o un vídeo (se
  abre ya en el visor), y «Ver esta carpeta en Fotos» en el hueco.
- **Miniaturas** con ImageIO a los píxeles del cuadro, nunca la foto entera, en un `NSCache` de
  60 MB. Por SFTP/SMB cada miniatura es bajar la foto (a la caché de `previewURL`), así que van
  **3 a la vez**, sólo las que se ven, y nada de más de 60 MB. Los vídeos: un fotograma con
  `AVAssetImageGenerator`, en local del fichero y en SFTP/SMB por trozos con `MediaStreamer`; de
  iCloud no (habría que copiar el vídeo entero).
- **`PhotoViewer`**: foto sobre negro, decodificada al tamaño de la pantalla (una de 48 MP entera
  son 200 MB), GIF animados, y vídeo con `AVPlayerLayer` y barra propia (`PlayerBar`:
  reproducir, tiempo, línea para saltar, sonido). Por SFTP/SMB el vídeo se ve mientras llega.
  ← → o los lados pasan de foto; Mayús+← → salta 10 s; espacio pausa; M silencia; Esc vuelve.
- **Pase de diapositivas** (botón de la cabecera): fotos 4 s, vídeos hasta que terminan, y da la
  vuelta al llegar al final.
- **El icono** (`DockIcon.drawPhotos`) es una flor de ocho pétalos de colores en multiplicar,
  dibujada por código: el de Apple no se puede copiar. Se comprobó pintándolo igual en un canvas.

**Lo menos seguro sin compilar**: la miniatura de vídeo por `MediaStreamer` (si
`AVAssetImageGenerator` no tira del cargador propio, sale el icono de película) y que los
controles del vídeo respondan en el monitor.
