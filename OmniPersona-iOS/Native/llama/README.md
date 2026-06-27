# llama.cpp Native Adapter

OmniPersona uses upstream `ggml-org/llama.cpp` release assets instead of a
checked-in submodule.

Run:

```bash
cd OmniPersona-iOS
Scripts/update_llama_xcframework.sh
```

The script installs:

```text
ThirdParty/llama/llama.xcframework
ThirdParty/llama/VERSION
```

The app currently keeps local inference behind `LocalLlamaService`. The native
bridge should remain isolated here so release upgrades only require:

1. Download the latest iOS XCFramework.
2. Rebuild.
3. Patch the small bridge if upstream `llama.h` / `mtmd.h` changed.

Do not commit the downloaded framework.
