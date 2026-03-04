import Foundation

enum AppSecrets {
    static var mistralAPIKey: String? {
        value(for: "MISTRAL_API_KEY")
    }

    static var elevenLabsAPIKey: String? {
        value(for: "ELEVENLABS_API_KEY")
    }

    static var huggingFaceToken: String {
        value(for: "HUGGINGFACE_TOKEN") ?? value(for: "HF_TOKEN") ?? ""
    }

    private static let dotenv: [String: String] = DotEnvLoader.load()

    static func value(for key: String) -> String? {
        if let envValue = ProcessInfo.processInfo.environment[key], !envValue.isEmpty {
            return envValue
        }

        if let dotenvValue = dotenv[key], !dotenvValue.isEmpty {
            return dotenvValue
        }

        if let plistValue = Bundle.main.object(forInfoDictionaryKey: key) as? String, !plistValue.isEmpty {
            return plistValue
        }

        return nil
    }
}

private enum DotEnvLoader {
    static func load() -> [String: String] {
        var merged: [String: String] = [:]
        for url in candidateURLs() {
            guard let parsed = parseFile(at: url) else { continue }
            for (key, value) in parsed where merged[key] == nil {
                merged[key] = value
            }
        }
        return merged
    }

    private static func candidateURLs() -> [URL] {
        var urls: [URL] = []
        let fm = FileManager.default
        let env = ProcessInfo.processInfo.environment

        if let explicitPath = env["TEST_ENV_PATH"], !explicitPath.isEmpty {
            urls.append(URL(fileURLWithPath: explicitPath))
        } else if let explicitPath = Bundle.main.object(forInfoDictionaryKey: "TEST_ENV_PATH") as? String, !explicitPath.isEmpty {
            urls.append(URL(fileURLWithPath: explicitPath))
        }

        urls.append(fm.currentDirectoryPathURL.appendingPathComponent(".env"))
        urls.append(fm.currentDirectoryPathURL.appendingPathComponent("test.env"))

        if let bundleDotEnv = Bundle.main.url(forResource: ".env", withExtension: nil) {
            urls.append(bundleDotEnv)
        }
        if let bundleTestEnv = Bundle.main.url(forResource: "test", withExtension: "env") {
            urls.append(bundleTestEnv)
        }

        return urls
    }

    private static func parseFile(at url: URL) -> [String: String]? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var values: [String: String] = [:]

        for line in content.split(whereSeparator: \.isNewline) {
            let rawLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawLine.isEmpty else { continue }
            guard !rawLine.hasPrefix("#") else { continue }

            let normalized = rawLine.hasPrefix("export ") ? String(rawLine.dropFirst(7)) : rawLine
            guard let equalsIndex = normalized.firstIndex(of: "=") else { continue }

            let key = String(normalized[..<equalsIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            var value = String(normalized[normalized.index(after: equalsIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)

            guard !key.isEmpty else { continue }

            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            } else if value.hasPrefix("'"), value.hasSuffix("'"), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }

            values[key] = value
        }

        return values
    }
}

private extension FileManager {
    var currentDirectoryPathURL: URL {
        URL(fileURLWithPath: currentDirectoryPath, isDirectory: true)
    }
}
