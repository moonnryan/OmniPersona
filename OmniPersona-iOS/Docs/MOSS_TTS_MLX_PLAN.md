# MOSS-TTS-Nano MLX Plan

Goal: device-side TTS for iPhone/iPad, with reference-audio cloning and preset
voices when no reference audio is selected.

Current app behavior:

- `TTSSettings.engine == .mossLocal` is the intended local MOSS-TTS mode.
- `TTSSettings.referenceAudioPath` takes priority for voice cloning.
- If no reference audio is present, `TTSSettings.presetVoice` chooses one of the
  built-in preset IDs:
  - `zh_female_warm`
  - `zh_male_calm`
  - `zh_child_bright`
  - `en_female_clear`
  - `en_male_story`
  - `ja_female_soft`
- When `mlx-audio-swift` is linked, `.mossLocal` loads
  `TTS.loadModel(modelRepo:)`, passes optional reference audio into
  `generatePCMBufferStream`, and plays generated PCM buffers with
  `MLXAudioCore.AudioPlayer`.
- If the MLX package is not linked, the model fails to load, or generation
  throws, the app falls back to `AVSpeechSynthesizer`.

Recommended integration path:

1. Resolve the `mlx-audio-swift` Swift Package in Xcode or via xcodebuild.
2. Download or bundle `mlx-community/MOSS-TTS-Nano-100M` metadata and weights.
3. Add UI for recording or importing reference audio into
   `TTSSettings.referenceAudioPath`.
4. Benchmark first-audio latency, tokens/s, RTF, memory pressure, and thermal
   behavior on target iPhone/iPad hardware.
5. Decide whether to keep ONNX Runtime as a CPU fallback for older devices.

The local reference repository at
`/Users/mac/Desktop/PyCharm_Workplace/tutor/MOSS-TTS-Nano` shows the Python
voice-clone flow. The iOS implementation should mirror that behavior but keep
Python/PyTorch out of the app binary.
