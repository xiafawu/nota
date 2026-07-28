import Foundation

// Mirror of the TypeScript model registry. The canonical source of truth is
// `src/registry.ts` (+ `src/model-id.ts`, `src/openrouter.ts`); keep this file
// in sync with them. Provider is always derived from the model id — it is never
// stored or user-chosen (ADR 0001, 0002).

enum ModelTask: String {
  case transcription
  case summary
}

enum ModelProvider: String, CaseIterable {
  case assemblyai
  case openai
  case gemini
  case deepseek
  case openrouter

  var displayName: String {
    switch self {
    case .assemblyai: return "AssemblyAI"
    case .openai: return "OpenAI"
    case .gemini: return "Gemini"
    case .deepseek: return "DeepSeek"
    case .openrouter: return "OpenRouter"
    }
  }

  /// Env var / ~/.nota/config key holding this provider's API key.
  var apiKeyEnv: String {
    switch self {
    case .assemblyai: return "ASSEMBLYAI_API_KEY"
    case .openai: return "OPENAI_API_KEY"
    case .gemini: return "GEMINI_API_KEY"
    case .deepseek: return "DEEPSEEK_API_KEY"
    case .openrouter: return "OPENROUTER_API_KEY"
    }
  }
}

/// How a model runs (ADR 0002). Mirrors `ExecutionKind` in `src/model-id.ts`.
/// `http` is an OpenAI-compatible endpoint reached with an API key; `cli` is a
/// local subprocess (no members yet — ADR 0003). Surfaces that cannot host a
/// subprocess filter on this **structurally**; matching on id prefixes is
/// explicitly not the mechanism.
enum ExecutionKind: String, Codable, Hashable {
  case http
  case cli
}

/// The id grammar, mirroring `src/model-id.ts`. A model id is one string that
/// fully names a summarizer: flat (`gpt-5-mini`) or namespaced
/// (`openrouter/anthropic/claude-sonnet-5`).
enum ModelID {
  /// The first path segment of a namespaced id, or nil for a flat one.
  static func namespace(of id: String) -> String? {
    guard let slash = id.firstIndex(of: "/"), slash != id.startIndex else { return nil }
    return String(id[id.startIndex..<slash])
  }

  /// Derive the provider. The namespace decides for a namespaced id, and an
  /// unregistered namespace is a rejection rather than a fallback to
  /// `declared` — an id naming a provider the app does not have is not a model
  /// it can run. A flat id keeps the lookup it always had.
  static func provider(for id: String, declared: String?) -> ModelProvider? {
    if let namespace = namespace(of: id) {
      return ModelProvider(rawValue: namespace)
    }
    guard let declared else { return nil }
    return ModelProvider(rawValue: declared)
  }

  /// The model string the provider's own API expects: the canonical id with a
  /// known provider namespace stripped, exactly once. OpenRouter is asked for
  /// `anthropic/claude-sonnet-5`, not `openrouter/anthropic/claude-sonnet-5`.
  static func wire(_ id: String) -> String {
    guard let namespace = namespace(of: id),
          ModelProvider(rawValue: namespace) != nil
    else { return id }
    return String(id.dropFirst(namespace.count + 1))
  }
}

struct ModelEntry: Identifiable, Hashable {
  let id: String
  let task: ModelTask
  let provider: ModelProvider
  let label: String
  /// Everything the app ships is `http`; the field exists so surfaces can
  /// exclude other kinds structurally when they arrive.
  let execution: ExecutionKind

  init(
    id: String,
    task: ModelTask,
    provider: ModelProvider,
    label: String,
    execution: ExecutionKind = .http
  ) {
    self.id = id
    self.task = task
    self.provider = provider
    self.label = label
    self.execution = execution
  }

  /// The id as this model's own API names it. See `ModelID.wire`.
  var wireID: String { ModelID.wire(id) }
}

/// A summary engine that is a local subprocess rather than an endpoint
/// (ADR 0003). Id plus the name a person reads — there is nothing else about it
/// the app can know: no provider, no key, no price.
struct CLIEngineModel: Identifiable, Hashable {
  let id: String
  let label: String
}

/// One labelled row in a model picker: the id that gets persisted and the text
/// the owner reads.
struct ModelPickerItem: Identifiable, Hashable {
  let id: String
  let label: String
}

/// One `Section` of a model picker. Grouped by provider for everything that has
/// one, plus a trailing group for the CLI engines, which do not.
struct ModelPickerGroup: Identifiable, Hashable {
  /// The section heading, which is also unique within a picker.
  let title: String
  let items: [ModelPickerItem]

  var id: String { title }
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

  /// The CLI engines as the Models tab offers them, mirroring the order and the
  /// membership of `CLI_ENGINE_MODELS` in `src/cli-engines.ts` — that file is
  /// the source of truth, this is the copy.
  ///
  /// Not `ModelEntry` values, and deliberately so. A CLI engine has no
  /// `ModelProvider`: no API key, no base URL, no key row to show in the API
  /// Keys tab. Inventing a provider case for one would put a "paste your key"
  /// field under a login that lives in the CLI's own config, and
  /// `ModelProvider.allCases` is what builds that tab. They are also not
  /// catalog rows: `ModelCatalog.contains` answers "is this a live
  /// auto-admitted/curated pin", and these are neither.
  ///
  /// ADR 0003 as amended 2026-07-28: they may be pinned as the **summary**
  /// model from the app, because the app's summary path shells out to the TS
  /// pipeline (`nota-app-run.sh`), which is the CLI path. They still may not
  /// reach any dictation-polish surface — that exclusion is `httpModels(for:)`,
  /// and it is structural: these never become `ModelEntry` values at all.
  static let cliEngineModels: [CLIEngineModel] = [
    CLIEngineModel(id: "claude-code/sonnet", label: "Claude Sonnet (subscription)"),
    CLIEngineModel(id: "claude-code/opus", label: "Claude Opus (subscription)"),
    CLIEngineModel(id: "claude-code/haiku", label: "Claude Haiku (subscription)"),
    CLIEngineModel(id: "codex/gpt-5.6-sol", label: "Codex GPT-5.6 Sol (subscription)"),
    CLIEngineModel(id: "codex/gpt-5.6-terra", label: "Codex GPT-5.6 Terra (subscription)"),
    CLIEngineModel(id: "codex/gpt-5.6-luna", label: "Codex GPT-5.6 Luna (subscription)"),
    CLIEngineModel(id: "codex/gpt-5.4-mini", label: "Codex GPT-5.4 Mini (subscription)"),
  ]

