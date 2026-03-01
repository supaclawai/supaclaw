//
//  ContentView.swift
//  MLXSampleApp
//
//  Created by İbrahim Çetin on 28.02.2025.
//

import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN
import MLXVLM
import PhotosUI
import SwiftUI

struct ContentView: View {
    private enum AppTab: Hashable {
        case chat
        case voice
    }

    init() {
        replacementTokenizers["TokenizersBackend"] = "PreTrainedTokenizer"
        registerMistral3CompatibilityLoader()
        LLMModelFactory.shared.modelRegistry.registerCustomModels()
    }

    @State private var vm = MLXViewModel(
        modelConfiguration: defaultModelConfiguration
    )

    #if os(iOS)
        private static let defaultModelConfiguration = MLXLLM.ModelRegistry
            .ministral3_3BInstruct4bit
    #else
        private static let defaultModelConfiguration = MLXLLM.ModelRegistry
            .mistralNeMoMinitron8BInstruct4bit
    #endif

    private static let defaultTelegramApiId = "26410040"
    private static let defaultTelegramApiHash = "0cba8ae79cd998cc3db43e7aa989d5b6"

    @State private var prompt: String = ""
    @State private var selectedImages: [Data] = []
    @StateObject private var voiceManager = VoiceIOManager()

    @State private var showingPhotoPicker: Bool = false
    @State private var photoSelection: PhotosPickerItem?
    @State private var generationTask: Task<Void, Never>?
    @State private var telegramBridge: TelegramTDLibBridge?
    @State private var useMockToolMode: Bool = false
    @State private var selectedTab: AppTab = .chat
    @State private var pendingForwardChatId: Int64?
    @State private var pendingForwardMessageId: Int64 = 0
    @State private var pendingForwardText: String = ""
    @State private var voiceTabStatus: String = "Waiting for a forwarded request"

    var body: some View {
        TabView(selection: $selectedTab) {
            chatTab
                .tabItem {
                    Label("Chat", systemImage: "message")
                }
                .tag(AppTab.chat)

            voiceTab
                .tabItem {
                    Label("Voice", systemImage: "waveform.circle.fill")
                }
                .tag(AppTab.voice)
        }
        .task {
            ensureTelegramBridge()
        }
        .onDisappear {
            stopTelegramBridge()
        }
        .onChange(of: useMockToolMode) { _, isMock in
            telegramBridge?.toolDecisionMode = isMock ? .mock : .llm
        }
        .onReceive(NotificationCenter.default.publisher(for: .forwardMessageToUserRequested)) {
            notification in
            guard let userInfo = notification.userInfo,
                let chatId = userInfo["chatId"] as? Int64,
                let text = userInfo["text"] as? String
            else {
                return
            }
            print("[MLXSampleApp] Voice tab received forward event chat=\(chatId) len=\(text.count)")
            pendingForwardChatId = chatId
            pendingForwardMessageId = 0
            pendingForwardText = text
            selectedTab = .voice
            voiceTabStatus = "Reading forwarded request..."
            voiceManager.speakTextImmediately(text)
        }
    }

