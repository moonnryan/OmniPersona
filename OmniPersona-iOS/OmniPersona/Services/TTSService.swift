import AVFoundation
import Foundation

#if canImport(HuggingFace)
import HuggingFace
#endif

#if canImport(MLXAudioTTS) && canImport(MLXAudioCore) && canImport(MLX)
@preconcurrency import MLX
import MLXAudioCore
import MLXAudioTTS
#endif

@MainActor
final class TTSService {
    private let synthesizer = AVSpeechSynthesizer()
    private var mossPlaybackPlayer: AVAudioPlayer?
    private var presetSynthesizers: [String: AVSpeechSynthesizer] = [:]
    var onStatus: ((String) -> Void)?
#if canImport(MLXAudioTTS) && canImport(MLXAudioCore) && canImport(MLX)
    private let mlxAudioPlayer = AudioPlayer()
    private let mossGenerator = MossTTSGenerator()
    private var mossPlaybackGeneration = UUID()
    private var isMossBusy = false
    private var presetReferenceCache: [String: MLXArray] = [:]
#endif

    func speak(_ text: String, settings: TTSSettings, waitUntilFinished: Bool = false) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, settings.engine != .off else { return }

        switch settings.engine {
        case .off:
            stopSpeaking()
            return
        case .system:
            stopMossPlayback()
            speakSystemFallback(trimmed, settings: settings)
            if waitUntilFinished {
                await waitForSystemSpeechToFinish()
            }
        case .remote:
            stopMossPlayback()
            await speakRemote(trimmed, settings: settings)
        case .mossLocal:
            synthesizer.stopSpeaking(at: .immediate)
            await speakMossLocal(trimmed, settings: settings, waitUntilFinished: waitUntilFinished)
        }
    }

    func stopSpeaking() {
        synthesizer.stopSpeaking(at: .immediate)
        stopMossPlayback()
        for synthesizer in presetSynthesizers.values {
            synthesizer.stopSpeaking(at: .immediate)
        }
        presetSynthesizers.removeAll()
    }

    func unloadMossLocalWeights() {
#if canImport(MLXAudioTTS) && canImport(MLXAudioCore) && canImport(MLX)
        Task {
            await mossGenerator.unload()
            Memory.clearCache()
        }
        presetReferenceCache.removeAll()
#endif
        try? FileManager.default.removeItem(at: Self.mossCacheDirectory())
    }

    func unloadMossRuntimeMemory() async {
#if canImport(MLXAudioTTS) && canImport(MLXAudioCore) && canImport(MLX)
        await mossGenerator.unload()
        Memory.clearCache()
        presetReferenceCache.removeAll()
#endif
    }

    func prewarmMoss(settings: TTSSettings) async {
#if canImport(MLXAudioTTS) && canImport(MLXAudioCore) && canImport(MLX)
        guard Self.mossCacheExists() else { return }
        try? await mossGenerator.prewarm()
#endif
    }

    static func downloadMossWeights(progressHandler: @MainActor @Sendable @escaping (Progress) -> Void) async throws {
#if canImport(HuggingFace)
        guard let repo = Repo.ID(rawValue: TTSSettings.mossModelRepo) else {
            throw TTSModelDownloadError.invalidRepo
        }
        guard let tokenizerRepo = Repo.ID(rawValue: TTSSettings.mossAudioTokenizerRepo) else {
            throw TTSModelDownloadError.invalidRepo
        }
        guard let mirror = URL(string: "https://hf-mirror.com") else {
            throw TTSModelDownloadError.invalidRepo
        }
        let client = HubClient(host: mirror)
        let modelDirectory = mossCacheDirectory()
        let tokenizerDirectory = modelDirectory.appendingPathComponent("audio_tokenizer", isDirectory: true)
        try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tokenizerDirectory, withIntermediateDirectories: true)

        _ = try await client.downloadSnapshot(
            of: repo,
            kind: .model,
            to: modelDirectory,
            revision: "main",
            matching: ["*.safetensors", "*.json", "*.txt", "*.model", "*.index.json"],
            localFilesOnly: false,
            maxConcurrentDownloads: 4,
            progressHandler: { progress in
                progressHandler(Self.scaledProgress(progress, base: 0, span: 0.72))
            }
        )

        _ = try await client.downloadSnapshot(
            of: tokenizerRepo,
            kind: .model,
            to: tokenizerDirectory,
            revision: "main",
            matching: ["*.safetensors", "*.json", "*.txt", "*.md", "*.index.json"],
            localFilesOnly: false,
            maxConcurrentDownloads: 4,
            progressHandler: { progress in
                progressHandler(Self.scaledProgress(progress, base: 0.72, span: 0.28))
            }
        )
