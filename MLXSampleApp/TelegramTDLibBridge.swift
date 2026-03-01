import Foundation
#if os(iOS)
import CoreLocation
#endif

#if canImport(TDLibKit)
import TDLibKit
#endif

extension Foundation.Notification.Name {
    static let forwardMessageToUserRequested = Foundation.Notification.Name("forwardMessageToUserRequested")
}

@MainActor
@Observable
final class TelegramTDLibBridge: TelegramToolRuntime {
    var apiIdText: String = ""
    var apiHash: String = ""
    var phoneNumber: String = ""
    var authCode: String = ""
    var twoFactorPassword: String = ""

    var isRunning: Bool = false
    var isAuthorized: Bool = false
    var statusText: String = "Telegram: disconnected"
    var lastInboundSummary: String = "No inbound message yet"
    var toolDecisionMode: TelegramToolDecisionMode = .llm

    private let onInboundMessage: @MainActor (_ chatId: Int64, _ messageId: Int64, _ text: String, _ imageData: Data?, _ runtime: any TelegramToolRuntime, _ mode: TelegramToolDecisionMode) async -> Void

#if canImport(TDLibKit)
    private var manager: TDLibClientManager?
    private var client: TDLibClient?
#endif
    private var pendingForwardResponseWaiters: [Int64: CheckedContinuation<String, Never>] = [:]
    private var lastForwardPromptByChat: [Int64: String] = [:]
    private var awaitingForwardUserResponseChats: Set<Int64> = []
#if os(iOS)
    private let locationProvider = IOSLocationProvider()
#endif

    init(onInboundMessage: @escaping @MainActor (_ chatId: Int64, _ messageId: Int64, _ text: String, _ imageData: Data?, _ runtime: any TelegramToolRuntime, _ mode: TelegramToolDecisionMode) async -> Void) {
        self.onInboundMessage = onInboundMessage
    }

    func start() {
#if canImport(TDLibKit)
        guard !isRunning else { return }
        isRunning = true
        isAuthorized = false
        statusText = "Telegram: starting"

        let manager = TDLibClientManager()
        self.manager = manager
        self.client = manager.createClient(updateHandler: { [weak self] data, client in
            Task { @MainActor [weak self] in
                await self?.handleUpdate(data: data, client: client)
            }
        })
#else
        statusText = "Telegram: TDLibKit not linked. Add Swiftgram/TDLibKit package."
#endif
    }

    func stop() {
#if canImport(TDLibKit)
        guard isRunning else { return }
        let activeClient = client
        let activeManager = manager

        client = nil
        manager = nil
        isRunning = false
        isAuthorized = false
        statusText = "Telegram: disconnected"
        resolveAllPendingForwardWaiters(with: "cancelled")

        Task.detached {
            if let activeClient {
                _ = try? await activeClient.close()
            }
            activeManager?.closeClients()
        }
#else
        isRunning = false
        isAuthorized = false
        statusText = "Telegram: disconnected"
#endif
    }

    func submitCode() {
#if canImport(TDLibKit)
        guard let client else { return }
        let code = authCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else {
            statusText = "Telegram: enter login code"
            return
        }

        Task {
            do {
                _ = try await client.checkAuthenticationCode(code: code)
                statusText = "Telegram: code submitted"
            } catch {
                statusText = "Telegram auth error: \(error.localizedDescription)"
            }
        }
#endif
    }

    func submitPhone() {
#if canImport(TDLibKit)
        guard let client else { return }
        let phone = phoneNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phone.isEmpty else {
            statusText = "Telegram: enter phone number"
            return
        }

        Task {
            do {
                _ = try await client.setAuthenticationPhoneNumber(phoneNumber: phone, settings: nil)
                statusText = "Telegram: code sent"
            } catch {
                statusText = "Telegram phone error: \(error.localizedDescription)"
                print("[MLXSampleApp] Telegram submitPhone error: \(String(reflecting: error))")
            }
        }
#endif
    }

    func submitPassword() {
#if canImport(TDLibKit)
        guard let client else { return }
        let password = twoFactorPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !password.isEmpty else {
            statusText = "Telegram: enter 2FA password"
            return
        }

        Task {
            do {
                _ = try await client.checkAuthenticationPassword(password: password)
                statusText = "Telegram: password submitted"
            } catch {
                statusText = "Telegram 2FA error: \(error.localizedDescription)"
            }
        }
#endif
    }

