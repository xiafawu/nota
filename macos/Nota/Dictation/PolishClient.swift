import Foundation
import os

// MARK: - PolishClient

/// OpenAI-compatible chat client for polishing dictation output.
///
/// Reads the selected model from `ModelRegistry` and the API key from
/// `ApiKeyStore`. Respects per-provider base URLs (Gemini, DeepSeek)
/// mirrored from `src/registry.ts`.
///
/// If the key or network call fails, the caller (DictationController) falls
/// back to the rules-only result.
enum PolishClient {
  private static let logger = Logger(
    subsystem: "com.xiafawu.nota",
    category: "dictation.polish"
  )

  /// Base URLs for providers that use an OpenAI-compatible endpoint.
  /// Mirrors `src/registry.ts` BASE_URL map.
  private static let baseURLs: [ModelProvider: String] = [
    .gemini: "https://generativelanguage.googleapis.com/v1beta/openai/",
    .deepseek: "https://api.deepseek.com",
  ]

  /// The default base URL for OpenAI models.
  private static let openAIBaseURL = "https://api.openai.com/v1"

  /// Polish `text` using the model identified by `modelID`.
  /// - Returns: The polished text, or `nil` if the call fails.
  /// - Throws: `PolishError` when the key is missing, the network fails, or
  ///   the response is malformed.
  static func polish(_ text: String, modelID: String) async throws -> String {
    guard let entry = ModelRegistry.model(id: modelID), entry.task == .summary else {
      throw PolishError.invalidModel(modelID)
    }

    let keyEnv = entry.provider.apiKeyEnv

    guard let key = ApiKeyStore.value(for: keyEnv) else {
      throw PolishError.missingKey(entry.provider.displayName)
    }

    let baseURL = baseURLs[entry.provider] ?? openAIBaseURL
    let url = URL(string: baseURL)!
      .appendingPathComponent("chat/completions")

    let systemPrompt = """
    You are an assistant that lightly polishes dictated text for readability. \
    Fix minor grammar issues, remove repetitions, and improve punctuation. \
    Do NOT change the meaning, tone, or technical terms. \
    Do NOT add content that was not dictated. \
    Preserve the speaker's voice and word choices.
    """

    let body: [String: Any] = [
      "model": entry.id,
      "messages": [
        ["role": "system", "content": systemPrompt],
        ["role": "user", "content": text],
      ],
      "temperature": 0.3,
      "max_tokens": text.count * 2,
    ]

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    request.timeoutInterval = 15

    logger.info("Polishing with model=\(entry.id, privacy: .public) provider=\(entry.provider.rawValue, privacy: .public)")

    let (data, response): (Data, URLResponse)
    do {
      (data, response) = try await URLSession.shared.data(for: request)
    } catch {
      throw PolishError.network(error.localizedDescription)
    }

    guard let httpResponse = response as? HTTPURLResponse else {
      throw PolishError.invalidResponse("not an HTTP response")
    }

    guard (200..<300).contains(httpResponse.statusCode) else {
      let bodyStr = String(data: data, encoding: .utf8) ?? "<no body>"
      logger.error("polish HTTP \(httpResponse.statusCode): \(bodyStr, privacy: .public)")
      throw PolishError.httpError(httpResponse.statusCode, bodyStr)
    }

    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let choices = json["choices"] as? [[String: Any]],
          let first = choices.first,
          let message = first["message"] as? [String: Any],
          let content = message["content"] as? String
    else {
      throw PolishError.invalidResponse("unexpected response shape")
    }

    return content
  }

}

// MARK: - Errors

enum PolishError: LocalizedError {
  case invalidModel(String)
  case missingKey(String)
  case network(String)
  case httpError(Int, String)
  case invalidResponse(String)

  var errorDescription: String? {
    switch self {
    case .invalidModel(let id):
      return "Unknown polish model: \(id)"
    case .missingKey(let provider):
      return "API key missing for \(provider). Add it in Settings → API Keys."
    case .network(let detail):
      return "Network error during polish: \(detail)"
    case .httpError(let code, let body):
      return "Polishing failed (HTTP \(code)): \(body)"
    case .invalidResponse(let detail):
      return "Unexpected polish response: \(detail)"
    }
  }
}
