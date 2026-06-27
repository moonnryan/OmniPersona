# OmniPersona

OmniPersona is a local-first, multi-platform assistant project. The current codebase contains the iOS client, with room reserved for Android and other clients under the same repository.

## Repository Layout

```text
OmniPersona/
  OmniPersona-iOS/      iPhone/iPad app
  README.md            project overview
  LICENSE
```

Future platform clients can live beside the iOS app, for example:

```text
OmniPersona-Android/
OmniPersona-Desktop/
```

## iOS App

The iOS app is a SwiftUI application focused on mobile LLM chat, model management, multimodal input, and TTS.

Main capabilities:

- Chat session management with per-conversation persona settings.
- Local GGUF model management for llama.cpp style inference.
- OpenAI-compatible remote model configuration.
- Image/video attachment flow for multimodal requests.
- System TTS, remote TTS endpoint support, and local MOSS-TTS-Nano integration.
- Lightweight app bundle policy: model weights are not bundled and should be downloaded or imported on device.

The iOS app lives in:

```text
OmniPersona-iOS/
```

Open it with Xcode:

```sh
open OmniPersona-iOS/OmniPersona.xcodeproj
```

For a no-signing build check:

```sh
cd OmniPersona-iOS
xcodebuild -project OmniPersona.xcodeproj \
  -scheme OmniPersona \
  -sdk iphoneos \
  -configuration Debug \
  -derivedDataPath ./DerivedData \
  build CODE_SIGNING_ALLOWED=NO
```

## Model Strategy

The repository intentionally avoids committing model weights and generated build artifacts.

Local LLM models:

- Add a Hugging Face or mirror repo ID in the app.
- Download a selected GGUF file on device.
- If a matching `mmproj` GGUF is available, the model can expose vision capability.
- Without `mmproj`, the app falls back to text-only capability.

TTS:

- System TTS works without additional weights.
- Remote TTS can target an HTTP endpoint.
- MOSS-TTS-Nano weights are downloaded separately on device.

## Git Hygiene

Do not commit:

- `DerivedData/`
- Xcode user state
- downloaded GGUF/model weights
- llama.cpp source/build trees
- generated XCFramework archives
- cache directories

The iOS project keeps only source code, project files, scripts, lightweight resources, and minimal third-party Swift sources required to build.

## Roadmap

- Stabilize the iOS local llama.cpp and OpenAI-compatible chat paths.
- Continue improving TTS latency and playback stability.
- Add Android as a sibling client while keeping shared architecture decisions documented here.
- Keep model files external to the repository so each platform can manage downloads independently.