    func submitForwardedUserResponse(chatId: Int64, text: String) -> Bool {
        let payload = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !payload.isEmpty else { return false }
        guard let waiter = pendingForwardResponseWaiters.removeValue(forKey: chatId) else { return false }
        awaitingForwardUserResponseChats.remove(chatId)
        waiter.resume(returning: "user_response(\(payload))")
        return true
    }

    func tlgMessageResponse(chatId: Int64, text: String) async -> String {
#if canImport(TDLibKit)
        guard let client else { return "fail: TDLib client unavailable" }
        let payload = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !payload.isEmpty else { return "fail: empty text" }

        if awaitingForwardUserResponseChats.contains(chatId) {
            print("[MLXSampleApp] TDLib send blocked: chat is in forward-user handoff state chat=\(chatId)")
            return "fail: awaiting forwarded user response"
        }

        if let prompt = lastForwardPromptByChat[chatId],
           normalizedText(payload) == normalizedText(prompt) {
            print("[MLXSampleApp] TDLib send blocked: payload duplicates forward prompt chat=\(chatId)")
            return "fail: payload duplicates forward prompt"
        }

        print("[MLXSampleApp] TDLib send attempt chat=\(chatId) len=\(payload.count)")

        do {
            _ = try await client.sendMessage(
                chatId: chatId,
                inputMessageContent: .inputMessageText(
                    InputMessageText(
                        clearDraft: false,
                        linkPreviewOptions: nil,
                        text: FormattedText(entities: [], text: payload)
                    )
                ),
                options: nil,
                replyMarkup: nil,
                replyTo: nil,
                topicId: nil
            )
            print("[MLXSampleApp] TDLib send success chat=\(chatId)")
            return "success"
        } catch {
            print("[MLXSampleApp] TDLib send fail chat=\(chatId) error=\(String(reflecting: error))")
            return "fail: \(error.localizedDescription)"
        }
#else
        return "fail: TDLibKit unavailable"
#endif
    }

    func forwardMessageToUser(chatId: Int64, text: String) async -> String {
        postForwardToUserRequested(chatId: chatId, text: text)
        lastForwardPromptByChat[chatId] = text
        awaitingForwardUserResponseChats.insert(chatId)

        if pendingForwardResponseWaiters[chatId] != nil {
            print("[MLXSampleApp] forwardMessageToUser skipped: pending waiter already exists for chat=\(chatId)")
            return "cancelled"
        }

        return await withCheckedContinuation { continuation in
            pendingForwardResponseWaiters[chatId] = continuation

            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 90 * 1_000_000_000)
                if let waiter = pendingForwardResponseWaiters.removeValue(forKey: chatId) {
                    // Keep forward handoff state until an explicit user response arrives.
                    waiter.resume(returning: "dismissed")
                }
            }
        }
    }

    func notifyForwardToUser(chatId: Int64, text: String) {
        postForwardToUserRequested(chatId: chatId, text: text)
    }

    private func postForwardToUserRequested(chatId: Int64, text: String) {
        let payload = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !payload.isEmpty else { return }
        print("[MLXSampleApp] forwardMessageToUserRequested chat=\(chatId) len=\(payload.count)")
        NotificationCenter.default.post(
            name: .forwardMessageToUserRequested,
            object: nil,
            userInfo: [
                "chatId": chatId,
                "text": payload
            ]
        )
    }

    func getUserLocation() async -> String {
#if os(iOS)
        await locationProvider.requestLocationText()
#else
        return "fail: location unsupported on this platform"
#endif
    }

    func expandChatContext(chatId: Int64, fromMessageId: Int64, limit: Int) async -> String {
#if canImport(TDLibKit)
        guard let client else { return "no older messages (fail)" }

        do {
            let messages = try await client.getChatHistory(
                chatId: chatId,
                fromMessageId: fromMessageId,
                limit: max(1, min(limit, 50)),
                offset: 1,
                onlyLocal: false
            ).messages ?? []

            guard !messages.isEmpty else {
                return "no older messages (fail)"
            }

            let lines = messages.prefix(limit).map { formatMessageMetadata($0) }
            return lines.joined(separator: "\n")
        } catch {
            return "no older messages (fail): \(error.localizedDescription)"
        }
#else
        return "no older messages (fail): TDLibKit unavailable"
#endif
    }

    func elaborateRequestToUser(chatId: Int64, text: String) async -> String {
        let payload = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !payload.isEmpty else { return "cancelled" }

        let elaborated = "Let me rephrase clearly:\n\(payload)\n\nPlease reply with the missing details."
        return await tlgMessageResponse(chatId: chatId, text: elaborated)
    }

