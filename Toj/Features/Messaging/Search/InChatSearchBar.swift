import SwiftUI

/// Find-in-conversation, rendered as a top overlay.
///
/// An overlay rather than a toolbar item because `ConversationExperience` hides the navigation bar
/// outright — there is nowhere to put a toolbar. The visual language follows the composer, which is
/// the other floating bar in this screen.
struct InChatSearchBar: View {
    @Bindable var model: CloudAppModel
    @FocusState private var focused: Bool

    var body: some View {
        if let state = model.inChatSearch {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(TojTheme.secondaryText)

                TextField("Search in chat", text: queryBinding)
                    .textFieldStyle(.plain)
                    .submitLabel(.search)
                    .focused($focused)
                    .accessibilityIdentifier("in-chat-search-field")

                if let label = state.positionLabel {
                    Text(label)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(TojTheme.secondaryText)
                        .accessibilityIdentifier("in-chat-search-position")
                } else if !state.query.isEmpty {
                    Text("No matches")
                        .font(.caption)
                        .foregroundStyle(TojTheme.secondaryText)
                        .accessibilityIdentifier("in-chat-search-empty")
                }

                // Up walks toward newer messages, down toward older, matching the direction the
                // list scrolls rather than the order of the underlying array.
                stepButton(systemImage: "chevron.up", forward: false, identifier: "in-chat-search-previous")
                stepButton(systemImage: "chevron.down", forward: true, identifier: "in-chat-search-next")

                Button {
                    model.closeInChatSearch()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(TojTheme.secondaryText)
                }
                .accessibilityLabel("Close search")
                .accessibilityIdentifier("in-chat-search-close")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .padding(.horizontal, 12)
            .accessibilityIdentifier("in-chat-search-bar")
            .onAppear { focused = true }
        }
    }

    private var queryBinding: Binding<String> {
        Binding(
            get: { model.inChatSearch?.query ?? "" },
            set: { newValue in
                Task { await model.updateInChatSearch(query: newValue) }
            }
        )
    }

    private func stepButton(systemImage: String, forward: Bool, identifier: String) -> some View {
        Button {
            Task { await model.stepInChatSearch(forward: forward) }
        } label: {
            Image(systemName: systemImage)
        }
        .disabled(model.inChatSearch?.isEmpty ?? true)
        .accessibilityIdentifier(identifier)
    }
}

/// Brief highlight on the message a search landed on.
///
/// The flash is what connects "I tapped a result" to "this is the message". Without it the
/// conversation simply appears at an arbitrary scroll position and the user has to re-find their
/// own result.
struct SearchMatchFlash: ViewModifier {
    let isActive: Bool
    let onFinished: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var opacity: Double = 0

    /// Long enough to notice while glancing, short enough not to linger over the text.
    private static let duration: Duration = .milliseconds(2_800)

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(TojTheme.accent.opacity(0.22 * opacity))
                    .padding(-6)
            )
            .accessibilityAddTraits(isActive ? .isSelected : [])
            .accessibilityValue(isActive ? String(localized: "Search match highlighted") : "")
            .task(id: isActive) {
                guard isActive else { return }
                // Reduce Motion gets the same information without the pulse.
                withAnimation(reduceMotion ? .none : .easeOut(duration: 0.2)) { opacity = 1 }
                try? await Task.sleep(for: Self.duration)
                withAnimation(reduceMotion ? .none : .easeIn(duration: 0.4)) { opacity = 0 }
                onFinished()
            }
    }
}

extension View {
    /// Flashes this row when it is the message a search result opened.
    func searchMatchFlash(isActive: Bool, onFinished: @escaping () -> Void) -> some View {
        modifier(SearchMatchFlash(isActive: isActive, onFinished: onFinished))
    }
}
