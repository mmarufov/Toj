import SwiftUI

struct DataStorageSettingsView: View {
    @Bindable var model: CloudAppModel

    @State private var selectedSize: MediaCacheSizeLimit = .gigabytes2
    @State private var selectedRetention: MediaCacheRetention = .oneMonth
    @State private var selectedChat: MediaChatClass = .privateChat
    @State private var treatsCellularAsRoaming = false
    @State private var clearSelection: MediaClearSelection?
    @State private var policyEditorSelection: MediaPolicyEditorSelection?
    @State private var hasLoaded = false

    private let sizeOptions: [MediaCacheSizeLimit] = [
        .megabytes500, .gigabytes2, .gigabytes5, .gigabytes10, .unlimited,
    ]

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 20) {
                header
                storageUsage
                automaticDownloads
                mobileNetwork
                networkGuidance
            }
            .padding(16)
            .padding(.bottom, 28)
        }
        .background(TojTheme.canvas)
        .navigationTitle("Data and Storage")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await load()
        }
        .task {
            guard !hasLoaded else { return }
            await load()
            hasLoaded = true
        }
        .sheet(item: $policyEditorSelection) { selection in
            MediaAutoDownloadNetworkEditor(
                chat: selection.chat,
                network: selection.network,
                initialLimits: limits(for: selection)
            ) { limits in
                updateAutoDownloadLimits(limits, for: selection)
            }
            .presentationDetents([.medium, .large])
        }
        .confirmationDialog(
            clearSelection?.confirmationTitle ?? "Clear downloaded media?",
            isPresented: Binding(
                get: { clearSelection != nil },
                set: { if !$0 { clearSelection = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(clearSelection?.buttonTitle ?? "Clear downloaded media", role: .destructive) {
                let selection = clearSelection
                clearSelection = nil
                Task {
                    if let kind = selection?.kind {
                        await model.clearMediaCache(kind: kind)
                    } else {
                        await model.clearMediaCache()
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(clearSelection?.message ?? "Pending uploads stay protected. Cloud media downloads again when you open it.")
        }
    }

    private var header: some View {
        VStack(spacing: 11) {
            Image(systemName: "externaldrive.fill.badge.checkmark")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(TojTheme.secure)
                .frame(width: 72, height: 72)
                .background(TojTheme.secure.opacity(0.16), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(TojTheme.secure.opacity(0.2), lineWidth: 0.5)
                )
            Text("Fast, private local media")
                .font(TojTheme.heading(.title2, weight: .bold))
                .foregroundStyle(TojTheme.text)
            Text("Messages render from this device first. Downloaded media stays encrypted and can be cleared without deleting its cloud copy.")
                .font(.subheadline)
                .foregroundStyle(TojTheme.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 350)
        }
        .padding(.vertical, 12)
    }

    private var storageUsage: some View {
        TojSectionCard("Storage usage") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(ByteCountFormatter.string(
                            fromByteCount: model.mediaCacheBytes,
                            countStyle: .file
                        ))
                            .font(TojTheme.heading(.title2, weight: .bold))
                            .foregroundStyle(TojTheme.text)
                        Text("Downloaded photos, videos, files and voice messages")
                            .font(.caption)
                            .foregroundStyle(TojTheme.secondaryText)
                    }
                    Spacer()
                    if model.clearingMediaCache {
                        ProgressView()
                            .tint(TojTheme.gold)
                    }
                }

                if let limit = selectedSize.bytes, limit > 0 {
                    ProgressView(
                        value: min(Double(model.mediaCacheBytes), Double(limit)),
                        total: Double(limit)
                    )
                    .tint(TojTheme.gold)
                }
            }
            .padding(16)

            Divider().overlay(TojTheme.hairline).padding(.leading, 16)

            policyMenuRow(
                title: "Maximum cache size",
                systemImage: "internaldrive.fill",
                value: selectedSize.title
            ) {
                ForEach(sizeOptions, id: \.self) { option in
                    Button {
                        selectedSize = option
                        updateCachePolicy()
                    } label: {
                        if selectedSize == option {
                            Label(option.title, systemImage: "checkmark")
                        } else {
                            Text(option.title)
                        }
                    }
                }
            }

            Divider().overlay(TojTheme.hairline).padding(.leading, 62)

            policyMenuRow(
                title: "Keep unused media",
                systemImage: "clock.arrow.circlepath",
                value: selectedRetention.title
            ) {
                ForEach(MediaCacheRetention.allCases, id: \.self) { option in
                    Button {
                        selectedRetention = option
                        updateCachePolicy()
                    } label: {
                        if selectedRetention == option {
                            Label(option.title, systemImage: "checkmark")
                        } else {
                            Text(option.title)
                        }
                    }
                }
            }

            Divider().overlay(TojTheme.hairline).padding(.leading, 62)

            Button(role: .destructive) {
                clearSelection = .all
            } label: {
                HStack(spacing: 13) {
                    TojIconTile(systemImage: "trash.fill", tint: TojTheme.danger)
                    Text(model.clearingMediaCache ? "Clearing…" : "Clear downloaded media")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                }
                .foregroundStyle(TojTheme.danger)
                .padding(.horizontal, 16)
                .frame(minHeight: 56)
            }
            .buttonStyle(.tojPressable(scale: 0.985))
            .disabled(model.clearingMediaCache || model.mediaCacheBytes == 0)

            Divider().overlay(TojTheme.hairline).padding(.leading, 62)

            Menu {
                ForEach(MediaClearSelection.mediaTypes) { selection in
                    Button(selection.menuTitle, role: .destructive) {
                        clearSelection = selection
                    }
                }
            } label: {
                HStack(spacing: 13) {
                    TojIconTile(systemImage: "line.3.horizontal.decrease.circle.fill", tint: TojTheme.danger)
                    Text("Clear by media type")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2.weight(.bold))
                }
                .foregroundStyle(TojTheme.danger)
                .padding(.horizontal, 16)
                .frame(minHeight: 56)
                .contentShape(Rectangle())
            }
            .buttonStyle(.tojPressable(scale: 0.985))
            .disabled(model.clearingMediaCache || model.mediaCacheBytes == 0)
        }
    }

    private var automaticDownloads: some View {
        TojSectionCard("Automatic downloads") {
            VStack(alignment: .leading, spacing: 14) {
                Picker("Chat type", selection: $selectedChat) {
                    Text("Private chats").tag(MediaChatClass.privateChat)
                    Text("Groups").tag(MediaChatClass.group)
                }
                .pickerStyle(.segmented)

                ForEach(networkRows) { row in
                    networkRow(row, showsDivider: row.id != networkRows.last?.id)
                }

                if model.mediaAutoDownloadPolicy != .default {
                    Button("Restore recommended defaults") {
                        Task { await model.updateMediaAutoDownloadPolicy(.default) }
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(TojTheme.gold)
                    .buttonStyle(.tojPressable)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 2)
                }
            }
            .padding(14)
        }
    }

    private var networkGuidance: some View {
        TojSectionCard("How it works") {
            VStack(alignment: .leading, spacing: 12) {
                guidanceRow(
                    icon: "photo.on.rectangle.angled",
                    title: "Previews arrive first",
                    detail: "Small encrypted thumbnails are cached before full photos and videos."
                )
                guidanceRow(
                    icon: "hand.tap.fill",
                    title: "Your tap always wins",
                    detail: "Opening media starts or resumes it immediately, even when automatic download is limited."
                )
                guidanceRow(
                    icon: "antenna.radiowaves.left.and.right",
                    title: "Respect constrained networks",
                    detail: "Low Data Mode and roaming keep previews and voice available without silently pulling large files."
                )
            }
            .padding(15)
        }
    }

    private var mobileNetwork: some View {
        TojSectionCard("Mobile network") {
            Toggle(isOn: Binding(
                get: { treatsCellularAsRoaming },
                set: { isRoaming in
                    treatsCellularAsRoaming = isRoaming
                    ReplicaNetworkMonitor.shared.setCellularRoaming(isRoaming)
                }
            )) {
                HStack(spacing: 13) {
                    TojIconTile(systemImage: "globe.europe.africa.fill", tint: TojTheme.gold)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("I’m using mobile data while roaming")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(TojTheme.text)
                        Text("Uses your roaming limits for automatic downloads and history backfill.")
                            .font(.caption)
                            .foregroundStyle(TojTheme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .tint(TojTheme.gold)
            .padding(.horizontal, 16)
            .frame(minHeight: 68)

            Divider().overlay(TojTheme.hairline).padding(.leading, 62)

            Text("iPhone does not expose roaming status to apps, so turn this on whenever your carrier is charging roaming data. Toj stores only this choice on your device.")
                .font(.footnote)
                .foregroundStyle(TojTheme.secondaryText)
                .padding(16)
        }
    }

    private var selectedNetworkPolicy: MediaAutoDownloadNetworkPolicy {
        selectedChat == .privateChat
            ? model.mediaAutoDownloadPolicy.privateChats
            : model.mediaAutoDownloadPolicy.groupChats
    }

    private var networkRows: [NetworkPolicyRow] {
        [
            NetworkPolicyRow(
                id: "wifi", network: .wifi, title: "Wi‑Fi", systemImage: "wifi",
                detail: Self.summary(selectedNetworkPolicy.wifi)
            ),
            NetworkPolicyRow(
                id: "cellular", network: .cellular, title: "Mobile data", systemImage: "antenna.radiowaves.left.and.right",
                detail: Self.summary(selectedNetworkPolicy.cellular)
            ),
            NetworkPolicyRow(
                id: "low-data", network: .constrained, title: "Low Data Mode", systemImage: "leaf.fill",
                detail: Self.summary(selectedNetworkPolicy.constrained)
            ),
            NetworkPolicyRow(
                id: "roaming", network: .roaming, title: "Roaming", systemImage: "globe.europe.africa.fill",
                detail: Self.summary(selectedNetworkPolicy.roaming)
            ),
        ]
    }

    private func networkRow(_ row: NetworkPolicyRow, showsDivider: Bool) -> some View {
        Button {
            policyEditorSelection = MediaPolicyEditorSelection(
                chat: selectedChat,
                network: row.network
            )
        } label: {
            HStack(spacing: 12) {
                TojIconTile(systemImage: row.systemImage, tint: TojTheme.gold)
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(TojTheme.text)
                    Text(row.detail)
                        .font(.caption)
                        .foregroundStyle(TojTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.caption.bold())
                    .foregroundStyle(TojTheme.tertiaryText)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.tojPressable(scale: 0.985))
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) {
            if showsDivider {
                Divider().overlay(TojTheme.hairline).padding(.leading, 42)
            }
        }
    }

    private func guidanceRow(icon: String, title: LocalizedStringKey, detail: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(TojTheme.secure)
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(TojTheme.text)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(TojTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func policyMenuRow<MenuContent: View>(
        title: LocalizedStringKey,
        systemImage: String,
        value: String,
        @ViewBuilder content: () -> MenuContent
    ) -> some View {
        Menu(content: content) {
            HStack(spacing: 13) {
                TojIconTile(systemImage: systemImage)
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(TojTheme.text)
                Spacer()
                Text(value)
                    .font(.subheadline)
                    .foregroundStyle(TojTheme.secondaryText)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(TojTheme.secondaryText)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.tojPressable(scale: 0.985))
    }

    private func load() async {
        treatsCellularAsRoaming = ReplicaNetworkMonitor.shared.cellularRoamingSetting()
        async let policies: Void = model.loadMediaPolicies()
        async let usage: Void = model.refreshMediaCacheUsage()
        _ = await (policies, usage)
        selectedSize = model.mediaCachePolicy.sizeLimit
        selectedRetention = model.mediaCachePolicy.retention
    }

    private func updateCachePolicy() {
        let policy = MediaCachePolicy(sizeLimit: selectedSize, retention: selectedRetention)
        Task { await model.updateMediaCachePolicy(policy) }
    }

    private func limits(for selection: MediaPolicyEditorSelection) -> MediaAutoDownloadLimits {
        let policy = selection.chat == .privateChat
            ? model.mediaAutoDownloadPolicy.privateChats
            : model.mediaAutoDownloadPolicy.groupChats
        return policy.limits(for: selection.network)
    }

    private func updateAutoDownloadLimits(
        _ limits: MediaAutoDownloadLimits,
        for selection: MediaPolicyEditorSelection
    ) {
        var policy = model.mediaAutoDownloadPolicy
        var chatPolicy = selection.chat == .privateChat ? policy.privateChats : policy.groupChats
        switch selection.network {
        case .wifi: chatPolicy.wifi = limits
        case .cellular: chatPolicy.cellular = limits
        case .constrained: chatPolicy.constrained = limits
        case .roaming: chatPolicy.roaming = limits
        }
        if selection.chat == .privateChat {
            policy.privateChats = chatPolicy
        } else {
            policy.groupChats = chatPolicy
        }
        Task { await model.updateMediaAutoDownloadPolicy(policy) }
    }

    private static func summary(_ limits: MediaAutoDownloadLimits) -> String {
        let values: [(String, Int64)] = [
            (String(localized: "Photos"), limits.photoBytes),
            (String(localized: "Voice"), limits.voiceBytes),
            (String(localized: "Videos"), limits.videoBytes),
            (String(localized: "Files"), limits.fileBytes),
        ]
        let enabled = values.compactMap { title, bytes -> String? in
            guard bytes > 0 else { return nil }
            return "\(title) \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))"
        }
        return enabled.isEmpty ? String(localized: "Previews only") : enabled.joined(separator: " · ")
    }
}

private struct NetworkPolicyRow: Identifiable {
    let id: String
    let network: MediaNetworkClass
    let title: LocalizedStringKey
    let systemImage: String
    let detail: String
}

private struct MediaPolicyEditorSelection: Identifiable {
    let chat: MediaChatClass
    let network: MediaNetworkClass

    var id: String { "\(chat.rawValue)|\(network.rawValue)" }
}

private struct MediaAutoDownloadNetworkEditor: View {
    @Environment(\.dismiss) private var dismiss

    let chat: MediaChatClass
    let network: MediaNetworkClass
    let onSave: (MediaAutoDownloadLimits) -> Void

    @State private var photoBytes: Int64
    @State private var voiceBytes: Int64
    @State private var videoBytes: Int64
    @State private var fileBytes: Int64

    private let limitOptions: [Int64] = [
        0,
        1 * 1024 * 1024,
        3 * 1024 * 1024,
        5 * 1024 * 1024,
        10 * 1024 * 1024,
        MediaAutoDownloadPolicy.maximumSupportedMediaBytes,
    ]

    init(
        chat: MediaChatClass,
        network: MediaNetworkClass,
        initialLimits: MediaAutoDownloadLimits,
        onSave: @escaping (MediaAutoDownloadLimits) -> Void
    ) {
        self.chat = chat
        self.network = network
        self.onSave = onSave
        _photoBytes = State(initialValue: initialLimits.photoBytes)
        _voiceBytes = State(initialValue: initialLimits.voiceBytes)
        _videoBytes = State(initialValue: initialLimits.videoBytes)
        _fileBytes = State(initialValue: initialLimits.fileBytes)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    limitRow(
                        title: "Photos", systemImage: "photo.fill", value: $photoBytes
                    )
                    limitRow(
                        title: "Voice messages", systemImage: "waveform", value: $voiceBytes
                    )
                    limitRow(
                        title: "Videos", systemImage: "play.rectangle.fill", value: $videoBytes
                    )
                    limitRow(
                        title: "Files", systemImage: "doc.fill", value: $fileBytes
                    )
                } header: {
                    Text("Maximum automatic download size")
                } footer: {
                    Text("Off still downloads small previews. Tapping media always starts it immediately.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(TojTheme.canvas)
            .navigationTitle(networkTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(MediaAutoDownloadLimits(
                            photoBytes: photoBytes,
                            voiceBytes: voiceBytes,
                            videoBytes: videoBytes,
                            fileBytes: fileBytes
                        ))
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                Text(chat == .privateChat ? "Private chats" : "Group chats")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(TojTheme.secondaryText)
                    .padding(.vertical, 8)
            }
        }
    }

    private func limitRow(
        title: LocalizedStringKey,
        systemImage: String,
        value: Binding<Int64>
    ) -> some View {
        HStack(spacing: 12) {
            Label(title, systemImage: systemImage)
                .foregroundStyle(TojTheme.text)
            Spacer()
            Menu {
                ForEach(limitOptions, id: \.self) { option in
                    Button {
                        value.wrappedValue = option
                    } label: {
                        if value.wrappedValue == option {
                            Label(Self.limitTitle(option), systemImage: "checkmark")
                        } else {
                            Text(Self.limitTitle(option))
                        }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Text(Self.limitTitle(value.wrappedValue))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2.weight(.bold))
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(TojTheme.gold)
            }
        }
        .frame(minHeight: 44)
    }

    private var networkTitle: String {
        switch network {
        case .wifi: String(localized: "Wi‑Fi")
        case .cellular: String(localized: "Mobile data")
        case .constrained: String(localized: "Low Data Mode")
        case .roaming: String(localized: "Roaming")
        }
    }

    private static func limitTitle(_ bytes: Int64) -> String {
        bytes == 0
            ? String(localized: "Off")
            : ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

private struct MediaClearSelection: Identifiable {
    let id: String
    let kind: String?
    let menuTitle: String
    let confirmationTitle: String
    let buttonTitle: String
    let message: String

    static let all = MediaClearSelection(
        id: "all",
        kind: nil,
        menuTitle: String(localized: "All downloaded media"),
        confirmationTitle: String(localized: "Clear downloaded media?"),
        buttonTitle: String(localized: "Clear downloaded media"),
        message: String(localized: "Pending uploads stay protected. Cloud media downloads again when you open it.")
    )

    static let mediaTypes: [MediaClearSelection] = [
        type(id: "photo", title: String(localized: "Photos")),
        type(id: "video", title: String(localized: "Videos")),
        type(id: "voice", title: String(localized: "Voice messages")),
        type(id: "file", title: String(localized: "Files")),
    ]

    private static func type(id: String, title: String) -> MediaClearSelection {
        MediaClearSelection(
            id: id,
            kind: id,
            menuTitle: title,
            confirmationTitle: String(localized: "Clear \(title.lowercased())?"),
            buttonTitle: String(localized: "Clear \(title.lowercased())"),
            message: String(localized: "Cached \(title.lowercased()) will be removed from this device and remain available in the cloud.")
        )
    }
}

private extension MediaCacheSizeLimit {
    var title: String {
        switch self {
        case .megabytes500: String(localized: "500 MB")
        case .gigabytes2: String(localized: "2 GB")
        case .gigabytes5: String(localized: "5 GB")
        case .gigabytes10: String(localized: "10 GB")
        case .unlimited: String(localized: "Unlimited")
        case let .custom(bytes): ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        }
    }
}

private extension MediaCacheRetention {
    var title: String {
        switch self {
        case .threeDays: String(localized: "3 days")
        case .oneWeek: String(localized: "1 week")
        case .oneMonth: String(localized: "1 month")
        case .forever: String(localized: "Forever")
        }
    }
}