#if canImport(TDLibKit)
    private func handleUpdate(data: Data, client: TDLibClient) async {
        do {
            let update = try client.decoder.decode(Update.self, from: data)

            switch update {
            case .updateAuthorizationState(let authUpdate):
                await handleAuthorizationState(authUpdate.authorizationState, client: client)

            case .updateNewMessage(let newMessage):
                if let payload = try await inboundPayload(from: newMessage.message, client: client) {
                    if let waiter = pendingForwardResponseWaiters.removeValue(forKey: newMessage.message.chatId) {
                        awaitingForwardUserResponseChats.remove(newMessage.message.chatId)
                        waiter.resume(returning: "user_response(\(payload.text))")
                        return
                    }

                    lastInboundSummary = "chat=\(newMessage.message.chatId) len=\(payload.text.count) image=\(payload.imageData != nil)"
                    print("[MLXSampleApp] Telegram inbound accepted \(lastInboundSummary)")
                    Task { @MainActor in
                        await onInboundMessage(
                            newMessage.message.chatId,
                            newMessage.message.id,
                            payload.text,
                            payload.imageData,
                            self,
                            toolDecisionMode
                        )
                    }
                }

            default:
                break
            }
        } catch {
            statusText = "Telegram update error: \(error.localizedDescription)"
            print("[MLXSampleApp] Telegram update error: \(String(reflecting: error))")
        }
    }

    private func handleAuthorizationState(_ state: AuthorizationState, client: TDLibClient) async {
        switch state {
        case .authorizationStateWaitTdlibParameters:
            await configureTdlib(client: client)

        case .authorizationStateWaitPhoneNumber:
            let phone = phoneNumber.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !phone.isEmpty else {
                statusText = "Telegram: enter phone number"
                return
            }

            do {
                _ = try await client.setAuthenticationPhoneNumber(phoneNumber: phone, settings: nil)
                statusText = "Telegram: code sent"
            } catch {
                statusText = "Telegram phone error: \(error.localizedDescription)"
            }

        case .authorizationStateWaitCode:
            statusText = "Telegram: waiting for login code"
            let code = authCode.trimmingCharacters(in: .whitespacesAndNewlines)
            if !code.isEmpty {
                do {
                    _ = try await client.checkAuthenticationCode(code: code)
                    statusText = "Telegram: code submitted"
                } catch {
                    statusText = "Telegram code error: \(error.localizedDescription)"
                }
            }

        case .authorizationStateWaitPassword:
            statusText = "Telegram: waiting for 2FA password"
            let password = twoFactorPassword.trimmingCharacters(in: .whitespacesAndNewlines)
            if !password.isEmpty {
                do {
                    _ = try await client.checkAuthenticationPassword(password: password)
                    statusText = "Telegram: password submitted"
                } catch {
                    statusText = "Telegram password error: \(error.localizedDescription)"
                }
            }

        case .authorizationStateReady:
            isAuthorized = true
            statusText = "Telegram: connected"
            print("[MLXSampleApp] Telegram authorization ready")

        case .authorizationStateClosing, .authorizationStateClosed:
            isAuthorized = false
            isRunning = false
            statusText = "Telegram: disconnected"

        default:
            statusText = "Telegram: auth state \(String(reflecting: state))"
        }
    }

    private func configureTdlib(client: TDLibClient) async {
        guard let apiId = Int(apiIdText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            statusText = "Telegram: enter valid API ID"
            return
        }

        let hash = apiHash.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !hash.isEmpty else {
            statusText = "Telegram: enter API hash"
            return
        }

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "telegram-tdlib", directoryHint: .isDirectory)
        let dbDir = appSupport.appending(path: "db", directoryHint: .isDirectory)
        let filesDir = appSupport.appending(path: "files", directoryHint: .isDirectory)

        do {
            try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: filesDir, withIntermediateDirectories: true)

            _ = try await client.setTdlibParameters(
                apiHash: hash,
                apiId: apiId,
                applicationVersion: "1.0",
                databaseDirectory: dbDir.path,
                databaseEncryptionKey: Data(),
                deviceModel: "iPhone",
                filesDirectory: filesDir.path,
                systemLanguageCode: Locale.current.language.languageCode?.identifier ?? "en",
                systemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                useChatInfoDatabase: true,
                useFileDatabase: true,
                useMessageDatabase: true,
                useSecretChats: false,
                useTestDc: false
            )
            statusText = "Telegram: TDLib configured"
            print("[MLXSampleApp] Telegram TDLib configured")
        } catch {
            statusText = "Telegram init error: \(error.localizedDescription)"
            print("[MLXSampleApp] Telegram configureTdlib error: \(String(reflecting: error))")
        }
    }

    private func inboundPayload(from message: Message, client: TDLibClient) async throws -> (text: String, imageData: Data?)? {
        guard !message.isOutgoing else { return nil }

        do {
            let chat = try await client.getChat(chatId: message.chatId)
            switch chat.type {
            case .chatTypePrivate, .chatTypeSecret:
                break
            default:
                return nil
            }
        } catch {
            // For a dummy app keep moving if chat metadata lookup fails intermittently.
            print("[MLXSampleApp] Telegram getChat failed for chatId=\(message.chatId): \(String(reflecting: error))")
        }

        switch message.content {
        case .messageText(let text):
            let value = text.text.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return nil }
            return (value, nil)

        case .messagePhoto(let photo):
            let caption = photo.caption.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let imageData = try await downloadLargestPhoto(photo.photo, client: client)
            return (caption.isEmpty ? "<image>" : caption, imageData)

        default:
            return nil
        }
    }

    private func downloadLargestPhoto(_ photo: Photo, client: TDLibClient) async throws -> Data {
        guard let largest = photo.sizes.max(by: { ($0.width * $0.height) < ($1.width * $1.height) }) else {
            throw NSError(domain: "TelegramTDLibBridge", code: 1, userInfo: [NSLocalizedDescriptionKey: "No photo sizes available"])
        }

        var file = largest.photo
        if !(file.local.isDownloadingCompleted && !file.local.path.isEmpty) {
            file = try await client.downloadFile(
                fileId: file.id,
                limit: 0,
                offset: 0,
                priority: 32,
                synchronous: true
            )
        }

        let path = file.local.path
        guard !path.isEmpty else {
            throw NSError(domain: "TelegramTDLibBridge", code: 2, userInfo: [NSLocalizedDescriptionKey: "Downloaded photo has empty local path"])
        }

        return try Data(contentsOf: URL(fileURLWithPath: path))
    }

    private func formatMessageMetadata(_ message: Message) -> String {
        let sender: String = message.isOutgoing ? "assistant" : "user"
        let body: String

        switch message.content {
        case .messageText(let text):
            body = text.text.text
        case .messagePhoto(let photo):
            let caption = photo.caption.text.trimmingCharacters(in: .whitespacesAndNewlines)
            body = caption.isEmpty ? "<photo>" : "<photo> \(caption)"
        default:
            body = "<unsupported-content>"
        }

        return "[id:\(message.id) date:\(message.date) sender:\(sender)] \(body)"
    }

