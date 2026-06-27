#import "OPLlamaBridge.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdocumentation"
#include <OmniLlamaMtmd/llama.h>
#include <OmniLlamaMtmd/mtmd.h>
#include <OmniLlamaMtmd/mtmd-helper.h>
#pragma clang diagnostic pop

#include <algorithm>
#include <string>
#include <vector>

namespace {

NSString * const OPLlamaErrorDomain = @"OPLlamaError";

void setNSError(NSError ** error, NSInteger code, NSString * message) {
    if (!error) return;
    *error = [NSError errorWithDomain:OPLlamaErrorDomain
                                 code:code
                             userInfo:@{NSLocalizedDescriptionKey: message}];
}

std::string tokenToPiece(const llama_vocab * vocab, llama_token token) {
    char stackBuf[256];
    int32_t n = llama_token_to_piece(vocab, token, stackBuf, sizeof(stackBuf), 0, true);
    if (n >= 0) {
        return std::string(stackBuf, static_cast<size_t>(n));
    }
    std::vector<char> buf(static_cast<size_t>(-n));
    n = llama_token_to_piece(vocab, token, buf.data(), static_cast<int32_t>(buf.size()), 0, true);
    if (n < 0) return std::string();
    return std::string(buf.data(), static_cast<size_t>(n));
}

std::string normalizedRole(NSString * role) {
    NSString * lower = role.lowercaseString ?: @"user";
    if ([lower isEqualToString:@"system"]) return "system";
    if ([lower isEqualToString:@"assistant"]) return "assistant";
    return "user";
}

std::string fallbackPrompt(
    const std::vector<std::string> & roles,
    const std::vector<std::string> & contents
) {
    std::string prompt;
    for (size_t i = 0; i < roles.size(); ++i) {
        if (roles[i] == "system") {
            prompt += "System: ";
        } else if (roles[i] == "assistant") {
            prompt += "Assistant: ";
        } else {
            prompt += "User: ";
        }
        prompt += contents[i];
        prompt += "\n";
    }
    prompt += "Assistant:";
    return prompt;
}

bool templateSupportsThinking(const char * tmpl) {
    if (!tmpl) return false;
    std::string source(tmpl);
    return source.find("enable_thinking") != std::string::npos;
}

std::string applyThinkingDirective(std::string prompt, const char * tmpl, bool enableThinking) {
    if (!templateSupportsThinking(tmpl)) {
        return prompt;
    }
    if (prompt.find("<think>") != std::string::npos) {
        return prompt;
    }
    prompt += enableThinking ? "<think>\n" : "<think>\n\n</think>\n\n";
    return prompt;
}

std::string buildPromptFromMessages(llama_model * model, NSArray<NSDictionary<NSString *, NSString *> *> * messages, bool enableThinking) {
    std::vector<std::string> roles;
    std::vector<std::string> contents;
    roles.reserve(messages.count);
    contents.reserve(messages.count);

    for (NSDictionary<NSString *, NSString *> * item in messages) {
        NSString * content = item[@"content"] ?: @"";
        if (content.length == 0) continue;
        roles.push_back(normalizedRole(item[@"role"] ?: @"user"));
        contents.push_back(std::string(content.UTF8String ?: ""));
    }

    if (roles.empty()) return "User: \nAssistant:";

    std::vector<llama_chat_message> chat;
    chat.reserve(roles.size());
    for (size_t i = 0; i < roles.size(); ++i) {
        llama_chat_message message;
        message.role = roles[i].c_str();
        message.content = contents[i].c_str();
        chat.push_back(message);
    }

    const char * tmpl = llama_model_chat_template(model, nullptr);
    int32_t required = llama_chat_apply_template(tmpl, chat.data(), chat.size(), true, nullptr, 0);
    if (required <= 0) {
        return fallbackPrompt(roles, contents);
    }

    std::vector<char> buffer(static_cast<size_t>(required) + 1);
    int32_t actual = llama_chat_apply_template(tmpl, chat.data(), chat.size(), true, buffer.data(), required + 1);
    if (actual <= 0) {
        return fallbackPrompt(roles, contents);
    }
    return applyThinkingDirective(std::string(buffer.data(), static_cast<size_t>(actual)), tmpl, enableThinking);
}

bool outputContainsStop(const std::string & output) {
    static const std::vector<std::string> stops = {
        "\nUser:", "\nAssistant:", "\n用户:", "\n用户：", "\n助手:", "\n助手：",
        "<|im_end|>", "<|endoftext|>", "</s>"
    };
    for (const std::string & stop : stops) {
        if (output.find(stop) != std::string::npos) return true;
    }
    return false;
}

bool appendTokenToOutput(
    const llama_vocab * vocab,
    llama_token token,
    std::string & output,
    OPLlamaTokenHandler tokenHandler
) {
    if (llama_vocab_is_eog(vocab, token)) return false;
    std::string piece = tokenToPiece(vocab, token);
    output += piece;
    if (tokenHandler && !piece.empty()) {
        NSString * tokenString = [[NSString alloc] initWithBytes:piece.data()
                                                          length:piece.size()
                                                        encoding:NSUTF8StringEncoding];
        if (tokenString.length > 0) {
            tokenHandler(tokenString);
        }
    }
    return !outputContainsStop(output);
}

void configureModelParams(llama_model_params & modelParams, int32_t nGpuLayers) {
    modelParams.n_gpu_layers = std::max<int32_t>(std::min<int32_t>(nGpuLayers, 99), 0);
    modelParams.use_mmap = true;
    modelParams.use_mlock = false;
}

void configureContextParams(llama_context_params & contextParams, int32_t nCtx, int32_t nThreads, int32_t nBatch, int32_t nUBatch) {
    int32_t safeBatch = std::max<int32_t>(std::min<int32_t>(nBatch, 1024), 32);
    int32_t safeUBatch = std::max<int32_t>(std::min<int32_t>(nUBatch, safeBatch), 16);
    contextParams.n_ctx = static_cast<uint32_t>(std::max<int32_t>(std::min<int32_t>(nCtx, 32768), 512));
    contextParams.n_batch = safeBatch;
    contextParams.n_ubatch = safeUBatch;
    contextParams.n_threads = std::max<int32_t>(std::min<int32_t>(nThreads, 8), 1);
    contextParams.n_threads_batch = std::max<int32_t>(std::min<int32_t>(nThreads, 8), 1);
    contextParams.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_AUTO;
}

llama_sampler * makeSampler(int32_t seed, float temperature, float topP) {
    llama_sampler_chain_params samplerParams = llama_sampler_chain_default_params();
    llama_sampler * sampler = llama_sampler_chain_init(samplerParams);
    llama_sampler_chain_add(sampler, llama_sampler_init_top_p(std::max(0.05f, std::min(topP, 1.0f)), 1));
    if (temperature > 0.0f) {
        llama_sampler_chain_add(sampler, llama_sampler_init_temp(temperature));
        llama_sampler_chain_add(sampler, llama_sampler_init_dist(seed == 0 ? LLAMA_DEFAULT_SEED : static_cast<uint32_t>(seed)));
    } else {
        llama_sampler_chain_add(sampler, llama_sampler_init_greedy());
    }
    return sampler;
}

} // namespace

