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

private final class GenerationCancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func isCancelled() -> Bool {
        lock.lock()
        let value = cancelled
        lock.unlock()
        return value
    }
}

@MainActor
protocol TelegramToolRuntime: AnyObject {
    func tlgMessageResponse(chatId: Int64, text: String) async -> String
    func forwardMessageToUser(chatId: Int64, text: String) async -> String
    func notifyForwardToUser(chatId: Int64, text: String)
    func getUserLocation() async -> String
    func expandChatContext(chatId: Int64, fromMessageId: Int64, limit: Int) async -> String
    func elaborateRequestToUser(chatId: Int64, text: String) async -> String
}

enum TelegramToolDecisionMode: String {
    case llm
    case mock
}

@MainActor
@Observable
class MLXViewModel {
    private enum ToolResultText {
        static let missingTextError = "error: missing text"
        static let unsupportedToolPrefix = "error: unsupported tool"

        // Mocked tool results (easy to tune in one place)
        static let mockLocation = "coordinates: 37.7749,-122.4194"
        static let mockExpandedContext = """
        [id:1001 date:1772300000 sender:user] On my way now.
        [id:1000 date:1772299940 sender:assistant] Share ETA when available.
        """
        static let mockElaborateResult = "success: elaborated request sent"
    }

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
    private let maxToolRounds = 4
    @ObservationIgnored private var activeCancellationFlag: GenerationCancellationFlag?

    init(modelConfiguration: ModelConfiguration) {
        self.modelConfiguration = modelConfiguration
    }

    /// The hub which changes the default download directory.
    /// On iOS we must use app-sandbox writable storage.
    private static let huggingFaceToken = AppSecrets.huggingFaceToken
    private let hub = HubApi(downloadBase: modelDownloadDirectory, hfToken: huggingFaceToken)

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
        let cancellationFlag = GenerationCancellationFlag()
        activeCancellationFlag = cancellationFlag

        isRunning = true
        defer {
            if activeCancellationFlag === cancellationFlag {
                activeCancellationFlag = nil
            }
            isRunning = false
        }

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

