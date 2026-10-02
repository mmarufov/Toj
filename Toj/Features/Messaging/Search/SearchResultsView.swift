import SwiftUI

/// The search screen's result list: chat rows, message rows, coverage, and empty states.
///
/// Every scope gets a real answer. Media, Files and Links browse before the user types, and none of
/// them can render blank the way the demo-only pills used to — an empty tab reads as broken, not as
/// "nothing here".
struct SearchResultsView: View {
    @Bindable var controller: MessageSearchController
    let onOpenDialog: (String) -> Void
    let onOpenMessage: (MessageSearchHit) -> Void

    var body: some View {
        List {
            if let message = controller.partialCoverageMessage {
                coverageBanner(message)
            }

            if !controller.sections.chats.isEmpty {
                Section(controller.scope == .people ? "People" : "Chats") {
                    ForEach(controller.sections.chats) { dialog in
                        Button { onOpenDialog(dialog.id) } label: {
                            CloudDialogRow(dialog: dialog)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("search-chat-\(dialog.id)")
                    }
                }
            }

            if !controller.sections.messages.isEmpty {
                Section(controller.scope == .messages ? "Messages" : controller.scope.title) {
                    ForEach(controller.sections.messages) { hit in
                        Button { onOpenMessage(hit) } label: {
                            MessageSearchRow(
                                hit: hit,
                                text: controller.displayText(for: hit),
                                highlights: controller.highlightRanges(in: hit)
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("search-message-\(hit.docId)")
                        .onAppear {
                            // Paginate from the tail rather than a "load more" button: the list is
                            // scanned, not read, and a button interrupts that.
                            if hit.id == controller.sections.messages.last?.id {
                                controller.loadMore()
                            }
                        }
                    }
                    if controller.isLoadingMore {
                        HStack { Spacer(); ProgressView(); Spacer() }
                    }
                }
            }

            emptyState
        }
        .listStyle(.plain)
        .background(TojTheme.canvas)
        .accessibilityIdentifier("search-results")
    }

    @ViewBuilder
    private func coverageBanner(_ message: String) -> some View {
        // Partial coverage has to be visible, or a user concludes a message does not exist when it
        // simply has not been downloaded yet.
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle")
                .foregroundStyle(TojTheme.secondaryText)
            Text(message)
                .font(.caption)
                .foregroundStyle(TojTheme.secondaryText)
        }
        .padding(.vertical, 6)
        .listRowBackground(TojTheme.canvas)
        .accessibilityIdentifier("search-coverage-banner")
    }

    @ViewBuilder
    private var emptyState: some View {
        switch controller.phase {
        case .searching where controller.sections.isEmpty:
            HStack { Spacer(); ProgressView(); Spacer() }
                .listRowBackground(TojTheme.canvas)
                .accessibilityIdentifier("search-loading")
        case .degraded:
            // An unavailable index is a different answer from "no matches", and saying so stops the
            // user retyping a query that was never going to work.
            emptyMessage(
                title: String(localized: "Search is unavailable"),
                detail: String(localized: "Chats and people still work. The message index is rebuilding."),
                identifier: "search-degraded"
            )
        case .empty:
            emptyMessage(
                title: String(localized: "No results"),
                detail: String(localized: "Try another name, filter, or message."),
                identifier: "search-empty"
            )
        case .idle, .results, .searching:
            EmptyView()
        }
    }

    private func emptyMessage(title: String, detail: String, identifier: String) -> some View {
        VStack(spacing: 6) {
            Text(title).font(TojTheme.heading(.headline))
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(TojTheme.secondaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .listRowBackground(TojTheme.canvas)
        .accessibilityIdentifier(identifier)
    }
}

/// One message hit: who, where, when, and the matched text with its matches marked.
struct MessageSearchRow: View {
    let hit: MessageSearchHit
    let text: String
    let highlights: [Range<String.Index>]

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            TojIconTile(systemImage: icon, tint: TojTheme.secondaryText)
            VStack(alignment: .leading, spacing: 3) {
                Text(snippet)
                    .font(.subheadline)
                    .lineLimit(2)
                Text(hit.dialogTitle)
                    .font(.caption2)
                    .foregroundStyle(TojTheme.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    private var icon: String {
        switch hit.kind {
        case "photo": "photo"
        case "video": "video"
        case "voice": "waveform"
        case "file": "doc"
        default: hit.hasMedia ? "paperclip" : "text.bubble"
        }
    }

    /// The original text with matches marked in the accent, built as an `AttributedString` so the
    /// letters themselves are never altered — only their styling.
    private var snippet: AttributedString {
        var attributed = AttributedString(text)
        for range in highlights {
            guard let lower = AttributedString.Index(range.lowerBound, within: attributed),
                  let upper = AttributedString.Index(range.upperBound, within: attributed)
            else { continue }
            attributed[lower..<upper].foregroundColor = TojTheme.accent
            attributed[lower..<upper].font = .subheadline.weight(.semibold)
        }
        return attributed
    }
}
