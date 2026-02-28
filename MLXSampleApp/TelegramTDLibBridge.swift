import Foundation

#if canImport(TDLibKit)
import TDLibKit
#endif

@MainActor
@Observable
final class TelegramTDLibBridge {
    var apiIdText: String = ""
    var apiHash: String = ""
    var phoneNumber: String = ""
    var authCode: String = ""
    var twoFactorPassword: String = ""

    var isRunning: Bool = false
    var isAuthorized: Bool = false
    var statusText: String = "Telegram: disconnected"
    var lastInboundSummary: String = "No inbound message yet"

    private let onInboundMessage: @MainActor (_ text: String, _ imageData: Data?) async -> Void

#if canImport(TDLibKit)
    private var manager: TDLibClientManager?
    private var client: TDLibClient?
#endif

    init(onInboundMessage: @escaping @MainActor (_ text: String, _ imageData: Data?) async -> Void) {
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

        Task.detached {
            if let activeClient {
                try? await activeClient.close()
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

#if canImport(TDLibKit)
    private func handleUpdate(data: Data, client: TDLibClient) async {
        do {
            let update = try client.decoder.decode(Update.self, from: data)

            switch update {
            case .updateAuthorizationState(let authUpdate):
                await handleAuthorizationState(authUpdate.authorizationState, client: client)

            case .updateNewMessage(let newMessage):
                if let payload = try await inboundPayload(from: newMessage.message, client: client) {
                    lastInboundSummary = "chat=\(newMessage.message.chatId) len=\(payload.text.count) image=\(payload.imageData != nil)"
                    print("[MLXSampleApp] Telegram inbound accepted \(lastInboundSummary)")
                    Task { @MainActor in
                        await onInboundMessage(payload.text, payload.imageData)
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
#endif
}
