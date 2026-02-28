//
//  MLXViewModel.swift
//  MLXSampleApp
//
//  Created by İbrahim Çetin on 3.03.2025.
//

import Foundation
import Hub
import MLXLLM
import MLXVLM
import MLXLMCommon
import CoreImage

@MainActor
@Observable
class MLXViewModel {
    /// The model configuration. It can be a LLM or VLM
    ///
    /// You can checkout MLXLLM.ModelRegistry or MLXVLM.ModelRegistry
    /// for predefined models.
    let modelConfiguration: ModelConfiguration

    /// The model container is used to generate language model output.
    ///
    /// The model container should be loaded via ``ModelFactory.laodContainer`` method.
    ///
    /// There is two type ``ModelFactory``: ``LLMModelFactory`` and ``VLMModelFactory``.
    var modelContainer: ModelContainer?

    /// The output of the language model.
    ///
    /// Call ``generate(prompt:images:)`` method to generate output.
    var output = ""

    /// The generated tokens per second count for the output.
    ///
    /// This property updated after ``generate(prompt:images:)`` method completed.
    var tokensPerSecond: Double = 0

    /// Indicated whetever ``generate(prompt:images:)`` is running or not.
    var isRunning = false

    /// The download progress to track downloading langauge model.
    ///
    /// When you call ``generate(prompt:images:)``, the download begins if the model is missing.
    var downloadProgress: Progress?

    /// Any error message occured while the generate process.
    var errorMessage: String?

    struct ConversationMessage {
        enum Role: String {
            case user
            case assistant
        }

        let role: Role
        let text: String
    }

    private let telegramHistoryLimit = 15
    private var telegramConversationHistory: [ConversationMessage] = []

    init(modelConfiguration: ModelConfiguration) {
        self.modelConfiguration = modelConfiguration
    }

    /// The hub which changes the default download directory.
    /// On iOS we must use app-sandbox writable storage.
    private let hub = HubApi(downloadBase: modelDownloadDirectory)

