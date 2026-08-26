import SwiftUI

struct TojPeerProfileView: View {
    @Bindable var model: CloudAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var notificationsEnabled = true
    @State private var showingClearMedia = false
    @State private var showingBlockConfirmation = false
    @State private var showingReport = false

    let dialogId: String
    let onCall: () -> Void
    /// Opens find-in-conversation. Supplied by the conversation, which owns that state.
    var onSearch: () -> Void = {}

    private var title: String { model.dialogTitle(dialogId) }
    private var dialog: CloudAppModel.Dialog? { model.dialogs.first(where: { $0.id == dialogId }) }
    private var canReportAccount: Bool { model.canShowAccountReport(dialogId: dialogId) }

    private var birthdayText: LocalizedStringKey? {
        guard let value = dialog?.peerBirthday else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = .current
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: value) else { return LocalizedStringKey(value) }
        return LocalizedStringKey(date.formatted(date: .long, time: .omitted))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    VStack(spacing: 10) {
                        CloudProfileAvatar(
                            model: model,
                            title: title,
                            media: dialog?.photo,
                            size: 82,
                            colorIndex: dialog?.profileColorIndex
                        )
                        Text(title)
                            .font(TojTheme.heading(.title, weight: .bold))
                        Text(model.typingSummary(dialogId: dialogId)
                             ?? model.directPresenceSubtitle(dialogId: dialogId))
                            .font(.subheadline)
                            .foregroundStyle(
                                model.typingSummary(dialogId: dialogId) != nil
                                    ? TojTheme.gold : TojTheme.secondaryText
                            )
                        if let bio = dialog?.peerBio, !bio.isEmpty {
                            Text(bio)
                                .font(.subheadline)
                                .foregroundStyle(TojTheme.secondaryText)
                                .multilineTextAlignment(.center)
                        }
                        Label(
                            CloudChatPrivacyPresentation.title,
                            systemImage: CloudChatPrivacyPresentation.systemImage
                        )
                            .font(.caption)
                            .foregroundStyle(TojTheme.secondaryText)
                            .accessibilityLabel(CloudChatPrivacyPresentation.accessibilityLabel)
                    }
                    .padding(.top, 12)

                    HStack(spacing: 12) {
                        profileAction("Audio", icon: "phone.fill") { onCall() }
                            .disabled(!model.capabilities.contains(.calls))
                            .opacity(model.capabilities.contains(.calls) ? 1 : 0.42)
                        profileAction("Video", icon: "video.slash.fill") {}
                            .disabled(true)
                            .opacity(0.42)
                        profileAction("Search", icon: "magnifyingglass") {
                            // The presenting conversation waits for the sheet's onDismiss before
                            // publishing the find bar, so it cannot be hidden by the transition.
                            onSearch()
                        }
                    }

