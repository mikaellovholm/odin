import Foundation

enum VMStarterService {
    private static let endpoint = URL(
        string: "https://europe-north1-claude-dev-ml-01.cloudfunctions.net/claude-dev-starter"
    )!

    struct VMResponse: Decodable {
        let status: String
        let ip: String
        let hostKey: String?
    }

    struct VMResult {
        let ip: String
        let hostKey: String
    }

    static func startAndWaitForIP() async throws -> VMResult {
        let maxAttempts = 20  // 20 × 3s = 60s timeout
        for attempt in 1...maxAttempts {
            let response = try await callFunction()
            if response.status == "running" {
                guard let hostKey = response.hostKey, !hostKey.isEmpty else {
                    throw VMStarterError.missingHostKey
                }
                return VMResult(ip: response.ip, hostKey: hostKey)
            }
            // VM is starting — wait before polling again
            if attempt < maxAttempts {
                try await Task.sleep(for: .seconds(3))
            }
        }
        throw VMStarterError.timeout
    }

    private static let decoder = JSONDecoder()

    private static func callFunction() async throws -> VMResponse {
        guard let apiKey = APIKeyManager.get() else {
            throw VMStarterError.missingAPIKey
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw VMStarterError.httpError(statusCode: -1)
        }
        if http.statusCode == 429 {
            let retryAfter = (http.value(forHTTPHeaderField: "Retry-After")).flatMap(Int.init)
            throw VMStarterError.rateLimited(retryAfter: retryAfter)
        }
        guard http.statusCode == 200 else {
            throw VMStarterError.httpError(statusCode: http.statusCode)
        }
        return try decoder.decode(VMResponse.self, from: data)
    }

    enum VMStarterError: LocalizedError {
        case httpError(statusCode: Int)
        case timeout
        case missingAPIKey
        case missingHostKey
        case rateLimited(retryAfter: Int?)

        var errorDescription: String? {
            switch self {
            case .httpError(let code):
                return "Cloud Function error (HTTP \(code))"
            case .timeout:
                return "VM did not become ready within 60 seconds"
            case .missingAPIKey:
                return "API key not configured. Set it in Remote settings."
            case .missingHostKey:
                return "VM did not return SSH host key"
            case .rateLimited(let retryAfter):
                if let retryAfter {
                    return "Too many VM starts. Try again in \(retryAfter)s."
                }
                return "Too many VM starts. Try again later."
            }
        }
    }
}