@implementation OPLlamaBridge

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
                               error:(NSError **)error {
    return [self generateWithModelPath:modelPath
                              messages:messages
                                  seed:seed
                           temperature:temperature
                                  topP:topP
                             maxTokens:maxTokens
                                  nCtx:nCtx
                              nThreads:nThreads
                            nGpuLayers:nGpuLayers
                                nBatch:nBatch
                               nUBatch:nUBatch
                        enableThinking:enableThinking
                          tokenHandler:nil
                                 error:error];
}

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
                        tokenHandler:(OPLlamaTokenHandler)tokenHandler
                               error:(NSError **)error {
    if (modelPath.length == 0) {
        setNSError(error, 1, @"Missing GGUF model path.");
        return @"";
    }
    if (![[NSFileManager defaultManager] fileExistsAtPath:modelPath]) {
        setNSError(error, 2, [NSString stringWithFormat:@"Model file does not exist: %@", modelPath]);
        return @"";
    }

    llama_backend_init();

    llama_model_params modelParams = llama_model_default_params();
    configureModelParams(modelParams, nGpuLayers);

    llama_model * model = llama_model_load_from_file(modelPath.UTF8String, modelParams);
    if (!model) {
        setNSError(error, 3, @"llama_model_load_from_file failed.");
        return @"";
    }

    llama_context_params contextParams = llama_context_default_params();
    configureContextParams(contextParams, nCtx, nThreads, nBatch, nUBatch);

    llama_context * ctx = llama_init_from_model(model, contextParams);
    if (!ctx) {
        llama_model_free(model);
        setNSError(error, 4, @"llama_init_from_model failed.");
        return @"";
    }

    const llama_vocab * vocab = llama_model_get_vocab(model);
    std::string promptString = buildPromptFromMessages(model, messages ?: @[], enableThinking);

    int32_t nPrompt = -llama_tokenize(vocab, promptString.c_str(), static_cast<int32_t>(promptString.size()), nullptr, 0, true, true);
    if (nPrompt <= 0) {
        llama_free(ctx);
        llama_model_free(model);
        setNSError(error, 5, @"Prompt tokenization failed.");
        return @"";
    }

    std::vector<llama_token> tokens(static_cast<size_t>(nPrompt));
    int32_t actual = llama_tokenize(vocab, promptString.c_str(), static_cast<int32_t>(promptString.size()), tokens.data(), nPrompt, true, true);
    if (actual < 0) {
        llama_free(ctx);
        llama_model_free(model);
        setNSError(error, 6, @"Prompt tokenization buffer was too small.");
        return @"";
    }
    tokens.resize(static_cast<size_t>(actual));

    int32_t batchCapacity = std::max<int32_t>(std::min<int32_t>(nBatch, 1024), 32);
    llama_batch batch = llama_batch_init(batchCapacity, 0, 1);
    if (!batch.token) {
        llama_free(ctx);
        llama_model_free(model);
        setNSError(error, 7, @"llama_batch_init failed.");
        return @"";
    }

    int32_t pos = 0;
    for (size_t offset = 0; offset < tokens.size(); offset += static_cast<size_t>(batchCapacity)) {
        int32_t count = static_cast<int32_t>(std::min<size_t>(batchCapacity, tokens.size() - offset));
        batch.n_tokens = count;
        for (int32_t i = 0; i < count; ++i) {
            batch.token[i] = tokens[offset + static_cast<size_t>(i)];
            batch.pos[i] = pos++;
            batch.n_seq_id[i] = 1;
            batch.seq_id[i][0] = 0;
            batch.logits[i] = (i == count - 1) ? 1 : 0;
        }
        if (llama_decode(ctx, batch) != 0) {
            llama_batch_free(batch);
            llama_free(ctx);
            llama_model_free(model);
            setNSError(error, 8, @"llama_decode failed during prompt prefill.");
            return @"";
        }
    }

    llama_sampler * sampler = makeSampler(seed, temperature, topP);

    std::string output;
    int32_t limit = std::max<int32_t>(maxTokens, 1);
    for (int32_t i = 0; i < limit; ++i) {
        llama_token token = llama_sampler_sample(sampler, ctx, -1);
        llama_sampler_accept(sampler, token);
        if (!appendTokenToOutput(vocab, token, output, tokenHandler)) {
            break;
        }

        batch.n_tokens = 1;
        batch.token[0] = token;
        batch.pos[0] = pos++;
        batch.n_seq_id[0] = 1;
        batch.seq_id[0][0] = 0;
        batch.logits[0] = 1;
        if (llama_decode(ctx, batch) != 0) {
            break;
        }
    }

    llama_sampler_free(sampler);
    llama_batch_free(batch);
    llama_free(ctx);
    llama_model_free(model);

    return [[NSString alloc] initWithBytes:output.data()
                                    length:output.size()
                                  encoding:NSUTF8StringEncoding] ?: @"";
}

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
                        tokenHandler:(OPLlamaTokenHandler)tokenHandler
                               error:(NSError **)error {
    if (modelPath.length == 0) {
        setNSError(error, 1, @"Missing GGUF model path.");
        return @"";
    }
    if (mmprojPath.length == 0) {
        setNSError(error, 9, @"Missing mmproj GGUF path.");
        return @"";
    }
    if (![[NSFileManager defaultManager] fileExistsAtPath:modelPath]) {
        setNSError(error, 2, [NSString stringWithFormat:@"Model file does not exist: %@", modelPath]);
        return @"";
    }
    if (![[NSFileManager defaultManager] fileExistsAtPath:mmprojPath]) {
        setNSError(error, 10, [NSString stringWithFormat:@"mmproj file does not exist: %@", mmprojPath]);
        return @"";
    }
    if (imagePaths.count == 0) {
        return [self generateWithModelPath:modelPath
                                  messages:messages
                                      seed:seed
                               temperature:temperature
                                      topP:topP
                                      maxTokens:maxTokens
                                           nCtx:nCtx
                                       nThreads:nThreads
                                     nGpuLayers:nGpuLayers
                                         nBatch:nBatch
                                        nUBatch:nUBatch
                                 enableThinking:enableThinking
                                   tokenHandler:tokenHandler
                                          error:error];
    }

    llama_backend_init();

    llama_model_params modelParams = llama_model_default_params();
    configureModelParams(modelParams, nGpuLayers);

    llama_model * model = llama_model_load_from_file(modelPath.UTF8String, modelParams);
    if (!model) {
        setNSError(error, 3, @"llama_model_load_from_file failed.");
        return @"";
    }

    llama_context_params contextParams = llama_context_default_params();
    configureContextParams(contextParams, nCtx, nThreads, nBatch, nUBatch);

    llama_context * ctx = llama_init_from_model(model, contextParams);
    if (!ctx) {
        llama_model_free(model);
        setNSError(error, 4, @"llama_init_from_model failed.");
        return @"";
    }

    mtmd_context_params mtmdParams = mtmd_context_params_default();
    mtmdParams.use_gpu = true;
    mtmdParams.n_threads = std::max<int32_t>(nThreads, 1);
    mtmdParams.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_AUTO;
    mtmdParams.batch_max_tokens = std::max<int32_t>(std::min<int32_t>(nBatch, 1024), 32);

    mtmd_context * mtmd = mtmd_init_from_file(mmprojPath.UTF8String, model, mtmdParams);
    if (!mtmd) {
        llama_free(ctx);
        llama_model_free(model);
        setNSError(error, 11, @"mtmd_init_from_file failed.");
        return @"";
    }

    std::vector<mtmd_bitmap *> bitmaps;
    std::vector<mtmd_helper_video *> videos;
    bitmaps.reserve(imagePaths.count);
    for (NSString * path in imagePaths) {
        if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
            continue;
        }
        mtmd_helper_bitmap_wrapper wrapper = mtmd_helper_bitmap_init_from_file(mtmd, path.UTF8String, false);
        if (!wrapper.bitmap) {
            continue;
        }
        bitmaps.push_back(wrapper.bitmap);
        if (wrapper.video_ctx) {
            videos.push_back(wrapper.video_ctx);
        }
    }

    if (bitmaps.empty()) {
        for (mtmd_helper_video * video : videos) mtmd_helper_video_free(video);
        mtmd_free(mtmd);
        llama_free(ctx);
        llama_model_free(model);
        setNSError(error, 12, @"No image could be loaded by mtmd.");
        return @"";
    }

    std::string promptString = buildPromptFromMessages(model, messages ?: @[], enableThinking);
    mtmd_input_text text;
    text.text = promptString.c_str();
    text.add_special = true;
    text.parse_special = true;

    mtmd_input_chunks * chunks = mtmd_input_chunks_init();
    int32_t tokenized = mtmd_tokenize(mtmd, chunks, &text, const_cast<const mtmd_bitmap **>(bitmaps.data()), bitmaps.size());
    for (mtmd_bitmap * bitmap : bitmaps) mtmd_bitmap_free(bitmap);
    for (mtmd_helper_video * video : videos) mtmd_helper_video_free(video);

    if (tokenized != 0) {
        mtmd_input_chunks_free(chunks);
        mtmd_free(mtmd);
        llama_free(ctx);
        llama_model_free(model);
        setNSError(error, 13, [NSString stringWithFormat:@"mtmd_tokenize failed: %d", tokenized]);
        return @"";
    }

    llama_pos nPast = 0;
    size_t nChunks = mtmd_input_chunks_size(chunks);
    for (size_t i = 0; i < nChunks; ++i) {
        const mtmd_input_chunk * chunk = mtmd_input_chunks_get(chunks, i);
        llama_pos newNPast = nPast;
        int32_t decoded = mtmd_helper_eval_chunk_single(
            mtmd,
            ctx,
            chunk,
            nPast,
            0,
            std::max<int32_t>(std::min<int32_t>(nBatch, 1024), 32),
            i == nChunks - 1,
            &newNPast
        );
        if (decoded != 0) {
            mtmd_input_chunks_free(chunks);
            mtmd_free(mtmd);
            llama_free(ctx);
            llama_model_free(model);
            setNSError(error, 14, [NSString stringWithFormat:@"mtmd decode failed: %d", decoded]);
            return @"";
        }
        nPast = newNPast;
    }
    mtmd_input_chunks_free(chunks);

    const llama_vocab * vocab = llama_model_get_vocab(model);
    llama_batch batch = llama_batch_init(std::max<int32_t>(std::min<int32_t>(nBatch, 1024), 32), 0, 1);
    if (!batch.token) {
        mtmd_free(mtmd);
        llama_free(ctx);
        llama_model_free(model);
        setNSError(error, 7, @"llama_batch_init failed.");
        return @"";
    }

    llama_sampler * sampler = makeSampler(seed, temperature, topP);
    std::string output;
    int32_t limit = std::max<int32_t>(maxTokens, 1);
    for (int32_t i = 0; i < limit; ++i) {
        llama_token token = llama_sampler_sample(sampler, ctx, -1);
        llama_sampler_accept(sampler, token);
        if (!appendTokenToOutput(vocab, token, output, tokenHandler)) {
            break;
        }

        batch.n_tokens = 1;
        batch.token[0] = token;
        batch.pos[0] = nPast++;
        batch.n_seq_id[0] = 1;
        batch.seq_id[0][0] = 0;
        batch.logits[0] = 1;
        if (llama_decode(ctx, batch) != 0) {
            break;
        }
    }

    llama_sampler_free(sampler);
    llama_batch_free(batch);
    mtmd_free(mtmd);
    llama_free(ctx);
    llama_model_free(model);

    return [[NSString alloc] initWithBytes:output.data()
                                    length:output.size()
                                  encoding:NSUTF8StringEncoding] ?: @"";
}

@end
