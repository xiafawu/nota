import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
  @ObservedObject var model: NotaModel

  var body: some View {
    NavigationSplitView {
      historyPane
        .navigationSplitViewColumnWidth(min: Metrics.sidebarMin, ideal: Metrics.sidebarIdeal, max: Metrics.sidebarMax)
    } detail: {
      mainPane
        .navigationSplitViewColumnWidth(min: Metrics.detailMin, ideal: Metrics.detailIdeal)
        .background(.thinMaterial)
    }
    .toolbar {
      ToolbarItemGroup(placement: .status) {
        if model.isRunning || model.status != "Drop audio to transcribe" {
          HStack(spacing: Metrics.statusHStackSpacing) {
            if model.isRunning {
              ProgressView()
                .controlSize(.small)
            }
            Text(model.status)
              .font(Tokens.statusFont)
              .lineLimit(1)
              .truncationMode(.middle)
          }
          .padding(.horizontal, Metrics.statusPillH)
          .padding(.vertical, Metrics.statusPillV)
          .liquidGlass(.regular.tint(Tokens.toolbarStatusTint), in: .capsule)
          .transition(.opacity.combined(with: .scale))
        }
      }

      ToolbarItem(placement: .primaryAction) {
        Menu {
          Section("Copy") {
            Button {
              model.copyRichText()
            } label: {
              Label("Copy Rich Text", systemImage: "doc.on.clipboard")
            }
            Button {
              model.copyMarkdown()
            } label: {
              Label("Copy Markdown", systemImage: "chevron.left.forwardslash.chevron.right")
            }
          }
          Section("Export") {
            Button {
              model.exportRichText()
            } label: {
              Label("Export Rich Text...", systemImage: "textformat")
            }
            Button {
              model.exportMarkdown()
            } label: {
              Label("Export Markdown...", systemImage: "number")
            }
          }
          Section {
            Button {
              model.revealOutput()
            } label: {
              Label("Reveal in Finder", systemImage: "finder")
            }
            .disabled(model.lastOutputURL == nil)
          }
        } label: {
          Label("Share", systemImage: "square.and.arrow.up")
        }
        .menuIndicator(.hidden)
        .help("Copy, export, or reveal transcript")
        .liquidGlassButton()
        .disabled(model.markdown.isEmpty && model.lastOutputURL == nil)
      }
    }
    .animation(Tokens.animFast, value: model.isRunning)
    .containerBackground(.ultraThinMaterial, for: .window)
    .toolbarBackground(.hidden, for: .windowToolbar)
  }

  private var historyPane: some View {
    VStack(spacing: 0) {
      Button {
        model.newTranscription()
      } label: {
        HStack(spacing: Metrics.newButtonStackSpacing) {
          Image(systemName: "square.and.pencil")
          Text("New Transcription")
            .fontWeight(.medium)
          Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Metrics.newButtonH)
        .padding(.vertical, Metrics.newButtonV)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .liquidGlass(.regular.tint(Tokens.primaryActionTint), in: RoundedRectangle(cornerRadius: Metrics.primaryActionCornerRadius))
      .padding(.horizontal, Metrics.newButtonOuterH)
      .padding(.top, Metrics.newButtonOuterTop)
      .padding(.bottom, Metrics.newButtonOuterBottom)
      .disabled(model.isRunning)

      if model.history.isEmpty {
        Spacer()
        VStack(spacing: Metrics.emptyHistoryStackSpacing) {
          Image(systemName: "tray")
            .font(Tokens.emptyHistoryIconFont)
            .foregroundStyle(.secondary)
          Text("No transcripts yet")
            .font(Tokens.emptyHistoryLabelFont)
            .foregroundStyle(.secondary)
          Text("Drop audio into the main window")
            .font(Tokens.emptyHistoryHelperFont)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
        }
        .padding(.horizontal, Metrics.historyEmptyHorizontalPadding)
        Spacer()
      } else {
        List(selection: $model.selectedHistoryID) {
          Section {
            ForEach(model.history) { entry in
              historyRow(entry)
                .tag(Optional(entry.id))
                .contextMenu {
                  Button {
                    model.openHistory(entry)
                  } label: {
                    Label("Open", systemImage: "doc.text")
                  }
                  Button {
                    NSWorkspace.shared.activateFileViewerSelecting([entry.url])
                  } label: {
                    Label("Reveal in Finder", systemImage: "finder")
                  }
                  Divider()
                  Button(role: .destructive) {
                    model.deleteHistory(entry)
                  } label: {
                    Label("Delete", systemImage: "trash")
                  }
                }
            }
          } header: {
            Text("History")
              .font(Tokens.historySectionFont)
              .foregroundStyle(.secondary)
          }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
      }
    }
    .onChange(of: model.selectedHistoryID) { _, newValue in
      guard let newValue, let entry = model.history.first(where: { $0.id == newValue }) else {
        return
      }
      if entry.url.standardizedFileURL != model.lastOutputURL?.standardizedFileURL {
        model.openHistory(entry)
      }
    }
  }

  private func historyRow(_ entry: HistoryEntry) -> some View {
    VStack(alignment: .leading, spacing: Metrics.tightStackSpacing) {
      Text(entry.title)
        .font(Tokens.historyTitleFont)
        .fontWeight(.medium)
        .lineLimit(1)
        .truncationMode(.middle)
      Text(entry.relativeDate)
        .font(Tokens.historyDateFont)
        .foregroundStyle(.secondary)
    }
    .padding(.vertical, Metrics.historyRowVerticalPadding)
  }

  private var mainPane: some View {
    ZStack {
      if model.hasContent {
        resultPane
      } else {
        emptyState
      }

      if model.isDropTargeted {
        RoundedRectangle(cornerRadius: Metrics.dropFullBleedCornerRadius)
          .strokeBorder(Tokens.dropAccent, lineWidth: Metrics.dropTargetStrokeWidth)
          .allowsHitTesting(false)
          .transition(.opacity)
      }
    }
    .animation(Tokens.animSnap, value: model.isDropTargeted)
    .animation(Tokens.animFast, value: model.hasContent)
    .onDrop(of: [UTType.fileURL.identifier], isTargeted: $model.isDropTargeted) { providers in
      guard let provider = providers.first else {
        return false
      }

      provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
        let url: URL?
        if let data = item as? Data {
          url = URL(dataRepresentation: data, relativeTo: nil)
        } else if let nsURL = item as? NSURL {
          url = nsURL as URL
        } else {
          url = nil
        }

        if let url {
          Task { @MainActor in
            model.accept(url)
          }
        }
      }
      return true
    }
  }

  private var emptyState: some View {
    VStack(spacing: Metrics.emptyMainSpacing) {
      Spacer()

      Image(systemName: model.isRunning ? "waveform" : "tray.and.arrow.down")
        .font(Tokens.emptyMainIconFont)
        .foregroundStyle(model.isDropTargeted ? Tokens.dropAccent : Tokens.emptyIconColor)
        .symbolEffect(.pulse, isActive: model.isRunning)

      VStack(spacing: Metrics.emptyTextSpacing) {
        Text(model.displayName)
          .font(Tokens.emptyMainTitleFont)
          .fontWeight(.bold)
          .foregroundStyle(.primary)
          .multilineTextAlignment(.center)

        Text(model.displayPath)
          .font(Tokens.emptyMainPathFont)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .padding(.horizontal, Metrics.emptySubtextHorizontalPadding)
      }

      Spacer()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(Metrics.emptyMainOuterPadding)
  }

  private var resultPane: some View {
    RichTextViewer(attributedString: model.richText)
  }
}