#else
        throw TTSModelDownloadError.huggingFaceUnavailable
#endif
    }

    nonisolated static func mossCacheExists() -> Bool {
        let directory = mossCacheDirectory()
        let tokenizer = directory.appendingPathComponent("audio_tokenizer", isDirectory: true)
        return FileManager.default.fileExists(atPath: directory.appendingPathComponent("config.json").path)
            && FileManager.default.fileExists(atPath: directory.appendingPathComponent("tokenizer.model").path)
            && FileManager.default.fileExists(atPath: tokenizer.appendingPathComponent("config.json").path)
    }

    nonisolated static func mossCacheDirectory() -> URL {
        let cacheRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return cacheRoot
            .appendingPathComponent("OmniPersona", isDirectory: true)
            .appendingPathComponent("MOSS-TTS-Nano-100M", isDirectory: true)
    }

    private static func scaledProgress(_ progress: Progress, base: Double, span: Double) -> Progress {
        let result = Progress(totalUnitCount: 1000)
        let fraction = progress.fractionCompleted.isFinite ? progress.fractionCompleted : 0
        result.completedUnitCount = Int64((base + min(1, max(0, fraction)) * span) * 1000)
        return result
    }

    static func popSpeakableSentence(from buffer: inout String) -> String? {
        let marks: Set<Character> = ["。", "！", "？", ".", "!", "?"]
        let minimumCharacters = 72
        var searchStart = buffer.startIndex
        var selectedEnd: String.Index?
        while let index = buffer[searchStart...].firstIndex(where: { marks.contains($0) }) {
            let end = buffer.index(after: index)
            let sentence = String(buffer[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            if sentence.count >= minimumCharacters {
                selectedEnd = end
                break
            }
            searchStart = end
            if searchStart >= buffer.endIndex { break }
        }
        if selectedEnd == nil, buffer.count >= 220 {
            selectedEnd = buffer.lastIndex(where: { $0.isWhitespace }).map { buffer.index(after: $0) } ?? buffer.index(buffer.startIndex, offsetBy: min(180, buffer.count))
        }
        guard let end = selectedEnd else { return nil }
        let sentence = String(buffer[..<end])
        buffer = String(buffer[end...])
        return sentence
    }

    private func speakRemote(_ text: String, settings: TTSSettings) async {
        guard var components = URLComponents(string: settings.remoteURL) else {
            reportRemoteFailure("远程 TTS URL 无效")
            return
        }
        var items = components.queryItems ?? []
        items.append(URLQueryItem(name: "text", value: text))
        if let speaker = remoteSpeaker(settings) {
            items.append(URLQueryItem(name: "speaker", value: speaker))
        }
        items.append(URLQueryItem(name: "speed", value: String(settings.speed)))
        components.queryItems = items

        guard let url = components.url else {
            reportRemoteFailure("远程 TTS 请求 URL 无效")
            return
        }
        if url.host == "localhost" || url.host == "127.0.0.1" {
            reportRemoteFailure("localhost 在真机上指向手机本机，请使用服务端内网 IP")
        }
        print("Remote TTS request URL: \(url.absoluteString)")

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("audio/wav, audio/x-wav, audio/mpeg, audio/mp4, audio/aac, audio/*;q=0.2", forHTTPHeaderField: "Accept")
        if !settings.remoteAPIKey.isEmpty {
            request.setValue("Bearer \(settings.remoteAPIKey)", forHTTPHeaderField: "Authorization")
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), !data.isEmpty else {
                reportRemoteFailure("远程 TTS 返回非 2xx 或空音频")
                return
            }
            let contentType = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
            if contentType.contains("ogg") || data.starts(with: [0x4F, 0x67, 0x67, 0x53]) {
                reportRemoteFailure("远程 TTS 返回 OGG/Vorbis，iOS 不能直接播放；请让接口返回 wav、mp3、aac 或 m4a。")
                return
            }
            let player = try AVAudioPlayer(data: data)
            player.prepareToPlay()
            player.play()
            while player.isPlaying {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        } catch {
            reportRemoteFailure("远程 TTS 播放失败：\(error.localizedDescription)")
        }
    }

    private func reportRemoteFailure(_ message: String) {
        print("Remote TTS failed: \(message)")
        onStatus?(message)
    }

    private func speakSystemFallback(_ text: String, settings: TTSSettings) {
        speakSystemFallback(
            text,
            speed: settings.speed,
            voiceIdentifier: settings.systemVoiceIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        )
    }

    private func speakSystemFallback(_ text: String, speed: Double, voiceIdentifier: String? = nil) {
        configurePlaybackSession()
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = Float(max(0.3, min(0.85, 0.42 * speed + 0.08)))
        if let voiceIdentifier,
           let voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier) {
            utterance.voice = voice
        } else {
            utterance.voice = AVSpeechSynthesisVoice(language: effectiveVoiceLanguage(text))
        }
        synthesizer.speak(utterance)
    }

    private func speakMossLocal(_ text: String, settings: TTSSettings, waitUntilFinished: Bool) async {
#if canImport(MLXAudioTTS) && canImport(MLXAudioCore) && canImport(MLX)
        guard !isMossBusy else { return }
        isMossBusy = true
        defer { isMossBusy = false }
        do {
            configurePlaybackSession()
            stopMossPlayback()
            let playbackID = UUID()
            mossPlaybackGeneration = playbackID
            let safeText = mossSafeText(text, language: mossLanguage(for: settings))
            let generated = try await mossGenerator.generateSamplesStream(
                text: safeText,
                presetVoice: settings.presetVoice,
                voiceName: mossVoiceName(for: settings),
                language: mossLanguage(for: settings),
                maxNewFrames: settings.mossMaxNewFrames,
                voiceCloneMaxTextTokens: settings.mossVoiceCloneMaxTextTokens,
                temperature: settings.mossTemperature,
                topP: settings.mossTopP,
                topK: settings.mossTopK,
                repetitionPenalty: settings.mossRepetitionPenalty,
                referenceText: settings.referenceText.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                presetReferenceProvider: { [weak self] sampleRate, presetID in
                    guard let self else { throw TTSModelDownloadError.mossWeightsMissing }
                    if let clone = try self.referenceAudioArray(path: settings.referenceAudioPath, sampleRate: sampleRate) {
                        return clone
                    }
                    return try await self.cachedPresetReferenceAudio(sampleRate: sampleRate, presetID: presetID)
                }
            )
            guard mossPlaybackGeneration == playbackID else { return }
            try await playMossSampleStream(generated.samples, sampleRate: generated.sampleRate, playbackID: playbackID, waitUntilFinished: waitUntilFinished)
        } catch {
            speakSystemFallback(text, settings: settings)
            if waitUntilFinished {
                await waitForSystemSpeechToFinish()
            }
        }
#else
        speakSystemFallback(text, settings: settings)
        if waitUntilFinished {
            await waitForSystemSpeechToFinish()
        }
#endif
    }

#if canImport(MLXAudioTTS) && canImport(MLXAudioCore) && canImport(MLX)
    private nonisolated func referenceAudioArray(path: String?, sampleRate: Int) throws -> MLXArray? {
        guard let path = path?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty
        else {
            return nil
        }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        return try loadAudioArray(from: url, sampleRate: sampleRate).1
    }

    private func cachedPresetReferenceAudio(sampleRate: Int, presetID: String) async throws -> MLXArray {
        let key = "\(presetID)-\(sampleRate)"
        if let cached = presetReferenceCache[key] {
            return cached
        }
        let url = try await presetReferenceAudioURL(for: presetID)
        let audio = try loadAudioArray(from: url, sampleRate: sampleRate).1
        presetReferenceCache[key] = audio
        return audio
    }

#endif

    private func configurePlaybackSession() {
#if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? session.setActive(true)
#endif
    }

    private func playAudioFile(_ url: URL, speed: Double, waitUntilFinished: Bool) async throws {
        mossPlaybackPlayer?.stop()
        let player = try AVAudioPlayer(contentsOf: url)
        mossPlaybackPlayer = player
        player.enableRate = true
        player.rate = Float(max(0.75, min(1.8, speed)))
        player.prepareToPlay()
        player.play()
        guard waitUntilFinished else { return }
        while mossPlaybackPlayer === player, player.isPlaying {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

#if canImport(MLXAudioTTS) && canImport(MLXAudioCore) && canImport(MLX)
    private func playMossSamples(_ samples: [Float], sampleRate: Int, playbackID: UUID, waitUntilFinished: Bool) async {
        guard !samples.isEmpty, mossPlaybackGeneration == playbackID else { return }
        mlxAudioPlayer.startStreaming(sampleRate: Double(sampleRate))
        mlxAudioPlayer.scheduleAudioChunk(samples, withCrossfade: false)
        mlxAudioPlayer.finishStreamingInput()
        guard waitUntilFinished else { return }
        while mossPlaybackGeneration == playbackID, mlxAudioPlayer.isPlaying {
            try? await Task.sleep(nanoseconds: 80_000_000)
        }
    }

    private func playMossSampleStream(_ stream: AsyncThrowingStream<[Float], Error>, sampleRate: Int, playbackID: UUID, waitUntilFinished: Bool) async throws {
        guard mossPlaybackGeneration == playbackID else { return }
        mlxAudioPlayer.startStreaming(sampleRate: Double(sampleRate))
        var scheduledAnyChunk = false
        do {
            for try await samples in stream {
                guard mossPlaybackGeneration == playbackID else { break }
                let finiteSamples = samples.filter { $0.isFinite }
                guard !finiteSamples.isEmpty else { continue }
                scheduledAnyChunk = true
                mlxAudioPlayer.scheduleAudioChunk(finiteSamples, withCrossfade: true)
            }
            mlxAudioPlayer.finishStreamingInput()
        } catch {
            mlxAudioPlayer.finishStreamingInput()
            throw error
        }
        guard scheduledAnyChunk, waitUntilFinished else { return }
        while mossPlaybackGeneration == playbackID, mlxAudioPlayer.isPlaying {
            try? await Task.sleep(nanoseconds: 80_000_000)
        }
    }
#endif

    private func stopMossPlayback() {
        mossPlaybackPlayer?.stop()
        mossPlaybackPlayer = nil
#if canImport(MLXAudioTTS) && canImport(MLXAudioCore) && canImport(MLX)
        mossPlaybackGeneration = UUID()
        mlxAudioPlayer.stop()
#endif
    }

    private func waitForSystemSpeechToFinish() async {
        while synthesizer.isSpeaking {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func presetReferenceAudioURL(for presetID: String) async throws -> URL {
        if let bundled = Bundle.main.url(forResource: presetID, withExtension: "wav", subdirectory: "MossPresetAudio") {
            return bundled
        }

        let directory = Self.mossCacheDirectory()
            .appendingPathComponent("preset-references", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(presetID)-v2.caf")
        if FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        try await synthesizePresetReference(presetID: presetID, to: url)
        return url
    }

    private func synthesizePresetReference(presetID: String, to url: URL) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let synthesizer = AVSpeechSynthesizer()
            presetSynthesizers[presetID] = synthesizer
            let utterance = AVSpeechUtterance(string: presetReferenceText(for: presetID))
            utterance.rate = 0.56
            utterance.pitchMultiplier = presetPitch(for: presetID)
            utterance.voice = AVSpeechSynthesisVoice(language: presetLanguage(for: presetID))
            var audioFile: AVAudioFile?
            var didResume = false

            synthesizer.write(utterance) { [weak self] buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength == 0 {
                    DispatchQueue.main.async {
                        guard !didResume else { return }
                        didResume = true
                        self?.presetSynthesizers[presetID] = nil
                        continuation.resume(returning: ())
                    }
                    return
                }

                do {
                    if audioFile == nil {
                        audioFile = try AVAudioFile(
                            forWriting: url,
                            settings: pcm.format.settings,
                            commonFormat: pcm.format.commonFormat,
                            interleaved: pcm.format.isInterleaved
                        )
                    }
                    try audioFile?.write(from: pcm)
                } catch {
                    DispatchQueue.main.async {
                        guard !didResume else { return }
                        didResume = true
                        self?.presetSynthesizers[presetID] = nil
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    private func presetLanguage(for presetID: String) -> String {
        switch presetID {
        case "en_female_clear", "en_male_story": return "en-US"
        case "ja_female_soft", "ja_male_calm": return "ja-JP"
        default: return "zh-CN"
        }
    }

    private func presetPitch(for presetID: String) -> Float {
        switch presetID {
        case "zh_child_bright": return 1.08
        case "ja_female_soft": return 1.04
        default: return 1.0
        }
    }

    private func presetReferenceText(for presetID: String) -> String {
        switch presetID {
        case "en_female_clear", "en_male_story":
            return "Hello, this is a short reference voice for OmniPersona."
        case "ja_female_soft":
            return "こんにちは、これはオムニペルソナの短い参考音声です。"
        case "ja_male_calm":
            return "だが、いくら返済をほのめかしても相手に話を逸らされると、手紙にはそう書いてある。"
        default:
            return "你好 当前是预设参考音色"
        }
    }

    private func mossSafeText(_ text: String, language: String?) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if language == "zh" {
            let normalized = trimmed
                .replacingOccurrences(of: "，", with: " ")
                .replacingOccurrences(of: ",", with: " ")
                .replacingOccurrences(of: "。", with: " ")
                .replacingOccurrences(of: "、", with: " ")
                .replacingOccurrences(of: "；", with: " ")
                .replacingOccurrences(of: ";", with: " ")
                .replacingOccurrences(of: "：", with: " ")
                .replacingOccurrences(of: ":", with: " ")
                .replacingOccurrences(of: "！", with: " ")
                .replacingOccurrences(of: "？", with: " ")
                .replacingOccurrences(of: "!", with: " ")
                .replacingOccurrences(of: "?", with: " ")
                .split(whereSeparator: { $0.isWhitespace })
                .joined(separator: " ")
            return String(normalized.prefix(360))
        }
        return String(trimmed.prefix(360))
    }

    private func effectiveVoice(_ settings: TTSSettings) -> String {
        if settings.referenceAudioPath?.isEmpty == false {
            return "clone:\(settings.referenceAudioPath ?? "")"
        }
        return settings.presetVoice.isEmpty ? settings.voice : settings.presetVoice
    }

    private func remoteSpeaker(_ settings: TTSSettings) -> String? {
        let candidate = settings.voice.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.isEmpty || TTSPresetVoices.all.contains(where: { $0.id == candidate }) {
            return nil
        }
        return candidate
    }

    private func mossVoiceName(for settings: TTSSettings) -> String {
        if let custom = settings.voice.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
           !TTSPresetVoices.all.contains(where: { $0.id == custom }) {
            return custom
        }
        switch settings.presetVoice {
        case "zh_child_bright": return "Hyacine"
        case "zh_female_warm": return "Phainon"
        case "en_female_clear": return "Ava"
        case "en_male_story": return "Adam"
        case "ja_female_soft": return "Yui"
        case "ja_male_calm": return "Goro"
        default: return "Junhao"
        }
    }

    private func mossLanguage(for settings: TTSSettings) -> String? {
        switch settings.presetVoice {
        case "en_female_clear", "en_male_story": return "en"
        case "ja_female_soft", "ja_male_calm": return "ja"
        default: return "zh"
        }
    }

    private func effectiveVoiceLanguage(_ text: String) -> String {
        if text.range(of: "[\\u3040-\\u30ff]", options: .regularExpression) != nil {
            return "ja-JP"
        }
        if text.range(of: "[A-Za-z]", options: .regularExpression) != nil,
           text.range(of: "[\\u4e00-\\u9fff]", options: .regularExpression) == nil {
            return "en-US"
        }
        return "zh-CN"
    }

#if canImport(MLXAudioTTS) && canImport(MLXAudioCore) && canImport(MLX)
    private actor MossTTSGenerator {
        private var modelRepo: String?
        private var model: SpeechGenerationModel?

        func unload() {
            model = nil
            modelRepo = nil
        }

        func prewarm() async throws {
            _ = try await loadModel()
        }

        func generateSamples(
            text: String,
            presetVoice: String,
            voiceName: String,
            language: String?,
            maxNewFrames: Int,
            voiceCloneMaxTextTokens: Int,
            temperature: Double,
            topP: Double,
            topK: Int,
            repetitionPenalty: Double,
            referenceText: String?,
            presetReferenceProvider: @MainActor @escaping (Int, String) async throws -> MLXArray
        ) async throws -> (samples: [Float], sampleRate: Int) {
            TTSService.configureMossMLXMemory()
            defer { Memory.clearCache() }
            let model = try await loadModel()
            let refAudio = try await presetReferenceProvider(model.sampleRate, presetVoice)
            var parameters = model.defaultGenerationParameters
            parameters.maxTokens = max(48, min(maxNewFrames, 900))
            parameters.temperature = Float(max(0, min(temperature, 1.5)))
            parameters.topP = Float(max(0.05, min(topP, 1)))
            parameters.topK = max(0, min(topK, 200))
            parameters.repetitionPenalty = Float(max(0.8, min(repetitionPenalty, 2.0)))

            let audio: MLXArray
            if let mossModel = model as? MossTTSNanoModel {
                audio = try await mossModel.generate(
                    text: text,
                    voice: voiceName,
                    refAudio: refAudio,
                    refText: referenceText,
                    language: language,
                    voiceCloneMaxTextTokens: max(24, min(voiceCloneMaxTextTokens, 240)),
                    generationParameters: parameters
                )
            } else {
                audio = try await model.generate(
                    text: text,
                    voice: voiceName,
                    refAudio: refAudio,
                    refText: referenceText,
                    language: language,
                    generationParameters: parameters
                )
            }
            let samples = try TTSService.mossMonoSamples(from: audio).filter { $0.isFinite }
            guard !samples.isEmpty else {
                throw TTSModelDownloadError.emptyGeneratedAudio
            }
            return (samples, model.sampleRate)
        }

        func generateSamplesStream(
            text: String,
            presetVoice: String,
            voiceName: String,
            language: String?,
            maxNewFrames: Int,
            voiceCloneMaxTextTokens: Int,
            temperature: Double,
            topP: Double,
            topK: Int,
            repetitionPenalty: Double,
            referenceText: String?,
            presetReferenceProvider: @MainActor @escaping (Int, String) async throws -> MLXArray
        ) async throws -> (samples: AsyncThrowingStream<[Float], Error>, sampleRate: Int) {
            TTSService.configureMossMLXMemory()
            let model = try await loadModel()
            let refAudio = try await presetReferenceProvider(model.sampleRate, presetVoice)
            var parameters = model.defaultGenerationParameters
            parameters.maxTokens = max(48, min(maxNewFrames, 900))
            parameters.temperature = Float(max(0, min(temperature, 1.5)))
            parameters.topP = Float(max(0.05, min(topP, 1)))
            parameters.topK = max(0, min(topK, 200))
            parameters.repetitionPenalty = Float(max(0.8, min(repetitionPenalty, 2.0)))

            if let mossModel = model as? MossTTSNanoModel {
                guard let tokenizer = mossModel.tokenizer else {
                    throw MossTTSNanoError.tokenizerNotInitialized
                }
                let promptAudioCodes = try mossModel.encodeReferenceAudio(refAudio, numQuantizers: mossModel.config.nVQ)
                let normalizedText = mossLightweightNormalizeText(text)
                let chunks = try mossSplitTextIntoBestSentences(
                    tokenizer: tokenizer,
                    text: normalizedText,
                    maxTokens: max(24, min(voiceCloneMaxTextTokens, 240))
                )
                let preparedChunks = try chunks.map { chunk in
                    try mossModel.buildInferenceInputIDs(
                        text: chunk,
                        tokenizer: tokenizer,
                        mode: "voice_clone",
                        promptText: nil,
                        promptAudioCodes: promptAudioCodes
                    )
                }
                let maxNewFramesValue = parameters.maxTokens ?? 375
                let doSampleValue = parameters.temperature > 0
                let audioTemperatureValue = parameters.temperature
                let audioTopPValue = parameters.topP
                let audioTopKValue = parameters.topK
                let audioRepetitionPenaltyValue = parameters.repetitionPenalty ?? 1.1
                let stream = AsyncThrowingStream<[Float], Error> { continuation in
                    let task = Task { @Sendable in
                        do {
                            TTSService.configureMossMLXMemory()
                            defer { Memory.clearCache() }
                            for prepared in preparedChunks {
                                try Task.checkCancellation()
                                let audioTokens = try mossModel.generateAudioTokenIDs(
                                    promptInputIDs: prepared.inputIDs,
                                    attentionMask: prepared.attentionMask,
                                    maxNewFrames: maxNewFramesValue,
                                    doSample: doSampleValue,
                                    audioTemperature: audioTemperatureValue,
                                    audioTopP: audioTopPValue,
                                    audioTopK: audioTopKValue,
                                    audioRepetitionPenalty: audioRepetitionPenaltyValue
                                )
                                let audio = try mossModel.decodeAudioTokenIDs(audioTokens, numQuantizers: mossModel.config.nVQ)
                                let samples = try TTSService.mossMonoSamples(from: audio)
                                if !samples.isEmpty {
                                    continuation.yield(samples)
                                }
                            }
                            continuation.finish()
                        } catch is CancellationError {
                            continuation.finish(throwing: CancellationError())
                        } catch {
                            continuation.finish(throwing: error)
                        }
                    }
                    continuation.onTermination = { @Sendable _ in task.cancel() }
                }
                return (stream, model.sampleRate)
            }

            let stream = model.generateSamplesStream(
                text: text,
                voice: voiceName,
                refAudio: refAudio,
                refText: referenceText,
                language: language,
                generationParameters: parameters,
                streamingInterval: 0.45
            )
            return (stream, model.sampleRate)
        }

        private func loadModel() async throws -> SpeechGenerationModel {
            TTSService.configureMossMLXMemory()
            let effectiveRepo = TTSSettings.mossModelRepo
            if let model, modelRepo == effectiveRepo {
                return model
            }
            guard TTSService.mossCacheExists() else {
                throw TTSModelDownloadError.mossWeightsMissing
            }
            let loaded = try await TTS.loadModel(
                modelRepo: TTSService.mossCacheDirectory().path,
                modelType: "moss_tts_nano"
            )
            modelRepo = effectiveRepo
            model = loaded
            return loaded
        }
    }

    private nonisolated static func configureMossMLXMemory() {
        let cacheLimit = 256 * 1024 * 1024
        if Memory.cacheLimit > cacheLimit {
            Memory.cacheLimit = cacheLimit
        }
    }

    private nonisolated static func mossMonoSamples(from audio: MLXArray) throws -> [Float] {
        var audio = audio.asType(.float32)
        if audio.ndim == 3 {
            guard audio.dim(0) == 1 else {
                throw TTSModelDownloadError.emptyGeneratedAudio
            }
            audio = audio[0]
        }

        let channels: [[Float]]
        switch audio.ndim {
        case 1:
            channels = [audio.asArray(Float.self)]
        case 2:
            let first = audio.dim(0)
            let second = audio.dim(1)
            let values = audio.asArray(Float.self)
            if second <= 8 {
                channels = Self.channelsFromSampleMajor(values: values, frameCount: first, channelCount: second)
            } else if first <= 8 {
                channels = (0..<first).map { channel in
                    let start = channel * second
                    return Array(values[start..<(start + second)])
                }
            } else {
                throw TTSModelDownloadError.emptyGeneratedAudio
            }
        default:
            throw TTSModelDownloadError.emptyGeneratedAudio
        }

        guard let firstChannel = channels.first, !firstChannel.isEmpty else {
            throw TTSModelDownloadError.emptyGeneratedAudio
        }
        guard channels.count > 1 else {
            return firstChannel
        }

        var mono = Array(repeating: Float(0), count: firstChannel.count)
        for frame in mono.indices {
            var sum: Float = 0
            for channel in channels {
                if frame < channel.count {
                    sum += channel[frame]
                }
            }
            mono[frame] = sum / Float(channels.count)
        }
        return mono
    }

    private nonisolated static func channelsFromSampleMajor(values: [Float], frameCount: Int, channelCount: Int) -> [[Float]] {
        var channels = Array(
            repeating: Array(repeating: Float(0), count: frameCount),
            count: channelCount
        )
        for frame in 0..<frameCount {
            for channel in 0..<channelCount {
                channels[channel][frame] = values[frame * channelCount + channel]
            }
        }
        return channels
    }
#endif
}

enum TTSModelDownloadError: LocalizedError {
    case invalidRepo
    case huggingFaceUnavailable
    case mossWeightsMissing
    case emptyGeneratedAudio

    var errorDescription: String? {
        switch self {
        case .invalidRepo:
            return "MOSS TTS repo 配置无效。"
        case .huggingFaceUnavailable:
            return "当前构建没有可用的 HuggingFace 下载组件。"
        case .mossWeightsMissing:
            return "MOSS TTS 权重或 audio tokenizer 尚未下载。"
        case .emptyGeneratedAudio:
            return "MOSS TTS 未生成有效音频。"
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
