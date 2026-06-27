#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^OPLlamaTokenHandler)(NSString * token);

@interface OPLlamaBridge : NSObject

- (NSString *)generateWithModelPath:(NSString *)modelPath
                            messages:(NSArray<NSDictionary<NSString *, NSString *> *> *)messages
                                seed:(int32_t)seed
                         temperature:(float)temperature
                                topP:(float)topP
                           maxTokens:(int32_t)maxTokens
                                nCtx:(int32_t)nCtx
                            nThreads:(int32_t)nThreads
                          nGpuLayers:(int32_t)nGpuLayers
                              nBatch:(int32_t)nBatch
                             nUBatch:(int32_t)nUBatch
                      enableThinking:(BOOL)enableThinking
                               error:(NSError * _Nullable * _Nullable)error;

- (NSString *)generateWithModelPath:(NSString *)modelPath
                            messages:(NSArray<NSDictionary<NSString *, NSString *> *> *)messages
                                seed:(int32_t)seed
                         temperature:(float)temperature
                                topP:(float)topP
                           maxTokens:(int32_t)maxTokens
                                nCtx:(int32_t)nCtx
                            nThreads:(int32_t)nThreads
                          nGpuLayers:(int32_t)nGpuLayers
                              nBatch:(int32_t)nBatch
                             nUBatch:(int32_t)nUBatch
                      enableThinking:(BOOL)enableThinking
                        tokenHandler:(OPLlamaTokenHandler _Nullable)tokenHandler
                               error:(NSError * _Nullable * _Nullable)error;

- (NSString *)generateWithModelPath:(NSString *)modelPath
                          mmprojPath:(NSString *)mmprojPath
                            messages:(NSArray<NSDictionary<NSString *, NSString *> *> *)messages
                          imagePaths:(NSArray<NSString *> *)imagePaths
                                seed:(int32_t)seed
                         temperature:(float)temperature
                                topP:(float)topP
                           maxTokens:(int32_t)maxTokens
                                nCtx:(int32_t)nCtx
                            nThreads:(int32_t)nThreads
                          nGpuLayers:(int32_t)nGpuLayers
                              nBatch:(int32_t)nBatch
                             nUBatch:(int32_t)nUBatch
                      enableThinking:(BOOL)enableThinking
                        tokenHandler:(OPLlamaTokenHandler _Nullable)tokenHandler
                               error:(NSError * _Nullable * _Nullable)error;

@end

NS_ASSUME_NONNULL_END
