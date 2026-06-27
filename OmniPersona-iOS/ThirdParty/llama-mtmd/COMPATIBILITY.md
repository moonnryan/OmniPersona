# OmniLlamaMtmd Compatibility

Built from ggml-org/llama.cpp b9789.

Keep this framework version-paired with the app's llama.cpp headers and runtime.
When ThirdParty/llama/llama.xcframework is updated to a new release tag, rebuild
this framework with the same RELEASE_TAG.

Recommended update sequence:

1. Scripts/update_llama_xcframework.sh
2. Scripts/build_llama_mtmd_xcframework.sh
3. Rebuild the iOS app and run a text + multimodal smoke test.
