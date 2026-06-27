# OmniPersona iOS

OmniPersona is a local-first iOS/iPadOS SwiftUI chat app for multimodal model testing, persona-driven conversations, and optional TTS playback.

The app is designed to stay lightweight: model weights, downloaded GGUF files, MOSS-TTS weights, user media, and generated runtime data are not bundled in the app target.

## Features

- Conversation management with editable persona cards, avatar, and chat background media.
- OpenAI-compatible streaming chat for LAN or remote endpoints.
- Local llama.cpp backend slot with Metal-capable iOS XCFramework integration.
- GGUF model discovery and download flow for local model management.
- Text and image/video attachments in chat.
- Optional TTS with system speech, remote interface, and local MOSS-TTS modes.
- MOSS-TTS preset voices, reference audio selection, and saved cloned voice records.
- Runtime model loading/offloading controls from the chat screen.

## Project Layout

```text
OmniPersona-iOS/
  OmniPersona.xcodeproj
  OmniPersona/
    Models/          App data models
    Services/        LLM, TTS, download, persistence, and bridge services
    Views/           SwiftUI screens and reusable UI
    Native/          Objective-C++ bridge code for native inference
    Resources/       Small app assets and preset reference audio
  Scripts/           llama.cpp XCFramework and model helper scripts
  ThirdParty/        Lightweight dependency notes or restored local frameworks
```

## Requirements

- Xcode 26 or newer
- iOS/iPadOS 17 or newer deployment target
- Apple Silicon Mac recommended for local framework builds
- CMake when rebuilding llama.cpp or mtmd frameworks locally

## Setup

Open the project:

```bash
open OmniPersona.xcodeproj
```

Resolve Swift package dependencies:

```bash
xcodebuild -resolvePackageDependencies -project OmniPersona.xcodeproj
```

Build without signing:

```bash
xcodebuild \
  -project OmniPersona.xcodeproj \
  -scheme OmniPersona \
  -sdk iphoneos \
  -configuration Debug \
  -derivedDataPath ./DerivedData \
  build CODE_SIGNING_ALLOWED=NO
```

For device testing, open the project in Xcode, select your development team, then run the `OmniPersona` scheme on the iPhone or iPad.

## Local llama.cpp

The app expects native inference frameworks to be restored or rebuilt outside of Git-tracked model data.

Update the upstream llama.cpp iOS XCFramework:

```bash
Scripts/update_llama_xcframework.sh
```

Build the mtmd helper framework when multimodal local inference needs it:

```bash
Scripts/build_llama_mtmd_xcframework.sh
```

The app should only package inference frameworks and small bridge files. GGUF weights are downloaded later on-device through model management.

## Model Downloads

The GGUF helper can inspect a model repository and list downloadable files:

```bash
Scripts/download_hf_gguf.sh unsloth/Qwen3.5-0.8B-GGUF
```

The app model manager is intended to download one selected LLM GGUF and, when available, one matching `mmproj` GGUF. If no `mmproj` is present, local inference falls back to text-only capability.

## TTS

Supported TTS modes:

- System speech through `AVSpeechSynthesizer`.
- Remote TTS interface for LAN or cloud services.
- Local MOSS-TTS-Nano through the Swift/MLX runtime path.

MOSS-TTS model weights are not bundled. They are downloaded or removed from inside the app. Preset reference audio files are intentionally small and live in app resources.

## Lightweight Repository Policy

Do not commit:

- `DerivedData/`
- downloaded GGUF, safetensors, ONNX, or MLX weight folders
- user-uploaded media
- generated app container data
- large rebuilt framework artifacts unless explicitly required for a release package

Keep the repository close to source code plus small assets. Release artifacts and model weights should be restored by scripts or downloaded at runtime.

