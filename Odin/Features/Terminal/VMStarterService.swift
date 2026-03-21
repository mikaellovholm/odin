import Foundation

enum VMStarterService {
    private static let endpoint = URL(
        string: "https://europe-north1-claude-dev-ml-01.cloudfunctions.net/claude-dev-starter"
    )!

    struct VMResponse: Decodable {
        let status: String
        let ip: String
    }

    static func startAndWaitForIP() async throws -> String {
        let maxAttempts = 20  // 20 × 3s = 60s timeout
        for attempt in 1...maxAttempts {
            let response = try await callFunction()
            if response.status == "running" {
                return response.ip
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
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw VMStarterError.httpError(statusCode: statusCode)
        }
        return try decoder.decode(VMResponse.self, from: data)
    }

    enum VMStarterError: LocalizedError {
        case httpError(statusCode: Int)
        case timeout

        var errorDescription: String? {
            switch self {
            case .httpError(let code): "Cloud Function error (HTTP \(code))"
            case .timeout: "VM did not become ready within 60 seconds"
            }
        }
    }
}
