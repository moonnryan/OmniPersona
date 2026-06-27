# OmniPersona

OmniPersona is a clean iOS/iPadOS SwiftUI app for local-first multimodal chat.

Implemented foundation:

- OpenAI-compatible remote and LAN streaming chat.
- Local llama.cpp backend slot using upstream release XCFrameworks.
- GGUF repo parsing from `hf-mirror.com`.
- Conversation management and persistent settings.
- Images/videos as chat attachments.
- TTS settings with off / remote / local MOSS modes.
- MOSS-TTS preset voices plus reference-audio-first cloning configuration.
- Persona avatar/background configuration.

Open the project:

```bash
open OmniPersona.xcodeproj
```

Update llama.cpp XCFramework:

```bash
Scripts/update_llama_xcframework.sh
```

List GGUF files:

```bash
Scripts/download_hf_gguf.sh mradermacher/Qwen3.5-4B-MiniFantasy-GGUF
```