#endif

    private func resolveAllPendingForwardWaiters(with result: String) {
        let waiters = pendingForwardResponseWaiters.values
        pendingForwardResponseWaiters.removeAll(keepingCapacity: false)
        awaitingForwardUserResponseChats.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume(returning: result)
        }
    }

    private func normalizedText(_ text: String) -> String {
        text.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "[^a-z0-9 ]", with: "", options: .regularExpression)
    }
}

#if os(iOS)
private final class IOSLocationProvider: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<String, Never>?
    private var authorizationContinuation: CheckedContinuation<Bool, Never>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    @MainActor
    func requestLocationText() async -> String {
        let status = manager.authorizationStatus

        if status == .denied || status == .restricted {
            return "fail: location permission denied"
        }

        if status == .notDetermined {
            let granted = await requestAuthorizationIfNeeded()
            if !granted {
                return "fail: location permission denied"
            }
        }

        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            manager.requestLocation()

            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 10 * 1_000_000_000)
                if let continuation = self.continuation {
                    self.continuation = nil
                    continuation.resume(returning: "fail: location timeout")
                }
            }
        }
    }

    @MainActor
    private func requestAuthorizationIfNeeded() async -> Bool {
        if manager.authorizationStatus == .authorizedAlways || manager.authorizationStatus == .authorizedWhenInUse {
            return true
        }

        return await withCheckedContinuation { continuation in
            self.authorizationContinuation = continuation
            manager.requestWhenInUseAuthorization()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last, let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: "coordinates: \(location.coordinate.latitude),\(location.coordinate.longitude)")
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Swift.Error) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: "fail: \(error.localizedDescription)")
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard let continuation = authorizationContinuation else { return }
        let status = manager.authorizationStatus
        if status == .authorizedAlways || status == .authorizedWhenInUse {
            authorizationContinuation = nil
            continuation.resume(returning: true)
        } else if status == .denied || status == .restricted {
            authorizationContinuation = nil
            continuation.resume(returning: false)
        }
    }
}
#endif
