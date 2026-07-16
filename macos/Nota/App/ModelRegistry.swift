import Foundation

// Mirror of the TypeScript model registry. The canonical source of truth is
// `src/registry.ts`; keep this list in sync with it. Provider is always derived
// from the model id — it is never stored or user-chosen.

enum ModelTask: String {
  case transcription
  case summary
}

enum ModelProvider: String {
  case assemblyai
  case openai
  case gemini
  case deepseek

  var displayName: String {
    switch self {
    case .assemblyai: return "AssemblyAI"
    case .openai: return "OpenAI"
    case .gemini: return "Gemini"
    case .deepseek: return "DeepSeek"
    }
  }

  /// Env var / ~/.nota/config key holding this provider's API key.
  var apiKeyEnv: String {
    switch self {
    case .assemblyai: return "ASSEMBLYAI_API_KEY"
    case .openai: return "OPENAI_API_KEY"
    case .gemini: return "GEMINI_API_KEY"
    case .deepseek: return "DEEPSEEK_API_KEY"
    }
  }
}

struct ModelEntry: Identifiable, Hashable {
  let id: String
  let task: ModelTask
  let provider: ModelProvider
  let label: String
}

enum ModelRegistry {
  static let defaultTranscriptionModel = "universal"
  static let defaultSummaryModel = "gpt-5-mini"

  static let all: [ModelEntry] = [
    // Transcription
    ModelEntry(id: "universal", task: .transcription, provider: .assemblyai, label: "Universal (AssemblyAI)"),
    ModelEntry(id: "slam-1", task: .transcription, provider: .assemblyai, label: "Slam-1 (AssemblyAI)"),
    ModelEntry(id: "nano", task: .transcription, provider: .assemblyai, label: "Nano (AssemblyAI)"),
    ModelEntry(id: "whisper-1", task: .transcription, provider: .openai, label: "Whisper (OpenAI)"),
    ModelEntry(id: "gpt-4o-transcribe", task: .transcription, provider: .openai, label: "GPT-4o Transcribe (OpenAI)"),
    ModelEntry(id: "gpt-4o-mini-transcribe", task: .transcription, provider: .openai, label: "GPT-4o mini Transcribe (OpenAI)"),
    // Summary
    ModelEntry(id: "gpt-5-mini", task: .summary, provider: .openai, label: "GPT-5 mini (OpenAI)"),
    ModelEntry(id: "gpt-5", task: .summary, provider: .openai, label: "GPT-5 (OpenAI)"),
    ModelEntry(id: "gpt-4o", task: .summary, provider: .openai, label: "GPT-4o (OpenAI)"),
    ModelEntry(id: "gpt-4.1", task: .summary, provider: .openai, label: "GPT-4.1 (OpenAI)"),
    ModelEntry(id: "gemini-2.5-flash", task: .summary, provider: .gemini, label: "Gemini 2.5 Flash (Google)"),
    ModelEntry(id: "gemini-2.5-pro", task: .summary, provider: .gemini, label: "Gemini 2.5 Pro (Google)"),
    ModelEntry(id: "deepseek-v4-flash", task: .summary, provider: .deepseek, label: "DeepSeek V4 Flash (DeepSeek)"),
    ModelEntry(id: "deepseek-v4-pro", task: .summary, provider: .deepseek, label: "DeepSeek V4 Pro (DeepSeek)"),
  ]

  static func models(for task: ModelTask) -> [ModelEntry] {
    all.filter { $0.task == task }
  }

  static func model(id: String) -> ModelEntry? {
    all.first { $0.id == id }
  }

  static func defaultModel(for task: ModelTask) -> String {
    task == .transcription ? defaultTranscriptionModel : defaultSummaryModel
  }
}