    private static var modelDownloadDirectory: URL {
#if os(iOS)
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "huggingface")
#else
        URL.downloadsDirectory.appending(path: "huggingface")
#endif
    }

    /// Returns appropriate `ModelFactory` for the ``modelConfiguration``
    ///
    /// If ``modelConfiguration`` is registered in the ``MLXLLM.ModelRegistry`` then it returns ``LLMModelFactory``.
    ///
    /// Otherwise, it returns ``VLMModelFactory``
    private var modelFactory: ModelFactory {
        // If the model is in LLM model registry then it is a LLM
        let isLLM = LLMModelFactory.shared.modelRegistry.models.contains { $0.name == modelConfiguration.name }

        // If the model is a LLM, select LLMFactory. If not, select VLM factory
        return if isLLM {
            LLMModelFactory.shared
        } else {
            VLMModelFactory.shared
        }
    }

    /// Loads the ``modelConfiguration`` into ``modelContainer``.
    ///
    /// You don't have to call this method explictly. ``generate(prompt:images:)`` method
    /// calls it when ``modelContainer`` is nil.
    private func loadModel() async {
        do {
            // Load the model with the appropriate factory
            modelContainer = try await modelFactory.loadContainer(
                hub: hub, // Comment out here if you want to use default download directory.
                configuration: modelConfiguration
            ) { progress in
                Task { @MainActor in
                    self.downloadProgress = progress
                }
            }
        } catch {
            logError(error, context: "loadModel")
            errorMessage = nil
        }
    }

    /// Generates language model output. It will set ``output`` property.
    func generate(prompt: String, images: [Data] = [], parameters: GenerateParameters = .init()) async {
        isRunning = true
        defer { isRunning = false }

        // Load the model if it hasn't been loaded yet
        if modelContainer == nil {
            await loadModel()
        }

        guard let modelContainer else { isRunning = false; return }

        do {
            let result = try await modelContainer.perform { context in
                // Create images
                let images: [UserInput.Image] = images.compactMap { CIImage(data: $0) }.map { .ciImage($0) }
                let prompt = createPrompt(prompt, images: images)

                // Create user input
                var userInput = UserInput(prompt: prompt, images: images)
                userInput.processing.resize = CGSize(width: 448, height: 448)

                // Create LM input
                let input = try await context.processor.prepare(input: userInput)

                // Generate output
                return try MLXLMCommon.generate(input: input, parameters: parameters, context: context) { tokens in
                    let text = context.tokenizer.decode(tokens: tokens)

                    Task { @MainActor in
                        output = text
                    }

                    if Task.isCancelled {
                        return .stop
                    }

                    return .more
                }
            }

            tokensPerSecond = result.tokensPerSecond
        } catch {
            if error is CancellationError {
                return
            }
            logError(error, context: "generate")
            errorMessage = nil
        }
    }

    func generateTelegramReply(incomingText: String, imageData: Data?) async {
        let normalized = incomingText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty || imageData != nil else {
            return
        }

        if isRunning {
            print("[MLXSampleApp] Telegram event dropped because generation is already running")
            return
        }

        appendTelegramHistory(role: .user, text: normalized.isEmpty ? "<image>" : normalized)
        let contextualPrompt = telegramPrompt(for: normalized)
        let images = imageData.map { [$0] } ?? []
        print("[MLXSampleApp] Telegram generation start promptLen=\(contextualPrompt.count) hasImage=\(imageData != nil)")
        await generate(
            prompt: contextualPrompt,
            images: images,
            parameters: .init(temperature: 0.6, topP: 0.95)
        )

        let finalOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if finalOutput.isEmpty {
            let fallbackPrompt = "Reply briefly to this private Telegram message:\n\(normalized)"
            print("[MLXSampleApp] Telegram generation empty on contextual prompt, retrying with fallback prompt")
            await generate(
                prompt: fallbackPrompt,
                images: [],
                parameters: .init(temperature: 0.7, topP: 0.95)
            )
        }

        let finalOrFallbackOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if !finalOrFallbackOutput.isEmpty {
            appendTelegramHistory(role: .assistant, text: finalOrFallbackOutput)
            print("[MLXSampleApp] Telegram generation done outputLen=\(finalOrFallbackOutput.count)")
        } else {
            print("[MLXSampleApp] Telegram generation completed with empty output after fallback")
        }
    }

    private func appendTelegramHistory(role: ConversationMessage.Role, text: String) {
        guard !text.isEmpty else { return }
        telegramConversationHistory.append(.init(role: role, text: text))
        if telegramConversationHistory.count > telegramHistoryLimit {
            telegramConversationHistory = Array(telegramConversationHistory.suffix(telegramHistoryLimit))
        }
    }

    private func telegramPrompt(for incomingText: String) -> String {
        let historyBlock = telegramConversationHistory.map { entry in
            "\(entry.role.rawValue): \(entry.text)"
        }.joined(separator: "\n")

        return """
        You are drafting a reply for a private Telegram conversation.
        Keep the response concise and useful.

        Conversation history:
        \(historyBlock)

        Draft the assistant's next reply:
        """
    }

    /// Creates ``UserInput.Prompt`` from prompt string and images
    ///
    /// If images is empty, return ``UserInput.Prompt/text`` case with the prompt.
    ///
    /// Otherwise, it will create messages in Qwen2 VL format and return ``UserInput.Prompt/messages``.
    private nonisolated func createPrompt(_ prompt: String, images: [UserInput.Image]) -> UserInput.Prompt {
        if images.isEmpty {
            return .text(prompt)
        } else {
            // Messages format for Qwen 2 VL, Qwen 2.5 VL. May need to be adapted for other models.
            let message: Message = [
                "role": "user",
                "content": [
                    ["type": "text", "text": prompt]
                ] + images.map { _ in ["type": "image"] }
            ]

            return .messages([message])
        }
    }

    private func logError(_ error: any Error, context: String) {
        print("[MLXSampleApp] ERROR in \(context) for model=\(modelConfiguration.id)")
        print("[MLXSampleApp] \(String(reflecting: error))")

        var nsError = error as NSError
        print("[MLXSampleApp] NSError domain=\(nsError.domain) code=\(nsError.code) userInfo=\(nsError.userInfo)")

        while let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            nsError = underlying
            print("[MLXSampleApp] Underlying domain=\(nsError.domain) code=\(nsError.code) userInfo=\(nsError.userInfo)")
        }
    }
}
