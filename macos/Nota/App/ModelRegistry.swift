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
  /// Keyless static fallback for callers that need one id without inspecting
  /// the key store (e.g. dictation polish). The Models UI and summary
  /// resolution use the key-aware `defaultSummaryModel(keyConfigured:)` chain.
  static let defaultSummaryModel = "gpt-5-mini"

  /// Preference order for the app's summary default when nothing is pinned:
  /// the first entry whose provider key is configured wins. Mirrors the TS
  /// key-aware chain shape as far as the UI needs.
  static let summaryDefaultChain = ["deepseek-v4-flash", "gpt-5.4-mini", "gemini-3.6-flash"]

  // Transcription models stay static (never sourced from the catalog).
  // slam-1 and nano were removed (vendor-retired).
  private static let transcriptionModels: [ModelEntry] = [
    ModelEntry(id: "universal", task: .transcription, provider: .assemblyai, label: "Universal (AssemblyAI)"),
    ModelEntry(id: "whisper-1", task: .transcription, provider: .openai, label: "Whisper (OpenAI)"),
    ModelEntry(id: "gpt-4o-transcribe", task: .transcription, provider: .openai, label: "GPT-4o Transcribe (OpenAI)"),
    ModelEntry(id: "gpt-4o-mini-transcribe", task: .transcription, provider: .openai, label: "GPT-4o mini Transcribe (OpenAI)"),
  ]

  // Summary models come from the catalog. `all` carries the baked snapshot so
  // model(id:) / models(for:) keep working for non-UI call sites; the Models
  // tab picker reads the live catalog store instead.
  static let all: [ModelEntry] = transcriptionModels + ModelCatalogLoader.bakedSnapshot.summaryModelEntries()

  static func models(for task: ModelTask) -> [ModelEntry] {
    all.filter { $0.task == task }
  }

  static func model(id: String) -> ModelEntry? {
    all.first { $0.id == id }
  }

  static func defaultModel(for task: ModelTask) -> String {
    task == .transcription ? defaultTranscriptionModel : defaultSummaryModel
  }

  /// The app's summary default: the first chain entry whose provider key is
  /// configured, else the ultimate fallback (`deepseek-v4-flash`).
  static func defaultSummaryModel(keyConfigured: (ModelProvider) -> Bool) -> String {
    for id in summaryDefaultChain {
      if let entry = model(id: id), keyConfigured(entry.provider) {
        return id
      }
    }
    return summaryDefaultChain.first ?? "deepseek-v4-flash"
  }
}
