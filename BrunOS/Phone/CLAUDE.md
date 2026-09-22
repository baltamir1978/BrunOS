# Interfaz del iPhone

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