  /// The CLI-engine ids. Derived from `cliEngineModels` rather than written a
  /// second time: the shared `~/.nota/settings.json` can hold one of these as a
  /// perfectly valid summary pin, and a set that had drifted from the picker
  /// would make the Models pane call a model it just offered "retired".
  static let cliEngineModelIDs: Set<String> = Set(cliEngineModels.map(\.id))

  /// Section title the CLI engines sit under in the summary picker.
  static let cliEngineGroupTitle = "Subscription CLIs"

  /// What the Models tab says under the summary picker about that group.
  static let cliEngineFooter = """
    Subscription CLIs run through the `claude` or `codex` command installed on \
    this Mac and are billed to that subscription, not to an API key. They need \
    the binary on your PATH and an active login, and they take minutes rather \
    than seconds.
    """

  /// The OpenRouter shortlist, mirroring `OPENROUTER_MODELS` in
  /// `src/openrouter.ts` — that file is the source of truth, this is the copy.
  /// Slugs were verified against a live `GET https://openrouter.ai/api/v1/models`
  /// on 2026-07-27; they are the undated canonical ones. Hand-picked rather than
  /// auto-admitted for the same reason as on the CLI side: OpenRouter lists
  /// 300+ ids and a picker is not a catalog browser.
  ///
  /// Modelled as catalog rows, not as `ModelEntry` values, so they take exactly
  /// the same decode path (provider derivation, execution kind) as everything
  /// read off disk — one bridge, not two.
  static let openRouterModels: [CatalogModel] = [
    curated("openrouter/anthropic/claude-sonnet-5", "Claude Sonnet 5 (OpenRouter)", 1_000_000),
    curated("openrouter/anthropic/claude-haiku-4.5", "Claude Haiku 4.5 (OpenRouter)", 200_000),
    curated("openrouter/moonshotai/kimi-k2.6", "Kimi K2.6 (OpenRouter)", 262_144),
    curated("openrouter/qwen/qwen3.7-max", "Qwen3.7 Max (OpenRouter)", 1_000_000),
    curated("openrouter/z-ai/glm-5.2", "GLM 5.2 (OpenRouter)", 1_048_576),
    curated("openrouter/meta-llama/llama-4-maverick", "Llama 4 Maverick (OpenRouter)", 1_048_576),
  ]

  private static func curated(_ id: String, _ label: String, _ context: Int) -> CatalogModel {
    CatalogModel(
      id: id,
      provider: "openrouter",
      label: label,
      task: "summary",
      // No cost: Nota stores no OpenRouter pricing (see src/openrouter.ts).
      cost: nil,
      costNote: "refer to OpenRouter",
      limit: CatalogLimit(context: context),
      execution: .http,
      origin: .curated
    )
  }

  // Summary models come from the catalog. `all` carries the baked snapshot so
  // model(id:) / models(for:) keep working for non-UI call sites; the Models
  // tab picker reads the live catalog store instead. Both go through
  // `mergingCurated` so the shortlist is present either way.
  static let all: [ModelEntry] =
    transcriptionModels + ModelCatalogLoader.bakedSnapshot.mergingCurated().summaryModelEntries()

  static func models(for task: ModelTask) -> [ModelEntry] {
    all.filter { $0.task == task }
  }

  /// Models a surface may run in-process over HTTP. The dictation polish picker
  /// filters on this — on the execution kind, never on the id (ADR 0002) — so a
  /// catalog refresh can never leak a subprocess engine into a per-sentence
  /// streaming path.
  static func httpModels(for task: ModelTask) -> [ModelEntry] {
    models(for: task).filter { $0.execution == .http }
  }

  static func model(id: String) -> ModelEntry? {
    all.first { $0.id == id }
  }

  /// The groups a model picker shows, in order: one per provider in the order
  /// the entries introduce them, then — when asked for — the CLI engines.
  ///
  /// Pure and shared by both pickers in the Models tab, so "the summary picker
  /// offers every CLI engine, after the catalog, and the transcription picker
  /// offers none" is one assertion about one function rather than a claim about
  /// a `View`'s body. `appendingCLIEngines` is passed explicitly at each call
  /// site: a surface that can host a subprocess has to say so.
  static func pickerGroups(
    for entries: [ModelEntry],
    appendingCLIEngines: Bool = false
  ) -> [ModelPickerGroup] {
    var order: [ModelProvider] = []
    for entry in entries where !order.contains(entry.provider) { order.append(entry.provider) }
    var groups = order.map { provider in
      ModelPickerGroup(
        title: provider.displayName,
        items: entries
          .filter { $0.provider == provider }
          .map { ModelPickerItem(id: $0.id, label: $0.label) }
      )
    }
    guard appendingCLIEngines else { return groups }
    groups.append(
      ModelPickerGroup(
        title: cliEngineGroupTitle,
        items: cliEngineModels.map { ModelPickerItem(id: $0.id, label: $0.label) }
      )
    )
    return groups
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