                    profileSection("Privacy") {
                        if let birthdayText {
                            profileRow("Birthday", detail: birthdayText, icon: "birthday.cake.fill")
                        }
                        profileRow(
                            "Message privacy",
                            detail: LocalizedStringKey(CloudChatPrivacyPresentation.detail),
                            icon: CloudChatPrivacyPresentation.systemImage
                        )
                        Text(CloudChatPrivacyPresentation.disclosure)
                            .font(.footnote)
                            .foregroundStyle(TojTheme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 15)
                            .padding(.vertical, 12)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(CloudChatPrivacyPresentation.accessibilityLabel)

                    profileSection("Conversation") {
                        Toggle(isOn: $notificationsEnabled) {
                            Label("Notifications", systemImage: notificationsEnabled ? "bell.fill" : "bell.slash.fill")
                        }
                        .tint(TojTheme.secure)
                        .padding(.horizontal, 15)
                        .frame(minHeight: 54)

                        Divider().overlay(TojTheme.hairline).padding(.leading, 58)

                        Button(role: .destructive) {
                            showingClearMedia = true
                        } label: {
                            HStack(spacing: 12) {
                                TojIconTile(systemImage: "trash.fill", tint: TojTheme.danger)
                                Text(model.clearingMediaCache ? "Clearing downloaded media…" : "Clear downloaded media")
                                    .font(.subheadline.weight(.medium))
                                Spacer()
                            }
                            .foregroundStyle(TojTheme.danger)
                            .padding(.horizontal, 15)
                            .frame(minHeight: 56)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.tojPressable(scale: 0.985))
                        .disabled(model.clearingMediaCache)

                        Divider().overlay(TojTheme.hairline).padding(.leading, 58)

                        Button(role: .destructive) { showingBlockConfirmation = true } label: {
                            Label(
                                canReportAccount
                                    ? String(localized: "Block or report")
                                    : String(localized: "Block"),
                                systemImage: "hand.raised.fill"
                            )
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .frame(minHeight: 54)
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 15)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 28)
            }
            .background(TojTheme.canvas)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog(
                "Clear this chat’s downloaded media?",
                isPresented: $showingClearMedia,
                titleVisibility: .visible
            ) {
                Button("Clear downloaded media", role: .destructive) {
                    Task { await model.clearMediaCache(dialogId: dialogId) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Messages stay in the chat. Cloud media downloads again when you open it.")
            }
            .confirmationDialog(
                canReportAccount
                    ? String(localized: "Block or report this contact?")
                    : String(localized: "Block this contact?"),
                isPresented: $showingBlockConfirmation,
                titleVisibility: .visible
            ) {
                Button("Block", role: .destructive) {
                    Task {
                        if await model.blockPeer(dialogId: dialogId) { dismiss() }
                    }
                }
                if canReportAccount {
                    Button("Report", role: .destructive) { showingReport = true }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Blocking prevents new messages and voice calls in both directions.")
            }
            .sheet(isPresented: $showingReport) {
                AbuseReportSheet(
                    subjectKind: .account,
                    submit: { reason, details, clientReportId in
                        await model.submitAccountReport(
                            dialogId: dialogId,
                            reason: reason,
                            details: details,
                            clientReportId: clientReportId
                        )
                    },
                    blockAccount: {
                        await model.blockPeer(dialogId: dialogId)
                    }
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
        }
    }

    private func profileAction(_ title: LocalizedStringKey, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .tojGlass(in: Circle(), interactive: true)
                Text(title).font(.caption.weight(.medium))
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.tojPressable)
        .foregroundStyle(TojTheme.text)
    }

    private func profileSection<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        TojSectionCard(title) { content() }
    }

    private func profileRow(_ title: LocalizedStringKey, detail: LocalizedStringKey, icon: String, iconTint: Color? = nil, detailColor: Color = TojTheme.secondaryText) -> some View {
        HStack(spacing: 12) {
            TojIconTile(systemImage: icon, tint: iconTint)
            Text(title)
            Spacer()
            Text(detail).font(.caption).foregroundStyle(detailColor)
            Image(systemName: "chevron.right").font(.caption2.bold()).foregroundStyle(TojTheme.secondaryText)
        }
        .font(.subheadline.weight(.medium))
        .padding(.horizontal, 15)
        .frame(minHeight: 56)
        .overlay(alignment: .bottom) { Rectangle().fill(TojTheme.hairline).frame(height: 0.5).padding(.leading, 57) }
    }
}

struct TojDemoCallView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CallViewState.Phase = .ringing
    @State private var isMuted = false
    @State private var isCameraEnabled = true
    @State private var isSpeakerEnabled = false

    let peerName: String
    var colorIndex: Int? = nil

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: 0x111318), TojTheme.canvas], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.down")
                        .frame(width: 46, height: 46)
                }
                .buttonStyle(.glass)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .accessibilityLabel("Minimize call")

                Spacer()

                ZStack {
                    if !reduceMotion, (phase == .ringing || phase == .connecting) {
                        Circle()
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                            .frame(width: 154, height: 154)
                            .scaleEffect(1.15)
                    }
                    TojAvatar(title: peerName, size: 122, colorIndex: colorIndex)
                }

                Text(peerName)
                    .font(TojTheme.heading(.title, weight: .bold))
                    .padding(.top, 22)
                Text(phaseTitle)
                    .font(.subheadline)
                    .foregroundStyle(TojTheme.secondaryText)
                    .padding(.top, 7)

                Spacer()

                HStack(spacing: 18) {
                    callControl(icon: isMuted ? "mic.slash.fill" : "mic.fill", title: "Mute", selected: isMuted) { isMuted.toggle() }
                    callControl(icon: isCameraEnabled ? "video.fill" : "video.slash.fill", title: "Camera", selected: !isCameraEnabled) { isCameraEnabled.toggle() }
                    callControl(icon: "speaker.wave.2.fill", title: "Speaker", selected: isSpeakerEnabled) { isSpeakerEnabled.toggle() }
                }

                Button {
                    phase = .ended
                    TojFeedback.sent()
                    Task {
                        try? await Task.sleep(for: .milliseconds(350))
                        dismiss()
                    }
                } label: {
                    Image(systemName: "phone.down.fill")
                        .font(.system(size: 22, weight: .bold))
                        .frame(width: 68, height: 68)
                        .background(TojTheme.danger, in: Circle())
                }
                .buttonStyle(.tojPressable)
                .padding(.top, 34)
                .padding(.bottom, 46)
                .accessibilityLabel("End call")
            }
        }
        .task {
            try? await Task.sleep(for: .milliseconds(800))
            phase = .connecting
            try? await Task.sleep(for: .milliseconds(700))
            phase = .active
        }
    }

    private var phaseTitle: String {
        switch phase {
        case .ringing: String(localized: "Ringing…")
        case .connecting: String(localized: "Connecting securely…")
        case .active: String(localized: "00:01")
        case .reconnecting: String(localized: "Reconnecting…")
        case .declined: String(localized: "Declined")
        case .ended: String(localized: "Call ended")
        }
    }

    private func callControl(icon: String, title: LocalizedStringKey, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 19, weight: .semibold))
                    .frame(width: 54, height: 54)
                    .background(selected ? TojTheme.text : TojTheme.strong, in: Circle())
                    .foregroundStyle(selected ? TojTheme.canvas : TojTheme.text)
                Text(title).font(.caption)
            }
        }
        .buttonStyle(.tojPressable)
        .foregroundStyle(TojTheme.text)
    }
}

