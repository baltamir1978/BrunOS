#import <AVFAudio/AVFAudio.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Puente a `installTapOnBus:bufferSize:format:error:block:`.
///
/// Existe por un fallo de importación del SDK de iOS 27. Apple marcó obsoleta
/// la variante sin `error:` y la sustituyó por ésta, pero **Swift sólo importa
/// la vieja**: el `error:` va en medio de la firma, Swift lo convierte en
/// `throws`, y `throws` no cuenta para distinguir sobrecargas. Las dos acaban
/// teniendo el mismo nombre y el mismo tipo, y la resolución se queda con la
/// obsoleta. Pasarle `error:` desde Swift da "extra arguments at positions
/// #4, #5", así que la nueva es sencillamente inalcanzable.
///
/// Desde Objective-C no hay ambigüedad. Este envoltorio la llama y la reexpone
/// a Swift con el `NSError **` al final, que es donde Swift sí sabe convertirlo
/// en `throws`.
///
/// Se gana algo más que quitar un aviso: **el error deja de perderse**. Con la
/// API vieja, si el tap no se instalaba no había forma de enterarse.
@interface BrunOSAudioTap : NSObject

+ (BOOL)installOnNode:(AVAudioNode *)node
                  bus:(AVAudioNodeBus)bus
           bufferSize:(AVAudioFrameCount)bufferSize
               format:(nullable AVAudioFormat *)format
                block:(void (^)(AVAudioPCMBuffer *buffer, AVAudioTime *when))block
                error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
