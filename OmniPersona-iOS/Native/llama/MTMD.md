# MTMD Build Strategy

The upstream `ggml-org/llama.cpp` release currently ships a standard
`llama.xcframework` for iOS. The scanned releases do not expose a separate
`mtmd` / multimodal / `mmproj` iOS XCFramework asset.

OmniPersona therefore uses two lanes:

1. `ThirdParty/llama/llama.xcframework`
   - downloaded from upstream releases
   - used for stable text GGUF inference
   - updated by `Scripts/update_llama_xcframework.sh`

2. `ThirdParty/llama-mtmd/OmniLlamaMtmd.xcframework`
   - custom-built from the same llama.cpp tag
   - includes `mtmd.h` and the static libraries needed by local multimodal
   - built by `Scripts/build_llama_mtmd_xcframework.sh`

Do not treat a stale `OmniLlamaMtmd.xcframework` as compatible with every
future upstream `llama.xcframework`. `mtmd` and `llama.h` can change together,
so the safe rule is version-pairing: update both from the same llama.cpp tag.

If the app links both frameworks, keep the native bridge boundaries explicit:
text inference can use the upstream `llama.xcframework`, while local multimodal
can use the `OmniLlamaMtmd` bridge. A later cleanup can move text inference to
`OmniLlamaMtmd` as well so only one llama runtime is loaded.
