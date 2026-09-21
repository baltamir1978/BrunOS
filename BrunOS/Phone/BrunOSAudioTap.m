#import "BrunOSAudioTap.h"

@implementation BrunOSAudioTap

+ (BOOL)installOnNode:(AVAudioNode *)node
                  bus:(AVAudioNodeBus)bus
           bufferSize:(AVAudioFrameCount)bufferSize
               format:(nullable AVAudioFormat *)format
                block:(void (^)(AVAudioPCMBuffer *buffer, AVAudioTime *when))block
                error:(NSError **)error {
    return [node installTapOnBus:bus
                      bufferSize:bufferSize
                          format:format
                           error:error
                           block:block];
}

@end