                    if Task.isCancelled || cancellationFlag.isCancelled() {
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

    func requestStopGeneration() {
        activeCancellationFlag?.cancel()
    }

    func clearConversationContext() {
        telegramConversationHistory.removeAll(keepingCapacity: false)
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

    func handleTelegramMessageWithTools(
        chatId: Int64,
        incomingMessageId: Int64,
        incomingText: String,
        imageData: Data?,
        runtime: any TelegramToolRuntime,
        mode: TelegramToolDecisionMode
    ) async {
        let normalized = incomingText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty || imageData != nil else { return }

        if isRunning {
            print("[MLXSampleApp] Telegram tool pipeline skipped because generation is already running")
            return
        }

        if normalized.lowercased().hasPrefix("mock:") {
            await runMockToolPipeline(
                chatId: chatId,
                incomingMessageId: incomingMessageId,
                incomingText: normalized,
                runtime: runtime
            )
            return
        }

        if mode == .mock {
            await runMockToolPipeline(
                chatId: chatId,
                incomingMessageId: incomingMessageId,
                incomingText: normalized,
                runtime: runtime
            )
            return
        }

        appendTelegramHistory(role: .user, text: normalized.isEmpty ? "<image>" : normalized)
        var toolTrace: [String] = []
        var lastNonToolModelText = ""
        var lastToolState: ToolCallState?

        for round in 1...maxToolRounds {
            let plannerPrompt = toolPlannerPrompt(
                incomingText: normalized,
                round: round,
                toolTrace: toolTrace
            )

            let modelOutput = await generateText(
                prompt: plannerPrompt,
                images: (round == 1 ? (imageData.map { [$0] } ?? []) : []),
                parameters: .init(temperature: 0.4, topP: 0.95)
            )

            let trimmed = modelOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            print("""
            [MLXSampleApp] TOOL_ROUND
            round=\(round)/\(maxToolRounds)
            mode=\(mode.rawValue)
            chatId=\(chatId)
            incomingMessageId=\(incomingMessageId)
            incomingText=\(normalized)
            imageAttached=\(imageData != nil)
            modelOutputRaw=\(trimmed)
            """)
            if trimmed.isEmpty { continue }

            if let toolCall = parseToolCall(from: trimmed) {
                print("""
                [MLXSampleApp] TOOL_CALL_PARSED
                round=\(round)
                tool=\(toolCall.tool)
                arguments=\(toolCall.arguments)
                """)
                let toolResult = await runToolCall(
                    toolCall,
                    chatId: chatId,
                    incomingMessageId: incomingMessageId,
                    runtime: runtime,
                    mode: .llm
                )
                lastToolState = ToolCallState(call: toolCall, result: toolResult)
                toolTrace.append("tool=\(toolCall.tool) result=\(toolResult)")
                if toolCall.tool == "forward_message_to_user",
                   let userReply = extractUserResponse(from: toolResult),
                   !userReply.isEmpty {
                    toolTrace.append("user_response_received=\(userReply)")
                    toolTrace.append("next_required_tool=tlg_message_response")
                }
                print("""
                [MLXSampleApp] TOOL_CALL_RESULT
                round=\(round)
                tool=\(toolCall.tool)
                arguments=\(toolCall.arguments)
                result=\(toolResult)
                toolTrace=\(toolTrace)
                """)

                if toolCall.tool == "tlg_message_response" && toolResult == "success" {
                    output = "final_reply_sent(success)"
                    appendTelegramHistory(role: .assistant, text: "[sent via tlg_message_response]")
                    print("[MLXSampleApp] TOOL_LOOP_STOP reason=tlg_message_response_success")
                    return
                }
                continue
            }

            let nonToolText = sanitizeFinalModelText(trimmed)
            if !nonToolText.isEmpty {
                lastNonToolModelText = nonToolText
                toolTrace.append("non_tool_output_ignored")
                if let lastToolState {
                    toolTrace.append(
                        "parse_failed_retry_required tool=\(lastToolState.call.tool) args=\(lastToolState.call.arguments) last_result=\(lastToolState.result)"
                    )
                } else {
                    toolTrace.append("parse_failed_retry_required tool=unknown")
                }
                print("""
                [MLXSampleApp] TOOL_CALL_PARSE_FAILED
                round=\(round)
                mode=\(mode.rawValue)
                nonToolText=\(nonToolText)
                toolTrace=\(toolTrace)
                """)
                continue
            }
        }

        if !lastNonToolModelText.isEmpty {
            output = "no_tool_response_sent: model returned non-tool text; ignored by policy"
            print("[MLXSampleApp] Non-tool model output ignored. Only tlg_message_response is allowed to send.")
        } else {
            output = "no_tool_response_sent: no valid tool call produced"
            print("[MLXSampleApp] No valid tool call produced. Nothing sent to Telegram.")
        }
    }

    private func runMockToolPipeline(
        chatId: Int64,
        incomingMessageId: Int64,
        incomingText: String,
        runtime: any TelegramToolRuntime
    ) async {
        let calls = mockToolCalls(from: incomingText)
        guard !calls.isEmpty else {
            output = "Mode active. Send command like: mock:get_user_location or mock:tlg_message_response hello"
            return
        }

        var results: [String] = []
        for call in calls {
            print("""
            [MLXSampleApp] MOCK_TOOL_CALL
            chatId=\(chatId)
            incomingMessageId=\(incomingMessageId)
            incomingText=\(incomingText)
            tool=\(call.tool)
            arguments=\(call.arguments)
            """)
            let result = await runToolCall(
                call,
                chatId: chatId,
                incomingMessageId: incomingMessageId,
                runtime: runtime,
                mode: .mock
            )
            print("""
            [MLXSampleApp] MOCK_TOOL_RESULT
            tool=\(call.tool)
            arguments=\(call.arguments)
            result=\(result)
            """)
            results.append("\(call.tool) => \(result)")

            // Mock E2E loop: simulate a follow-up LLM decision to answer in Telegram
            // based on the returned tool result.
            if call.tool == "get_user_location", !result.lowercased().hasPrefix("fail") {
                let followUp = ParsedToolCall(
                    tool: "tlg_message_response",
                    arguments: ["text": "Your current location is: \(result)"]
                )
                let followUpResult = await runToolCall(
                    followUp,
                    chatId: chatId,
                    incomingMessageId: incomingMessageId,
                    runtime: runtime,
                    mode: .mock
                )
                results.append("tlg_message_response => \(followUpResult)")
            }

            if call.tool == "forward_message_to_user",
               let userReply = extractUserResponse(from: result) {
                output = userReply
            }
        }

        if !results.isEmpty {
            output += (output.isEmpty ? "" : "\n\n") + results.joined(separator: "\n")
        }
        appendTelegramHistory(role: .assistant, text: output)
    }

    private func extractUserResponse(from toolResult: String) -> String? {
        let prefix = "user_response("
        guard toolResult.hasPrefix(prefix), toolResult.hasSuffix(")") else { return nil }
        let start = toolResult.index(toolResult.startIndex, offsetBy: prefix.count)
        let end = toolResult.index(before: toolResult.endIndex)
        return String(toolResult[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func mockToolCalls(from text: String) -> [ParsedToolCall] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()

        if lower.hasPrefix("mock:tlg_message_response ") {
            let payload = String(trimmed.dropFirst("mock:tlg_message_response ".count))
            return [.init(tool: "tlg_message_response", arguments: ["text": payload])]
        }

        if lower.hasPrefix("mock:forward_message_to_user ") {
            let payload = String(trimmed.dropFirst("mock:forward_message_to_user ".count))
            return [.init(tool: "forward_message_to_user", arguments: ["text": payload])]
        }

        if lower == "mock:get_user_location" {
            return [.init(tool: "get_user_location", arguments: [:])]
        }

        if lower.hasPrefix("mock:expand_chat_context") {
            let limit = trimmed.split(separator: " ").last.map(String.init) ?? "15"
            return [.init(tool: "expand_chat_context", arguments: ["limit": limit])]
        }

        if lower.hasPrefix("mock:elaborate_request_to_user ") {
            let payload = String(trimmed.dropFirst("mock:elaborate_request_to_user ".count))
            return [.init(tool: "elaborate_request_to_user", arguments: ["text": payload])]
        }

        return [.init(tool: "tlg_message_response", arguments: ["text": "Echo: \(trimmed)"])]
    }

    private func generateText(
        prompt: String,
        images: [Data] = [],
        parameters: GenerateParameters = .init()
    ) async -> String {
        await generate(prompt: prompt, images: images, parameters: parameters)
        return output
    }

    private struct ParsedToolCall {
        let tool: String
        let arguments: [String: String]
    }

    private struct ToolCallState {
        let call: ParsedToolCall
        let result: String
    }

    private func parseToolCall(from text: String) -> ParsedToolCall? {
        let candidate: String
        if let jsonBlock = extractJSONBlock(from: text) {
            candidate = jsonBlock
        } else {
            candidate = text
        }

        guard let data = candidate.data(using: .utf8) else { return nil }
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard let tool = raw["tool"] as? String else { return nil }

        var args: [String: String] = [:]
        if let dict = raw["arguments"] as? [String: Any] {
            for (key, value) in dict {
                args[key] = String(describing: value)
            }
        }

        return ParsedToolCall(tool: tool, arguments: args)
    }

    private func extractJSONBlock(from text: String) -> String? {
        if let start = text.range(of: "```json") {
            let remainder = text[start.upperBound...]
            if let end = remainder.range(of: "```") {
                return String(remainder[..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        guard let first = text.firstIndex(of: "{"), let last = text.lastIndex(of: "}") else { return nil }
        guard first <= last else { return nil }
        return String(text[first...last])
    }

    private func sanitizeFinalModelText(_ text: String) -> String {
        if text.uppercased().hasPrefix("FINAL:") {
            return String(text.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    private func runToolCall(
        _ toolCall: ParsedToolCall,
        chatId: Int64,
        incomingMessageId: Int64,
        runtime: any TelegramToolRuntime,
        mode: TelegramToolDecisionMode
    ) async -> String {
        switch toolCall.tool {
        case "tlg_message_response":
            let text = toolCall.arguments["text"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else {
                print("[MLXSampleApp] tlg_message_response blocked: empty text")
                return ToolResultText.missingTextError
            }
            guard !isInternalToolTraceText(text) else {
                print("[MLXSampleApp] tlg_message_response blocked: invalid final message format text=\(text)")
                return "fail: invalid final message format"
            }
            print("[MLXSampleApp] tlg_message_response attempt chat=\(chatId) text=\(text)")
            return await runtime.tlgMessageResponse(chatId: chatId, text: text)

        case "forward_message_to_user":
            let text = toolCall.arguments["text"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else { return ToolResultText.missingTextError }
            return await runtime.forwardMessageToUser(chatId: chatId, text: text)

        case "get_user_location":
            if mode == .mock {
                return ToolResultText.mockLocation
            }
            return await runtime.getUserLocation()

        case "expand_chat_context":
            let limit = Int(toolCall.arguments["limit"] ?? "") ?? 15
            if mode == .mock {
                return ToolResultText.mockExpandedContext
            }
            return await runtime.expandChatContext(
                chatId: chatId,
                fromMessageId: incomingMessageId,
                limit: max(1, min(limit, 50))
            )

        case "elaborate_request_to_user":
            let text = toolCall.arguments["text"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else { return ToolResultText.missingTextError }
            if mode == .mock {
                return ToolResultText.mockElaborateResult
            }
            return await runtime.elaborateRequestToUser(chatId: chatId, text: text)

        default:
            return "\(ToolResultText.unsupportedToolPrefix) \(toolCall.tool)"
        }
    }

    private func isInternalToolTraceText(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("tool:") ||
            lower.contains("arguments:") ||
            lower.contains("result:") ||
            lower.contains("```") ||
            lower.contains("\"tool\"") ||
            lower.contains("\"arguments\"")
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

    private func toolPlannerPrompt(incomingText: String, round: Int, toolTrace: [String]) -> String {
        let historyBlock = telegramConversationHistory.map { entry in
            "\(entry.role.rawValue): \(entry.text)"
        }.joined(separator: "\n")

        let toolTraceBlock = toolTrace.isEmpty ? "none" : toolTrace.joined(separator: "\n")

        return """
        You are handling a private Telegram chat with tool calling.
        Round \(round) of \(maxToolRounds).

        Operating rules:
        - This input came from a Telegram private chat user.
        - You are an orchestrator. Do not discuss orchestration, simulation, or model internals with the user.
        - Interpret "you/your" in incoming text as the Telegram account owner (human), not the model.
        - Never answer with meta-questions like "are you asking me to simulate...".
        - IMPORTANT: `forward_message_to_user` is a QUESTION to the human owner; it is not a final Telegram answer.
        - IMPORTANT: `tlg_message_response` is the ONLY tool that sends the final visible answer to Telegram.
        - `tlg_message_response.text` must be plain user-facing text only (no JSON, no markdown code blocks, no "Tool:", no "Arguments:", no "Result:").
        - Never put chain-of-thought, reasoning, draft text, status, or internal notes into `tlg_message_response`.
        - If interrupted or uncertain, do not send anything unless you intentionally call `tlg_message_response`.
        - When direct info is missing, use tools first (especially `forward_message_to_user`) instead of freeform guessing.
        - If you need to reply to the user, you MUST call `tlg_message_response`.
        - After `tlg_message_response` returns success, STOP immediately and do not emit any additional response.
        - Never send duplicate replies for the same user message.
        - Don't treat local app output as a user-visible Telegram reply.
        - Use `forward_message_to_user` only when clarification is needed and a user response is required before finalizing.
        - Use `expand_chat_context` when context is insufficient.
        - Use `get_user_location` only when location is directly required.
        - Use `elaborate_request_to_user` when the user says they don't understand.
        - `FINAL:` is only for internal fallback/debug and should be avoided for normal chat replies.

        Available tools (return ONLY JSON with `tool` and `arguments`):
        1) tlg_message_response { "text": "..." } -> send FINAL response in current chat (only visible send tool)
        2) forward_message_to_user { "text": "..." } -> local voice handoff to human owner (not a Telegram send); returns dismissed/cancelled/user_response(text)
        3) get_user_location {} -> returns location text/coordinates
        4) expand_chat_context { "limit": "15" } -> returns older messages metadata or fail
        5) elaborate_request_to_user { "text": "..." } -> send clearer rephrased ask to user

        Practical guidance:
        - ETA/arrival questions about "you": call `forward_message_to_user` to get the human's answer, then call `tlg_message_response` with that answer.
        - Location requests: call `get_user_location`, then call `tlg_message_response` with the location.
        - Missing context: call `expand_chat_context`.
        - If user says they are confused after a `forward_message_to_user` step (e.g. "didn't get it", "rephrase"), call `forward_message_to_user` again with a clearer, more explicit request.
        - If any previous tool result contains `user_response(...)`, your immediate next tool MUST be `tlg_message_response` using that response content.
        - After receiving `user_response(...)`, do not call `forward_message_to_user` again unless the user response itself explicitly asks for rephrase/clarification.
        - If tool trace contains `parse_failed_retry_required`, immediately repeat the referenced tool call as valid JSON with the same tool and arguments.

        Preferred flow: choose tools until response is sent via `tlg_message_response`, then stop.
        Do not output plain prose replies. Return only JSON tool calls.
        If you cannot decide, use `forward_message_to_user` rather than generating a direct non-tool answer.

        Conversation history:
        \(historyBlock)

        Incoming user message:
        \(incomingText)

        Previous tool results:
        \(toolTraceBlock)
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
