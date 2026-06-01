import Foundation

/// Whether the caret sits between words (suggest a continuation) or inside a
/// half-typed word (complete just that word). Decided from the character before
/// the caret — see `AutocompleteController.detectMode`.
enum SuggestionMode: Equatable {
    case continuation
    case wordCompletion
}

protocol Predicting: Sendable {
    func suggest(prefix: String, mode: SuggestionMode, model: String, maxTokens: Int) async throws -> String
}

/// Tiny raw-completion client for autocomplete. Uses Ollama's `/api/generate`
/// rather than chat so the model returns only a short continuation.
struct OllamaPredictor: Predicting {
    enum Failure: Error, Equatable {
        case invalidURL
        case badStatus(Int)
        case emptyResponse
    }

    private let endpoint: URL
    private let session: URLSession

    init(endpoint: URL = URL(string: "http://127.0.0.1:11434/api/generate")!,
         session: URLSession = .shared) {
        self.endpoint = endpoint
        self.session = session
    }

    func suggest(prefix: String, mode: SuggestionMode, model: String, maxTokens: Int) async throws -> String {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Same instructed prompt for both modes (qwen2.5:1.5b is instruct-tuned, so
        // a raw prefix yields chat noise). Word completion just adds a space to the
        // stop set so generation halts after finishing the current word.
        let stop = mode == .wordCompletion ? [" ", "\n"] : ["\n"]
        request.httpBody = try JSONEncoder().encode(RequestBody(
            model: model,
            prompt: Self.prompt(for: prefix),
            stream: false,
            keepAlive: "24h",
            options: Options(numPredict: maxTokens, temperature: 0.2, stop: stop)
        ))

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Failure.badStatus(http.statusCode)
        }
        let decoded = try JSONDecoder().decode(ResponseBody.self, from: data)
        let suggestion = decoded.response.trimmingCharacters(in: .whitespacesAndNewlines)
        if suggestion.isEmpty { throw Failure.emptyResponse }
        return suggestion
    }

    private static func prompt(for prefix: String) -> String {
        """
        Continue the user's text with a short inline completion.
        Output only the continuation. Do not repeat the prefix. Stop after a few words.

        Prefix:
        \(prefix)
        """
    }

    private struct RequestBody: Encodable {
        let model: String
        let prompt: String
        let stream: Bool
        let keepAlive: String
        let options: Options

        enum CodingKeys: String, CodingKey {
            case model, prompt, stream, options
            case keepAlive = "keep_alive"
        }
    }

    private struct Options: Encodable {
        let numPredict: Int
        let temperature: Double
        let stop: [String]

        enum CodingKeys: String, CodingKey {
            case temperature, stop
            case numPredict = "num_predict"
        }
    }

    private struct ResponseBody: Decodable {
        let response: String
    }
}
