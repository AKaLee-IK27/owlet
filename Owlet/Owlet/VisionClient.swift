import Foundation

/// Swift-native Ollama client for vision models.
/// Sends base64-encoded images via the /api/chat endpoint.
final class VisionClient: @unchecked Sendable {

    enum Failure: Error, Equatable {
        case timeout
        case emptyOutput
        case backendError(String)
        case launchFailed(String)
        case modelNotFound(String)
    }

    private let model: String
    private let timeoutSeconds: TimeInterval

    init(model: String, timeoutSeconds: TimeInterval = 60) {
        self.model = model
        self.timeoutSeconds = timeoutSeconds
    }

    /// Send an image to the vision model and return the rewritten text.
    func rewrite(imageData: Data) async throws -> String {
        let payload = Self.buildPayload(imageData: imageData, model: model)
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload) else {
            throw Failure.launchFailed("Failed to serialize payload")
        }

        let url = URL(string: "http://localhost:11434/api/chat")!
        let (data, response) = try await withTimeout(timeoutSeconds) {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = jsonData
            return try await URLSession.shared.data(for: req)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw Failure.backendError("No HTTP response")
        }

        if httpResponse.statusCode == 404 {
            let body = String(data: data, encoding: .utf8) ?? ""
            if body.contains("not found") || body.contains("does not exist") {
                throw Failure.modelNotFound(model)
            }
        }

        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw Failure.backendError("HTTP \(httpResponse.statusCode): \(body)")
        }

        guard let text = Self.parseResponse(String(data: data, encoding: .utf8) ?? "") else {
            throw Failure.backendError("Failed to parse Ollama response")
        }

        let cleaned = CleanOutput.clean(text)
        if cleaned.isEmpty {
            throw Failure.emptyOutput
        }
        return cleaned
    }

    /// Build the JSON payload for the Ollama vision API.
    static func buildPayload(imageData: Data, model: String) -> [String: Any] {
        let systemPrompt = "You are a text extraction and rewriting assistant. Look at the screenshot the user provides. Extract ALL visible text from the image. Then rewrite that text to be clearer and better structured, following prompt engineering best practices. Preserve the original language. Output ONLY the rewritten text — no explanation, no preamble."

        return [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                [
                    "role": "user",
                    "content": "Extract and rewrite the text in this image.",
                    "images": [imageData.base64EncodedString()]
                ]
            ],
            "stream": false,
            "options": ["temperature": 0.2]
        ]
    }

    /// Parse the Ollama JSON response to extract message.content.
    static func parseResponse(_ body: String) -> String? {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? [String: Any],
              let content = message["content"] as? String else {
            return nil
        }
        return content
    }

    private func withTimeout<T: Sendable>(_ seconds: TimeInterval, operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw Failure.timeout
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}
