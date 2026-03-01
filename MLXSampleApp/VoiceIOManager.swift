import Foundation
import SwiftUI
import AVFoundation
#if os(macOS)
import AVKit
#endif

final class VoiceIOManager: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var isRecording = false
    @Published var isSpeakingOutLoud = false
    @Published var errorMessage: String?

    private var audioRecorder: AVAudioRecorder?
    private var recordingURL: URL?

    private var audioQueue: [Data] = []
    private var audioPlayer: AVAudioPlayer?
    private var pendingTTSChunks: [String] = []
    private var ttsProcessingTask: Task<Void, Never>?

    private var spokenCharacterCount = 0
    private var pendingSpeechBuffer = ""

    func startRecordingPrompt() async {
        do {
            let granted = await requestMicrophonePermission()
            guard granted else {
                throw VoiceIOError.microphonePermissionDenied
            }

            #if os(iOS)
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try audioSession.setActive(true)
            #endif

            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("prompt-recording-\(UUID().uuidString)")
                .appendingPathExtension("m4a")

            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]

            let recorder = try AVAudioRecorder(url: tempURL, settings: settings)
            recorder.prepareToRecord()
            guard recorder.record() else {
                throw VoiceIOError.recordingFailed
            }

            recordingURL = tempURL
            audioRecorder = recorder
            isRecording = true
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stopRecordingAndTranscribe() async -> String? {
        do {
            guard let recorder = audioRecorder, let url = recordingURL else {
                throw VoiceIOError.noRecordingInProgress
            }

            recorder.stop()
            audioRecorder = nil
            isRecording = false

            let audioData = try Data(contentsOf: url)
            try? FileManager.default.removeItem(at: url)
            recordingURL = nil

            let text = try await transcribeWithMistral(audioData: audioData, filename: "prompt.m4a")
            errorMessage = nil
            return text
        } catch {
            isRecording = false
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func beginOutputSpeechSession() {
        stopPlaybackAndResetQueues()
        spokenCharacterCount = 0
        pendingSpeechBuffer = ""
    }

    func consumeOutputText(_ fullText: String) {
        if fullText.count < spokenCharacterCount {
            spokenCharacterCount = 0
            pendingSpeechBuffer = ""
        }

        guard fullText.count >= spokenCharacterCount else { return }
        let delta = String(fullText.dropFirst(spokenCharacterCount))
        spokenCharacterCount = fullText.count

        guard !delta.isEmpty else { return }

        pendingSpeechBuffer += delta
        enqueueCompleteChunksIfAny()
    }

    func finishOutputSpeechSession() {
        let remaining = pendingSpeechBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingSpeechBuffer = ""

        if !remaining.isEmpty {
            enqueueTTSChunk(remaining)
        }
    }

    func resetAll() {
        if isRecording {
            audioRecorder?.stop()
            audioRecorder = nil
            isRecording = false
        }

        if let url = recordingURL {
            try? FileManager.default.removeItem(at: url)
        }
        recordingURL = nil

        stopPlaybackAndResetQueues()
        spokenCharacterCount = 0
        pendingSpeechBuffer = ""
    }

    func speakTextImmediately(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        stopPlaybackAndResetQueues()
        enqueueTTSChunk(trimmed)
    }

    func stopSpeechPlayback() {
        stopPlaybackAndResetQueues()
    }

    private func enqueueCompleteChunksIfAny() {
        while let splitIndex = pendingSpeechBuffer.firstIndex(where: { ".!?\n".contains($0) }) {
            let chunk = String(pendingSpeechBuffer[...splitIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            pendingSpeechBuffer = String(pendingSpeechBuffer[pendingSpeechBuffer.index(after: splitIndex)...])

            if !chunk.isEmpty {
                enqueueTTSChunk(chunk)
            }
        }

        if pendingSpeechBuffer.count > 160, let splitIndex = pendingSpeechBuffer.lastIndex(of: " ") {
            let chunk = String(pendingSpeechBuffer[..<splitIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            pendingSpeechBuffer = String(pendingSpeechBuffer[pendingSpeechBuffer.index(after: splitIndex)...])

            if !chunk.isEmpty {
                enqueueTTSChunk(chunk)
            }
        }
    }

    private func enqueueTTSChunk(_ text: String) {
        pendingTTSChunks.append(text)
        isSpeakingOutLoud = true

        if ttsProcessingTask == nil {
            ttsProcessingTask = Task { [weak self] in
                await self?.processTTSQueue()
            }
        }
    }

    private func processTTSQueue() async {
        while !Task.isCancelled {
            guard !pendingTTSChunks.isEmpty else {
                ttsProcessingTask = nil
                return
            }

            let chunk = pendingTTSChunks.removeFirst()

            do {
                let audioData = try await synthesizeWithElevenLabs(text: chunk)
                audioQueue.append(audioData)
                playNextAudioIfNeeded()
            } catch {
                errorMessage = error.localizedDescription
            }
        }

        ttsProcessingTask = nil
    }

    private func playNextAudioIfNeeded() {
        guard audioPlayer == nil else { return }
        guard !audioQueue.isEmpty else {
            isSpeakingOutLoud = false
            return
        }

        let data = audioQueue.removeFirst()

        do {
            let player = try AVAudioPlayer(data: data)
            player.delegate = self
            player.prepareToPlay()
            if player.play() {
                audioPlayer = player
                isSpeakingOutLoud = true
            } else {
                audioPlayer = nil
                playNextAudioIfNeeded()
            }
        } catch {
            errorMessage = error.localizedDescription
            audioPlayer = nil
            playNextAudioIfNeeded()
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.audioPlayer = nil
            self.playNextAudioIfNeeded()
            if self.audioPlayer == nil && self.audioQueue.isEmpty && self.pendingTTSChunks.isEmpty {
                self.isSpeakingOutLoud = false
            }
        }
    }

    private func stopPlaybackAndResetQueues() {
        audioPlayer?.stop()
        audioPlayer = nil
        audioQueue.removeAll(keepingCapacity: false)

        pendingTTSChunks.removeAll(keepingCapacity: false)
        ttsProcessingTask?.cancel()
        ttsProcessingTask = nil
        isSpeakingOutLoud = false
    }

    private func requestMicrophonePermission() async -> Bool {
        #if os(iOS)
        return await AVAudioApplication.requestRecordPermission()
        #elseif os(macOS)
        return await AVCaptureDevice.requestAccess(for: .audio)
        #else
        return false
        #endif
    }

    private func transcribeWithMistral(audioData: Data, filename: String) async throws -> String {
        guard let apiKey = Secrets.mistralAPIKey, !apiKey.isEmpty else {
            throw VoiceIOError.missingMistralApiKey
        }

        do {
            return try await transcribeWithMistralModel(
                apiKey: apiKey,
                model: Secrets.mistralSTTModel,
                audioData: audioData,
                filename: filename
            )
        } catch let error as VoiceIOError {
            guard case .apiError(_, let body) = error, body.localizedCaseInsensitiveContains("Invalid model") else {
                throw error
            }

            return try await transcribeWithMistralModel(
                apiKey: apiKey,
                model: Secrets.mistralFallbackSTTModel,
                audioData: audioData,
                filename: filename
            )
        }
    }

    private func transcribeWithMistralModel(apiKey: String, model: String, audioData: Data, filename: String) async throws -> String {
        let boundary = "Boundary-\(UUID().uuidString)"
        let url = URL(string: "\(Secrets.mistralBaseURL)/v1/audio/transcriptions")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let body = makeMultipartBody(boundary: boundary, model: model, filename: filename, audioData: audioData)
        let (data, response) = try await URLSession.shared.upload(for: request, from: body)
        try validateHTTPResponse(response, data: data)

        let decoded = try JSONDecoder().decode(MistralTranscriptionResponse.self, from: data)
        return decoded.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func synthesizeWithElevenLabs(text: String) async throws -> Data {
        guard let apiKey = Secrets.elevenLabsAPIKey, !apiKey.isEmpty else {
            throw VoiceIOError.missingElevenLabsApiKey
        }

        let url = URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(Secrets.elevenLabsVoiceID)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")

        let payload = ElevenLabsRequest(
            text: text,
            model_id: Secrets.elevenLabsModel,
            optimize_streaming_latency: 2,
            voice_settings: .init(stability: 0.35, similarity_boost: 0.75)
        )

        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        try validateHTTPResponse(response, data: data)
        return data
    }

    private func validateHTTPResponse(_ response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw VoiceIOError.invalidServerResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "<non-utf8-response>"
            throw VoiceIOError.apiError(statusCode: httpResponse.statusCode, body: body)
        }
    }

    private func makeMultipartBody(boundary: String, model: String, filename: String, audioData: Data) -> Data {
        var body = Data()
        let lineBreak = "\r\n"

        body.append("--\(boundary)\(lineBreak)".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"model\"\(lineBreak)\(lineBreak)".data(using: .utf8)!)
        body.append("\(model)\(lineBreak)".data(using: .utf8)!)

        body.append("--\(boundary)\(lineBreak)".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\(lineBreak)".data(using: .utf8)!)
        body.append("Content-Type: audio/m4a\(lineBreak)\(lineBreak)".data(using: .utf8)!)
        body.append(audioData)
        body.append(lineBreak.data(using: .utf8)!)

        body.append("--\(boundary)--\(lineBreak)".data(using: .utf8)!)
        return body
    }
}

private struct MistralTranscriptionResponse: Decodable {
    let text: String
}

private struct ElevenLabsRequest: Encodable {
    let text: String
    let model_id: String
    let optimize_streaming_latency: Int
    let voice_settings: VoiceSettings

    struct VoiceSettings: Encodable {
        let stability: Double
        let similarity_boost: Double
    }
}

private enum Secrets {
    static var mistralAPIKey: String? {
        "***REMOVED_MISTRAL_API_KEY***"
    }

    static var mistralBaseURL: String {
        "https://api.mistral.ai"
    }

    static var mistralSTTModel: String {
        "voxtral-mini-latest"
    }

    static var mistralFallbackSTTModel: String {
        "voxtral-mini-transcribe-2507"
    }

    static var elevenLabsAPIKey: String? {
        "***REMOVED_ELEVENLABS_API_KEY***"
    }

    static var elevenLabsVoiceID: String {
        "JBFqnCBsd6RMkjVDRZzb"
    }

    static var elevenLabsModel: String {
        "eleven_flash_v2_5"
    }
}

enum VoiceIOError: LocalizedError {
    case microphonePermissionDenied
    case recordingFailed
    case noRecordingInProgress
    case missingMistralApiKey
    case missingElevenLabsApiKey
    case invalidServerResponse
    case apiError(statusCode: Int, body: String)

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "Microphone permission was denied."
        case .recordingFailed:
            return "Failed to start audio recording."
        case .noRecordingInProgress:
            return "No recording is currently in progress."
        case .missingMistralApiKey:
            return "Missing MISTRAL_API_KEY. Add it to env vars, test.env, or Info.plist."
        case .missingElevenLabsApiKey:
            return "Missing ELEVENLABS_API_KEY. Add it to env vars, test.env, or Info.plist."
        case .invalidServerResponse:
            return "Invalid response from the speech API."
        case .apiError(let statusCode, let body):
            return "Speech API failed with HTTP \(statusCode): \(body)"
        }
    }
}