struct DemoGroupCreationView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String> = []
    @State private var groupName = ""
    @State private var step = 0

    let dialogs: [CloudAppModel.Dialog]

    var body: some View {
        NavigationStack {
            Group {
                if step == 0 { memberSelection } else { groupDetails }
            }
            .background(TojTheme.canvas)
            .navigationTitle(step == 0 ? "New group" : "Group details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(step == 0 ? "Next" : "Create") {
                        if step == 0 { step = 1 } else { TojFeedback.sent(); dismiss() }
                    }
                    .disabled(step == 0 ? selected.isEmpty : groupName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private var memberSelection: some View {
        List(dialogs.filter { !$0.isArchived }) { dialog in
            Button {
                if selected.contains(dialog.id) { selected.remove(dialog.id) } else { selected.insert(dialog.id) }
            } label: {
                HStack(spacing: 12) {
                    TojAvatar(title: dialog.title, size: 44)
                    Text(dialog.title).foregroundStyle(TojTheme.text)
                    Spacer()
                    Image(systemName: selected.contains(dialog.id) ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected.contains(dialog.id) ? TojTheme.secure : TojTheme.secondaryText)
                }
            }
            .listRowBackground(TojTheme.raised)
        }
        .scrollContentBackground(.hidden)
    }

    private var groupDetails: some View {
        VStack(spacing: 22) {
            TojAvatar(title: groupName.isEmpty ? "Group" : groupName, size: 88)
            TextField("Group name", text: $groupName)
                .padding(.horizontal, 16)
                .frame(height: 54)
                .background(TojTheme.raised, in: Capsule())
            Text("\(selected.count) members selected")
                .font(.subheadline)
                .foregroundStyle(TojTheme.secondaryText)
            Spacer()
        }
        .padding(22)
    }
}

/// Demo twin of the production media viewer — same Telegram-style chrome grammar (uniform 46 pt
/// glass circles, tappable title capsule, fading chrome) over placeholder content.
struct DemoMediaViewer: View {
    @Environment(\.dismiss) private var dismiss
    let attachment: DemoAttachment
    var title = ""
    var subtitle = ""
    var onDelete: (() -> Void)? = nil
    @State private var chromeVisible = true
    @State private var confirmingDelete = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            LinearGradient(
                colors: [Color(hex: 0x27333A), Color(hex: 0x101C22)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            .overlay {
                VStack(spacing: 18) {
                    Image(systemName: mediaIcon)
                        .font(.system(size: 84, weight: .ultraLight))
                        .foregroundStyle(.white.opacity(0.85))
                    Text(attachment.title)
                        .font(TojTheme.heading(.title3))
                        .foregroundStyle(.white)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { chromeVisible.toggle() }

            chrome
                .opacity(chromeVisible ? 1 : 0)
                .allowsHitTesting(chromeVisible)
                .animation(.easeInOut(duration: 0.22), value: chromeVisible)
        }
        .preferredColorScheme(.dark)
        .confirmationDialog(
            "Delete this message?", isPresented: $confirmingDelete, titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                onDelete?()
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var chrome: some View {
        VStack {
            HStack(spacing: 8) {
                Button { dismiss() } label: { TojGlassIconLabel(systemImage: "chevron.left") }
                    .buttonStyle(.tojPressable)
                    .accessibilityLabel("Back")
                Spacer(minLength: 8)
                Menu {
                    Button { dismiss() } label: {
                        Label("Show in Chat", systemImage: "bubble.left.and.text.bubble.right")
                    }
                    if onDelete != nil {
                        Button(role: .destructive) { confirmingDelete = true } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                } label: {
                    TojGlassIconLabel(systemImage: "ellipsis")
                }
                .buttonStyle(.tojPressable)
                .accessibilityLabel("More")
            }
            .overlay {
                Button { dismiss() } label: {
                    VStack(spacing: 1) {
                        Text(title.isEmpty ? attachment.title : title)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(TojTheme.text)
                            .lineLimit(1)
                        if !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.system(size: 12))
                                .foregroundStyle(TojTheme.secondaryText)
                                .lineLimit(1)
                        }
                    }
                    .padding(.horizontal, 18)
                    .frame(height: 46)
                    .frame(maxWidth: 240)
                    .contentShape(Capsule())
                }
                .buttonStyle(.tojPressable)
                .tojGlass(in: Capsule(), interactive: true)
                .accessibilityLabel("Back to chat")
            }

            Spacer()

            HStack {
                TojGlassIconLabel(systemImage: "arrowshape.turn.up.right")
                    .opacity(0.45)
                    .accessibilityHidden(true)
                Spacer()
                if onDelete != nil {
                    Button { confirmingDelete = true } label: { TojGlassIconLabel(systemImage: "trash") }
                        .buttonStyle(.tojPressable)
                        .accessibilityLabel("Delete")
                } else {
                    Color.clear.frame(width: 46, height: 46)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 14)
    }

    private var mediaIcon: String {
        switch attachment {
        case .photo: "photo"
        case .video: "play.rectangle"
        case .file: "doc"
        case .voice: "waveform"
        case .link: "link"
        }
    }
}

struct PresentationStateGallery: View {
    private let callStates: [(String, String)] = [
        (String(localized: "Ringing"), "phone.arrow.up.right.fill"),
        (String(localized: "Connecting"), "arrow.triangle.2.circlepath"),
        (String(localized: "Active"), "phone.fill"),
        (String(localized: "Reconnecting"), "wifi.exclamationmark"),
        (String(localized: "Declined"), "phone.down.fill"),
        (String(localized: "Ended"), "checkmark.circle.fill"),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                gallerySection("Connection") {
                    stateRow("Connected", detail: "Live sync", icon: "network", color: TojTheme.secure)
                    stateRow("Connecting…", detail: "Syncing", icon: "arrow.triangle.2.circlepath", color: TojTheme.secondaryText)
                    stateRow("Waiting for network", detail: "Messages are queued", icon: "wifi.slash", color: .orange)
                }

                gallerySection("Message delivery") {
                    stateRow("Queued", detail: "Clock", icon: "clock", color: TojTheme.secondaryText)
                    stateRow("Sent", detail: "Single check", icon: "checkmark", color: TojTheme.secondaryText)
                    stateRow("Seen", detail: "Confirmed", icon: "checkmark.circle.fill", color: TojTheme.secure)
                    stateRow("Failed", detail: "Tap for retry", icon: "exclamationmark.circle.fill", color: .red)
                }

                gallerySection("Rich content") {
                    DemoGalleryAttachment(attachment: .photo(name: "Photo preview"))
                    DemoGalleryAttachment(attachment: .file(name: "Document.pdf", size: "1.8 MB"))
                    DemoGalleryAttachment(attachment: .voice(duration: "0:08"))
                }

                gallerySection("Call lifecycle") {
                    ForEach(callStates, id: \.0) { state in
                        stateRow(state.0, detail: "Demo fixture", icon: state.1, color: TojTheme.text)
                    }
                }

                Label("These deterministic fixtures never call the production transport.", systemImage: "hammer.fill")
                    .font(.caption)
                    .foregroundStyle(TojTheme.secondaryText)
                    .padding(.horizontal, 5)
            }
            .padding(16)
            .padding(.bottom, 24)
        }
        .background(TojTheme.canvas)
        .navigationTitle("Interface states")
    }

    private func gallerySection<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        TojSectionCard(title) { content() }
    }

    private func stateRow(_ title: String, detail: String, icon: String, color: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 28)
            Text(title).font(.subheadline.weight(.medium))
            Spacer()
            Text(detail).font(.caption).foregroundStyle(TojTheme.secondaryText)
        }
        .padding(.horizontal, 15)
        .frame(minHeight: 52)
        .overlay(alignment: .bottom) { Rectangle().fill(TojTheme.hairline).frame(height: 0.5).padding(.leading, 55) }
        .accessibilityElement(children: .combine)
    }
}

private struct DemoGalleryAttachment: View {
    let attachment: DemoAttachment

    var body: some View {
        HStack(spacing: 12) {
            TojIconTile(systemImage: icon)
            Text(attachment.title).font(.subheadline.weight(.medium))
            Spacer()
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(TojTheme.secondaryText)
        }
        .padding(.horizontal, 13)
        .frame(minHeight: 58)
    }

    private var icon: String {
        switch attachment {
        case .photo: "photo.fill"
        case .video: "video.fill"
        case .file: "doc.fill"
        case .voice: "waveform"
        case .link: "link"
        }
    }
}