    private var chatTab: some View {
        NavigationStack {
            VStack {
                HStack {
                    Text("Tool Mode")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Toggle(isOn: $useMockToolMode) {
                        Text(useMockToolMode ? "Mock" : "LLM")
                            .font(.caption)
                    }
                    .toggleStyle(.switch)
                    .labelsHidden()
                    Text(useMockToolMode ? "Mock" : "LLM")
                        .font(.caption)
                        .foregroundStyle(useMockToolMode ? .orange : .green)
                }

                #if os(iOS)
                    if let telegramBridge {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Telegram MTProto")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            TextField(
                                "API ID",
                                text: Binding(
                                    get: { telegramBridge.apiIdText },
                                    set: { telegramBridge.apiIdText = $0 }
                                )
                            )
                            .textFieldStyle(.roundedBorder)
                            .keyboardType(.numberPad)
                            .accessibilityIdentifier("telegram_api_id")

                            TextField(
                                "API Hash",
                                text: Binding(
                                    get: { telegramBridge.apiHash },
                                    set: { telegramBridge.apiHash = $0 }
                                )
                            )
                            .textFieldStyle(.roundedBorder)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("telegram_api_hash")

                            TextField(
                                "Phone Number (+...)",
                                text: Binding(
                                    get: { telegramBridge.phoneNumber },
                                    set: { telegramBridge.phoneNumber = $0 }
                                )
                            )
                            .textFieldStyle(.roundedBorder)
                            .keyboardType(.phonePad)
                            .accessibilityIdentifier("telegram_phone")

                            HStack {
                                Button("Send Phone") {
                                    telegramBridge.submitPhone()
                                }
                                .accessibilityIdentifier("telegram_submit_phone")

                                Text(telegramBridge.isAuthorized ? "Authorized" : "Not authorized")
                                    .font(.caption2)
                                    .foregroundStyle(telegramBridge.isAuthorized ? .green : .orange)
                            }

                            HStack {
                                TextField(
                                    "Login Code",
                                    text: Binding(
                                        get: { telegramBridge.authCode },
                                        set: { telegramBridge.authCode = $0 }
                                    )
                                )
                                .textFieldStyle(.roundedBorder)
                                .accessibilityIdentifier("telegram_code")

                                Button("Submit") {
                                    telegramBridge.submitCode()
                                }
                                .accessibilityIdentifier("telegram_submit_code")
                            }

                            HStack {
                                SecureField(
                                    "2FA Password",
                                    text: Binding(
                                        get: { telegramBridge.twoFactorPassword },
                                        set: { telegramBridge.twoFactorPassword = $0 }
                                    )
                                )
                                .textFieldStyle(.roundedBorder)
                                .accessibilityIdentifier("telegram_password")

                                Button("Submit") {
                                    telegramBridge.submitPassword()
                                }
                                .accessibilityIdentifier("telegram_submit_password")
                            }

                            HStack {
                                if telegramBridge.isRunning {
                                    Button("Disconnect", action: stopTelegramBridge)
                                        .accessibilityIdentifier("telegram_disconnect")
                                } else {
                                    Button("Connect", action: startTelegramBridge)
                                        .accessibilityIdentifier("telegram_connect")
                                }

                                Text(telegramBridge.statusText)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }

                            Text(telegramBridge.lastInboundSummary)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        .padding(8)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
                    }
                #endif

                ScrollView {
                    if let selectedImage = selectedImages.first,
                        let image = PlatformImage(data: selectedImage)
                    {
                        Image(platformImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: 200, alignment: .trailing)
                    }

                    Text(vm.output)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("output_text")

                    if let voiceError = voiceManager.errorMessage, !voiceError.isEmpty {
                        Text(voiceError)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                HStack {
                    Button {
                        showingPhotoPicker = true
                    } label: {
                        Image(systemName: "photo.badge.plus")
                    }

                    Button {
                        toggleVoiceInput()
                    } label: {
                        Image(
                            systemName: voiceManager.isRecording ? "stop.circle.fill" : "mic.fill")
                    }
                    .accessibilityIdentifier("voice_input_button")

                    TextField("Prompt", text: $prompt)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("prompt_field")

                    if vm.isRunning {
                        Button(action: stopGeneration) {
                            Image(systemName: "stop.fill")
                        }
                        .accessibilityIdentifier("stop_button")
                    } else {
                        Button(action: generate) {
                            Image(systemName: "paperplane.fill")
                        }
                        .keyboardShortcut(.defaultAction)
                        .disabled(sendButtonDisabled)
                        .accessibilityIdentifier("send_button")
                    }
                }
            }
            .padding()
            #if (os(iOS))
                .photosPicker(isPresented: $showingPhotoPicker, selection: $photoSelection)
                .onChange(of: photoSelection, addImage)
            #elseif (os(macOS))
                .fileImporter(
                    isPresented: $showingPhotoPicker, allowedContentTypes: [.image],
                    onCompletion: addImage)
            #endif

            .toolbar {
                if let progress = vm.downloadProgress, !progress.isFinished {
                    DownloadProgressView(progress: progress)
                }

                Button(action: reset) {
                    TokensPerSecondView(value: vm.tokensPerSecond)
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("MLXSampleApp")
            #if (os(macOS))
                .navigationSubtitle(vm.modelConfiguration.name)
            #endif
        }
    }

    private var voiceTab: some View {
        ZStack {
            LinearGradient(
                colors: [Color.black, Color(red: 0.07, green: 0.08, blue: 0.13)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 24) {
                Text("Choose a voice")
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.95))

                Spacer()

                Button {
                    Task {
                        await handleVoiceCircleTap()
                    }
                } label: {
                    ZStack {
                        Circle()
                            .fill(
                                RadialGradient(
                                    gradient: Gradient(colors: [
                                        Color(red: 0.83, green: 0.94, blue: 1.0),
                                        Color(red: 0.43, green: 0.74, blue: 1.0),
                                        Color(red: 0.10, green: 0.51, blue: 0.98),
                                    ]),
                                    center: .topLeading,
                                    startRadius: 10,
                                    endRadius: 130
                                )
                            )
                            .frame(width: 220, height: 220)
                            .shadow(color: .blue.opacity(0.35), radius: 20, y: 10)

                        Image(systemName: voiceCircleIconName)
                            .font(.system(size: 52, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.95))
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("voice_mode_circle_button")

                VStack(spacing: 8) {
                    Text(voiceTabTitle)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                    Text(voiceTabStatus)
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.8))
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                    if !pendingForwardText.isEmpty {
                        Text("Request: \(pendingForwardText)")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(3)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(.horizontal, 24)

                Spacer()

                Button("Done") {
                    selectedTab = .chat
                }
                .font(.headline)
                .foregroundStyle(.black.opacity(0.85))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(.white.opacity(0.9), in: Capsule())
                .padding(.horizontal, 22)
                .padding(.bottom, 18)
            }
            .padding(.top, 16)
        }
    }

    private func generate() {
        generationTask?.cancel()
        generationTask = Task {
            await vm.generate(prompt: prompt, images: selectedImages)
            generationTask = nil
        }
    }

    private func stopGeneration() {
        vm.requestStopGeneration()
        vm.clearConversationContext()
        generationTask?.cancel()
        generationTask = nil
    }

    private var voiceCircleIconName: String {
        if voiceManager.isRecording {
            return "stop.fill"
        }
        if voiceManager.isSpeakingOutLoud {
            return "waveform"
        }
        return "mic.fill"
    }

    private var voiceTabTitle: String {
        if voiceManager.isRecording {
            return "Listening..."
        }
        if voiceManager.isSpeakingOutLoud {
            return "Speaking..."
        }
        return "SupaClawd"
    }

    private func handleVoiceCircleTap() async {
        guard let telegramBridge else {
            voiceTabStatus = "Telegram bridge is not ready"
            return
        }

        guard let chatId = pendingForwardChatId else {
            voiceTabStatus = "No pending forwarded request"
            return
        }

        if voiceManager.isRecording {
            voiceTabStatus = "Transcribing with Voxtral..."
            let transcription = await voiceManager.stopRecordingAndTranscribe()?.trimmingCharacters(
                in: .whitespacesAndNewlines)
            guard let text = transcription, !text.isEmpty else {
                voiceTabStatus = voiceManager.errorMessage ?? "No speech captured"
                return
            }

            if telegramBridge.submitForwardedUserResponse(chatId: chatId, text: text) {
                voiceTabStatus = "Delivered voice response to tool loop"
            } else {
                // Keep tool pipeline strictly serial:
                // if no pending forward waiter exists, do not start a parallel/new inference loop.
                print("[MLXSampleApp] Voice response ignored: no pending forward waiter for chat=\(chatId)")
                voiceTabStatus = "No pending forward request. Try forward-to-user again."
                return
            }

            pendingForwardChatId = nil
            pendingForwardMessageId = 0
            pendingForwardText = ""
            voiceTabStatus = "Response sent to Telegram"
            return
        }

        if voiceManager.isSpeakingOutLoud {
            voiceManager.stopSpeechPlayback()
        }

        voiceTabStatus = "Listening for user answer..."
        await voiceManager.startRecordingPrompt()
        if let error = voiceManager.errorMessage, !error.isEmpty {
            voiceTabStatus = error
        }
    }

    private func ensureTelegramBridge() {
        guard telegramBridge == nil else { return }

        let bridge = TelegramTDLibBridge { chatId, messageId, text, imageData, runtime, mode in
            await vm.handleTelegramMessageWithTools(
                chatId: chatId,
                incomingMessageId: messageId,
                incomingText: text,
                imageData: imageData,
                runtime: runtime,
                mode: mode
            )
        }

        bridge.apiIdText =
            UserDefaults.standard.string(forKey: "telegram.api_id") ?? Self.defaultTelegramApiId
        bridge.apiHash =
            UserDefaults.standard.string(forKey: "telegram.api_hash") ?? Self.defaultTelegramApiHash
        bridge.phoneNumber = UserDefaults.standard.string(forKey: "telegram.phone") ?? ""
        bridge.toolDecisionMode = useMockToolMode ? .mock : .llm
        telegramBridge = bridge
    }

    private func startTelegramBridge() {
        guard let telegramBridge else { return }

        UserDefaults.standard.set(telegramBridge.apiIdText, forKey: "telegram.api_id")
        UserDefaults.standard.set(telegramBridge.apiHash, forKey: "telegram.api_hash")
        UserDefaults.standard.set(telegramBridge.phoneNumber, forKey: "telegram.phone")
        telegramBridge.start()
    }

    private func stopTelegramBridge() {
        telegramBridge?.stop()
    }

    #if (os(iOS))
        private func addImage() {
            Task {
                if let data = try? await photoSelection?.loadTransferable(type: Data.self) {
                    selectedImages = [data]
                } else {
                    selectedImages = []
                }
            }
        }
    #elseif (os(macOS))
        private func addImage(_ result: Result<URL, any Error>) {
            if let url = try? result.get(), let data = try? Data(contentsOf: url) {
                selectedImages = [data]
            } else {
                selectedImages = []
            }
        }
    #endif

    private func reset() {
        vm.requestStopGeneration()
        generationTask?.cancel()
        generationTask = nil
        voiceManager.resetAll()
        vm.output = ""
        vm.tokensPerSecond = 0

        prompt = ""
        selectedImages = []
    }

    private var sendButtonDisabled: Bool {
        vm.isRunning || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || (vm.downloadProgress != nil && !vm.downloadProgress!.isFinished)
    }

    private func toggleVoiceInput() {
        if voiceManager.isRecording {
            Task {
                if let transcription = await voiceManager.stopRecordingAndTranscribe(),
                    !transcription.isEmpty
                {
                    prompt = transcription
                }
            }
        } else {
            Task {
                await voiceManager.startRecordingPrompt()
            }
        }
    }
}

#Preview {
    ContentView()
}

private enum Mistral3CompatibilityError: LocalizedError {
    case missingTextConfig

    var errorDescription: String? {
        switch self {
        case .missingTextConfig:
            return "mistral3 config.json is missing text_config"
        }
    }
}

private final class Mistral3TextLlamaWrapper: Module, LLMModel, KVCacheDimensionProvider {
    @ModuleInfo(key: "language_model") var languageModel: LlamaModel

    init(_ languageModel: LlamaModel) {
        self._languageModel.wrappedValue = languageModel
    }

    var kvHeads: [Int] {
        languageModel.kvHeads
    }

    func callAsFunction(_ inputs: MLXArray, cache: [KVCache]?) -> MLXArray {
        languageModel(inputs, cache: cache)
    }

    func loraLinearLayers() -> LoRALinearLayers {
        languageModel.loraLinearLayers()
    }

    func sanitize(weights: [String: MLXArray]) -> [String: MLXArray] {
        var filtered = [String: MLXArray]()
        filtered.reserveCapacity(weights.count)

        for (key, value) in weights {
            guard key.hasPrefix("language_model.") else {
                continue
            }
            if key.contains("self_attn.rotary_emb.inv_freq") {
                continue
            }
            filtered[key] = value
        }

        return filtered
    }
}

private enum Mistral3ConfigAdapter {
    static func makeLlamaConfigData(from configURL: URL) throws -> Data {
        let rootData = try Data(contentsOf: configURL)
        guard
            let root = try JSONSerialization.jsonObject(with: rootData) as? [String: Any],
            var textConfig = root["text_config"] as? [String: Any]
        else {
            throw Mistral3CompatibilityError.missingTextConfig
        }

        // Ministral-3 stores RoPE settings under rope_parameters with yarn metadata.
        // Older LlamaConfiguration decoders don't accept that shape.
        if let ropeParameters = textConfig["rope_parameters"] as? [String: Any] {
            if let ropeTheta = ropeParameters["rope_theta"] {
                textConfig["rope_theta"] = ropeTheta
            }
            textConfig.removeValue(forKey: "rope_parameters")
            textConfig.removeValue(forKey: "rope_scaling")
        }

        return try JSONSerialization.data(withJSONObject: textConfig)
    }
}

private func registerMistral3CompatibilityLoader() {
    LLMModelFactory.shared.typeRegistry.registerModelType("mistral3") { configURL in
        let configData = try Mistral3ConfigAdapter.makeLlamaConfigData(from: configURL)
        let llamaConfiguration = try JSONDecoder().decode(LlamaConfiguration.self, from: configData)
        return Mistral3TextLlamaWrapper(LlamaModel(llamaConfiguration))
    }
}
