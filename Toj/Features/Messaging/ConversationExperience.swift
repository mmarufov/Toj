import SwiftUI
import AVFoundation
import AVKit
import Combine
import Contacts
import ContactsUI
import CoreLocation
import Network
import PhotosUI
import Photos
import UniformTypeIdentifiers
import UserNotifications
import UIKit

nonisolated enum VoiceGestureIntent: Equatable {
    case recording
    case cancel
    case lock

    static func resolve(translation: CGSize) -> VoiceGestureIntent {
        if translation.width < -82 { return .cancel }
        if translation.height < -72 { return .lock }
        return .recording
    }
}

private struct GroupLifecycleServiceRow: View {
    let line: CloudAppModel.Line

    private var title: String {
        switch line.serviceType {
        case "group.created":
            return String(localized: "Group created")
        case "member.added":
            return String(localized: "Members added")
        case "member.removed":
            return String(localized: "A member was removed")
        case "member.left":
            return String(localized: "A member left")
        case "member.role_changed":
            return String(localized: "Member permissions changed")
        case "dialog.title_changed":
            if let title = line.serviceData?.title, !title.isEmpty {
                return String(localized: "Group name changed to \(title)")
            }
            return String(localized: "Group name changed")
        case "dialog.photo_changed":
            return String(localized: "Group photo changed")
        case "dialog.owner_transferred":
            return String(localized: "Group ownership transferred")
        default:
            return line.text.isEmpty ? String(localized: "Group updated") : line.text
        }
    }

    var body: some View {
        Text(title)
            .font(.caption.weight(.medium))
            .foregroundStyle(TojTheme.secondaryText)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(TojTheme.raised.opacity(0.92), in: Capsule())
            .frame(maxWidth: .infinity)
            .accessibilityLabel(title)
    }
}

struct TojConversationExperience: View {
    @Bindable var model: CloudAppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var composerFocused: Bool
    @State private var showingProfile = false
    @State private var openSearchAfterProfileDismiss = false
    @State private var showingAttachments = false
    @State private var showingForwarding = false
    @State private var forwardLine: CloudAppModel.Line?
    @State private var detailsLine: CloudAppModel.Line?
    @State private var deleteLine: CloudAppModel.Line?
    @State private var reactionLine: CloudAppModel.Line?
    @State private var reportLine: CloudAppModel.Line?
    @State private var isAtBottom = true
    @State private var shouldFollowLatest = true
    @State private var didApplyOpeningAnchor = false
    @State private var openingUnreadMsgId: Int64?
    @State private var visibleTimelineTargets: [TimelineTargetID] = []
    @State private var timelinePosition = ScrollPosition(idType: TimelineTargetID.self)
    @State private var timelineScrollPhase: ScrollPhase = .idle
    @State private var voiceFingerDown = false
    @State private var voiceLocked = false
    @State private var voiceCancelled = false
    @State private var voiceStartTask: Task<Void, Never>?
    @State private var autoplayCoordinator = VideoAutoplayCoordinator()
    @State private var networkMonitor = MediaNetworkMonitor()
    @State private var showingSchedulePicker = false

    let dialogId: String

    private var dialog: CloudAppModel.Dialog? {
        model.dialogs.first { $0.id == dialogId }
    }

    private var isGroup: Bool { dialog?.type == "group" }
    private var isSavedMessages: Bool { dialog?.type == "saved" }

    private var canSend: Bool {
        guard model.activeDialogId == dialogId, !model.composerMode.isRecording else {
            return false
        }
        let attachments = model.currentDraft?.attachments ?? []
        if !attachments.isEmpty {
            return attachments.allSatisfy { $0.state == "ready" && $0.mediaId != nil }
        }
        return !model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        messageTimeline
            .background { TojChatWallpaper() }
            .overlay(alignment: .top) {
                VStack(spacing: 8) {
                    header
                    // Below the header rather than replacing it: the user still needs to see which
                    // conversation they are searching.
                    InChatSearchBar(model: model)
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .animation(reduceMotion ? nil : .snappy, value: model.inChatSearch != nil)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { composer }
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .accessibilityIdentifier("conversation-\(dialogId)")
        .task(id: dialogId) {
            didApplyOpeningAnchor = false
            isAtBottom = true
            shouldFollowLatest = true
            openingUnreadMsgId = nil
            visibleTimelineTargets = []
            timelinePosition = ScrollPosition(idType: TimelineTargetID.self)
            await model.selectDialog(dialogId)
            guard !Task.isCancelled, model.activeDialogId == dialogId else { return }
            if isGroup { await model.refreshGroupCall(dialogId: dialogId) }
            refreshOpeningUnreadDivider(for: model.openingTimelineAnchor)
            applyOpeningTimelineAnchor()
        }
        .onDisappear {
            publishTimelineViewport()
            Task { await model.flushAndDeselectDialog(dialogId) }
        }
        .onChange(of: model.activeDialogId) { previous, current in
            if previous == dialogId, current == nil { dismiss() }
        }
        .sheet(isPresented: $showingProfile, onDismiss: {
            guard openSearchAfterProfileDismiss else { return }
            openSearchAfterProfileDismiss = false
            model.openInChatSearch()
        }) {
            if isGroup {
                NavigationStack {
                    GroupProfileView(model: model, dialogId: dialogId)
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            } else {
                TojPeerProfileView(
                    model: model,
                    dialogId: dialogId,
                    onCall: {
                        showingProfile = false
                        Task { await model.startVoiceCall(dialogId: dialogId) }
                    },
                    onSearch: {
                        openSearchAfterProfileDismiss = true
                        showingProfile = false
                    }
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
        }
        .sheet(isPresented: $showingAttachments) {
            Group {
            #if DEBUG
                if model.isDemoMode {
                    DemoAttachmentPicker { attachment in
                        shouldFollowLatest = true
                        model.sendDemoAttachment(attachment)
                        showingAttachments = false
                        scrollToLatest()
                    }
                } else {
                    ProductionAttachmentPicker(
                        model: model,
                        onDone: { showingAttachments = false },
                        onSent: { followUserSendToLatest() }
                    )
                }
            #else
                ProductionAttachmentPicker(
                    model: model,
                    onDone: { showingAttachments = false },
                    onSent: { followUserSendToLatest() }
                )
            #endif
            }
            .presentationDetents([.fraction(0.72), .large])
            .presentationDragIndicator(.hidden)
            .presentationCornerRadius(34)
            .presentationBackground(TojTheme.base)
        }
        .sheet(isPresented: $showingForwarding) {
            DemoForwardingView(model: model, dialogs: model.dialogs) { targetDialogId in
                if let forwardLine {
                    Task { await model.forwardMessage(forwardLine, to: targetDialogId) }
                }
                forwardLine = nil
                showingForwarding = false
            }
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingSchedulePicker) {
            ScheduleMessageSheet(isReminder: isSavedMessages) { date in
                showingSchedulePicker = false
                send(deliverAfter: date)
            }
            .presentationDetents([.height(390)])
            .presentationDragIndicator(.visible)
        }
        .alert("Delete message?", isPresented: Binding(
            get: { deleteLine != nil },
            set: { if !$0 { deleteLine = nil } }
        )) {
            Button("Delete", role: .destructive) {
                if let deleteLine { Task { await model.deleteMessage(deleteLine) } }
                deleteLine = nil
            }
            Button("Cancel", role: .cancel) { deleteLine = nil }
        } message: {
            Text(
                isSavedMessages
                    ? String(localized: "This removes the message from Saved Messages on all your devices.")
                    : String(localized: "This removes the message for everyone in this conversation.")
            )
        }
        .alert(item: Binding(
            get: { model.operationNotice },
            set: { if $0 == nil { model.dismissOperationNotice() } }
        )) { notice in
            if notice.opensSettings {
                return Alert(
                    title: Text(notice.title), message: Text(notice.message),
                    primaryButton: .default(Text("Open Settings")) {
                        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                        UIApplication.shared.open(url)
                        model.dismissOperationNotice()
                    },
                    secondaryButton: .cancel { model.dismissOperationNotice() }
                )
            }
            return Alert(
                title: Text(notice.title), message: Text(notice.message),
                dismissButton: .default(Text("OK")) { model.dismissOperationNotice() }
            )
        }
        .confirmationDialog(
            "Choose a reaction",
            isPresented: Binding(
                get: { reactionLine != nil },
                set: { if !$0 { reactionLine = nil } }
            ),
            titleVisibility: .visible
        ) {
            ForEach(["❤️", "👍", "😂", "🔥", "😮", "😢"], id: \.self) { reaction in
                Button(reactionLine?.myReaction == reaction ? "Remove \(reaction)" : reaction) {
                    if let reactionLine {
                        Task { await model.reactToMessage(reactionLine, reaction: reaction) }
                    }
                    reactionLine = nil
                }
            }
            Button("Cancel", role: .cancel) { reactionLine = nil }
        }
        .sheet(item: $detailsLine) { line in
            MessageDetailsView(line: line)
                .presentationDetents([.height(310)])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $reportLine) { line in
            AbuseReportSheet(
                subjectKind: .message,
                submit: { reason, details, clientReportId in
                    await model.submitMessageReport(
                        line,
                        reason: reason,
                        details: details,
                        clientReportId: clientReportId
                    )
                }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    private var header: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                Button { dismiss() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 17, weight: .bold))
                        if othersUnreadCount > 0 {
                            Text(othersUnreadCount > 999 ? "999+" : "\(othersUnreadCount)")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(TojTheme.onAccent)
                                .padding(.horizontal, 7)
                                .frame(minWidth: 25, minHeight: 25)
                                .background(TojTheme.accent, in: Capsule())
                        }
                    }
                    .padding(.horizontal, othersUnreadCount > 0 ? 11 : 0)
                    .frame(minWidth: 46)
                    .frame(height: 46)
                }
                .buttonStyle(.glass)
                .accessibilityLabel("Back")
                .accessibilityValue(othersUnreadCount > 0 ? "\(othersUnreadCount) unread in other chats" : "")

                Button {
                    if model.replicaSyncState.showsRetry {
                        model.retryReplicaSync()
                    } else if !isSavedMessages {
                        showingProfile = isGroup
                            || model.capabilities.contains(.profiles)
                            || model.capabilities.contains(.calls)
                    }
                } label: {
                    HStack(spacing: 7) {
                        VStack(spacing: 1) {
                            Text(model.dialogTitle(dialogId))
                                .font(TojTheme.heading(.headline, weight: .semibold))
                                .foregroundStyle(TojTheme.text)
                                .lineLimit(1)
                            Text(headerSubtitle)
                                .font(.system(size: 12.5))
                                .foregroundStyle(headerSubtitleColor)
                                .lineLimit(1)
                                .accessibilityIdentifier("conversation-subtitle")
                        }
                        if model.replicaSyncState.showsRetry {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(TojTheme.gold)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .padding(.horizontal, 14)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .tojGlass(
                    in: Capsule(),
                    interactive: model.replicaSyncState.showsRetry
                        || (!isSavedMessages && (
                            model.capabilities.contains(.profiles)
                                || model.capabilities.contains(.calls)
                                || isGroup
                        ))
                )
                .accessibilityHint(
                    model.replicaSyncState.showsRetry
                        ? "Checks for new messages again"
                        : (!isSavedMessages && (model.capabilities.contains(.profiles) || model.capabilities.contains(.calls))
                            ? "Opens contact and privacy details"
                            : "Connection status")
                )

                if !isGroup && !isSavedMessages && model.capabilities.contains(.calls) {
                    Button {
                        Task { await model.startVoiceCall(dialogId: dialogId) }
                    } label: {
                        Image(systemName: "phone.fill")
                            .frame(width: 46, height: 46)
                    }
                    .buttonStyle(.glass)
                    .disabled(model.callCoordinator.state.isInProgress)
                    .accessibilityLabel("Call \(model.dialogTitle(dialogId))")
                }

                if !isGroup && !isSavedMessages && model.capabilities.contains(.videoCalls) {
                    Button {
                        Task { await model.startVideoCall(dialogId: dialogId) }
                    } label: {
                        Image(systemName: "video.fill")
                            .frame(width: 46, height: 46)
                    }
                    .buttonStyle(.glass)
                    .disabled(model.callCoordinator.state.isInProgress)
                    .accessibilityLabel("Video call \(model.dialogTitle(dialogId))")
                }

                if isGroup && model.capabilities.contains(.groupCalls) {
                    let activeHere = model.groupCallCoordinator.activeDialogId == dialogId
                    let available = model.groupCallCoordinator.availableCalls[dialogId] != nil
                    if activeHere || available {
                        Button {
                            if activeHere {
                                model.groupCallCoordinator.isPresented = true
                            } else {
                                Task { await model.joinGroupCall(dialogId: dialogId) }
                            }
                        } label: {
                            Image(systemName: activeHere ? "waveform.circle.fill" : "person.3.fill")
                                .foregroundStyle(.green)
                                .frame(width: 46, height: 46)
                        }
                        .buttonStyle(.glass)
                        .accessibilityLabel(activeHere ? "Return to group call" : "Join group call")
                    } else {
                        Menu {
                            Button {
                                Task { await model.startGroupCall(dialogId: dialogId, initialKind: .voice) }
                            } label: {
                                Label("Start voice chat", systemImage: "phone.fill")
                            }
                            if model.capabilities.contains(.groupVideoCalls) {
                                Button {
                                    Task { await model.startGroupCall(dialogId: dialogId, initialKind: .video) }
                                } label: {
                                    Label("Start video chat", systemImage: "video.fill")
                                }
                            }
                        } label: {
                            Image(systemName: "person.3.fill")
                                .frame(width: 46, height: 46)
                        }
                        .buttonStyle(.glass)
                        .accessibilityLabel("Start group call")
                    }
                }

                Button {
                    guard !isSavedMessages else { return }
                    showingProfile = isGroup
                        || model.capabilities.contains(.profiles)
                        || model.capabilities.contains(.calls)
                } label: {
                    CloudProfileAvatar(
                        model: model,
                        title: model.dialogTitle(dialogId),
                        media: model.dialogs.first(where: { $0.id == dialogId })?.photo,
                        size: 46,
                        colorIndex: model.dialogs.first(where: { $0.id == dialogId })?.profileColorIndex,
                        systemImage: isSavedMessages ? "bookmark.fill" : nil
                    )
                }
                .buttonStyle(.tojPressable)
                .disabled(
                    isSavedMessages
                        || (!isGroup
                        && !model.capabilities.contains(.profiles)
                        && !model.capabilities.contains(.calls))
                )
                .accessibilityLabel(
                    isSavedMessages ? "Saved Messages" : "Open \(model.dialogTitle(dialogId)) profile"
                )
                .accessibilityIdentifier(isSavedMessages ? "saved-messages-avatar" : "")
            }
        }
    }

    /// Unread total across the *other* chats — Telegram's back-pill count.
    private var othersUnreadCount: Int {
        model.dialogs.reduce(0) { total, dialog in
            dialog.id == dialogId || dialog.isArchived ? total : total + dialog.unreadCount
        }
    }

    /// This count comes from the durable dialog summary, so messages beyond the rendered window
    /// still appear in the jump-to-latest badge.
    private var durableUnreadCount: Int {
        model.dialogs.first(where: { $0.id == dialogId })?.unreadCount ?? 0
    }

    private var typingSummary: String? { model.typingSummary(dialogId: dialogId) }

    /// Telegram grammar: the subtitle is presence; connection trouble takes its place when relevant.
    private var headerSubtitle: String {
        switch model.replicaSyncState {
        case .ready:
            if isSavedMessages {
                String(localized: "Synced across your devices")
            } else if isGroup {
                typingSummary ?? String(
                    format: String(localized: "%lld members"),
                    Int64(dialog?.memberCount ?? 0)
                )
            } else {
                typingSummary ?? model.directPresenceSubtitle(dialogId: dialogId)
            }
        case .checking, .updating, .offline, .connectionSlow, .serverUnavailable,
             .sessionExpired, .protocolFailure, .localFailure, .configurationError:
            model.replicaSyncState.title
        }
    }

    private var headerSubtitleColor: Color {
        switch model.replicaSyncState {
        case .ready: typingSummary != nil ? TojTheme.gold : TojTheme.secondaryText
        case .checking, .updating, .connectionSlow: TojTheme.secondaryText
        case .offline, .serverUnavailable, .sessionExpired, .protocolFailure,
             .localFailure, .configurationError: .orange
        }
    }

    @ViewBuilder
    private func serviceRow(for line: CloudAppModel.Line) -> some View {
        if isSavedMessages {
            timelinePill(
                Text(line.text.isEmpty ? String(localized: "Saved item") : line.text),
                icon: "bookmark.fill"
            )
        } else if isGroup {
            GroupLifecycleServiceRow(line: line)
        } else {
            VoiceCallServiceRow(line: line)
        }
    }

    private var messageTimeline: some View {
        ZStack(alignment: .bottomTrailing) {
            ScrollView {
                LazyVStack(spacing: 3) {
                    if isGroup,
                       model.groupCallCoordinator.activeDialogId != dialogId,
                       let activeCall = model.groupCallCoordinator.availableCalls[dialogId] {
                        Button {
                            Task { await model.joinGroupCall(dialogId: dialogId) }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: activeCall.initialKind == .video
                                    ? "video.fill" : "waveform")
                                    .font(.title3.weight(.semibold))
                                    .foregroundStyle(.green)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(activeCall.initialKind == .video
                                        ? "Video chat in progress" : "Voice chat in progress")
                                        .font(.subheadline.weight(.semibold))
                                    Text("\(activeCall.participants.count) joined · end-to-end encrypted")
                                        .font(.caption)
                                        .foregroundStyle(TojTheme.secondaryText)
                                }
                                Spacer()
                                Text("Join")
                                    .font(.subheadline.weight(.bold))
                                    .foregroundStyle(.green)
                            }
                            .padding(14)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20))
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 8)
                        .accessibilityLabel("Join encrypted group call")
                    }

                    if isSavedMessages {
                        timelinePill(
                            Text("Notes and files for your Toj account"),
                            icon: "bookmark.fill"
                        )
                        .accessibilityLabel(CloudChatPrivacyPresentation.savedMessagesAccessibilityLabel)
                        .padding(.vertical, 8)
                    } else if !isGroup {
                        timelinePill(
                            Text(CloudChatPrivacyPresentation.title),
                            icon: CloudChatPrivacyPresentation.systemImage
                        )
                            .foregroundStyle(TojTheme.secondaryText)
                            .accessibilityLabel(CloudChatPrivacyPresentation.accessibilityLabel)
                            .padding(.vertical, 8)
                    }

                    if model.lines.isEmpty {
                        conversationLocalPlaceholder
                    }

                    if model.canLoadEarlier {
                        Button {
                            loadEarlierPreservingPosition()
                        } label: {
                            Label(model.loadingEarlier ? "Loading" : "Earlier messages", systemImage: "arrow.up")
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(.glass)
                        .disabled(model.loadingEarlier)
                        .padding(.bottom, 6)
                    }

                    ForEach(timelineItems) { item in
                        VStack(spacing: 3) {
                            if let dayLabel = item.dayLabel {
                                timelinePill(Text(verbatim: dayLabel))
                                    .padding(.vertical, 7)
                            }
                            if item.showsUnreadDivider {
                                unreadDivider
                            }
                            if item.line.kind == "service" {
                                serviceRow(for: item.line)
                                    .padding(.vertical, 5)
                            } else {
                                TojMessageBubble(
                                    model: model,
                                    line: item.line,
                                    albumLines: item.albumLines,
                                    isLastInGroup: item.isLastInGroup,
                                    actions: model.actions(for: item.line),
                                    onAction: { perform($0, on: item.line) },
                                    onSwipeReply: { model.beginReply(to: item.line); composerFocused = true }
                                )
                                .padding(.top, item.isFirstInGroup ? 5 : 0)
                            }
                        }
                        .id(item.id)
                        .searchMatchFlash(
                            isActive: item.line.msgId != nil
                                && item.line.msgId == model.focusedSearchMsgId
                        ) { model.clearSearchFocus() }
                        .transition(
                            reduceMotion
                                ? .opacity
                                : .opacity.combined(with: .scale(
                                    scale: 0.97,
                                    anchor: item.line.mine ? .bottomTrailing : .bottomLeading
                                ))
                        )
                    }

                    if model.loadingLater {
                        ProgressView()
                            .controlSize(.small)
                            .padding(.vertical, 8)
                    }

                    Color.clear
                        .frame(height: 1)
                        .id(TimelineTargetID.bottom)
                }
                .scrollTargetLayout()
                .padding(.top, 62)
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
            .scrollPosition($timelinePosition, anchor: .top)
            .scrollDismissesKeyboard(.interactively)
            .defaultScrollAnchor(.bottom)
            .environment(autoplayCoordinator)
            .environment(networkMonitor)
            .onScrollTargetVisibilityChange(idType: TimelineTargetID.self, threshold: 0.1) {
                updateTimelineVisibility($0)
            }
            .onScrollPhaseChange { oldPhase, newPhase in
                updateTimelineScrollPhase(from: oldPhase, to: newPhase)
            }
            .onChange(of: timelineLineIDs) { oldIDs, newIDs in
                if didApplyOpeningAnchor {
                    handleTimelineLineIDsChange(from: oldIDs, to: newIDs)
                } else {
                    applyOpeningTimelineAnchor()
                }
            }
            .onChange(of: model.openingTimelineAnchor) { _, anchor in
                refreshOpeningUnreadDivider(for: anchor)
                didApplyOpeningAnchor = false
                applyOpeningTimelineAnchor()
            }

            if !isAtBottom {
                Button {
                    didApplyOpeningAnchor = true
                    shouldFollowLatest = true
                    Task {
                        await model.jumpToLatest(dialogId)
                        guard model.activeDialogId == dialogId else { return }
                        scrollToLatest()
                    }
                } label: {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 16, weight: .bold))
                            .frame(width: 46, height: 46)
                        if durableUnreadCount > 0 {
                            Text(durableUnreadCount > 99 ? "99+" : "\(durableUnreadCount)")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(TojTheme.onAccent)
                                .padding(.horizontal, 5)
                                .frame(minWidth: 18, minHeight: 18)
                                .background(TojTheme.accent, in: Capsule())
                                .offset(x: 5, y: -4)
                        }
                    }
                }
                .buttonStyle(.glass)
                .padding(14)
                .transition(.opacity)
                .accessibilityLabel("Jump to latest message")
            }
        }
    }

    @ViewBuilder
    private var conversationLocalPlaceholder: some View {
        switch model.conversationOpenState {
        case .loadingLocal, .cached:
            savedMessageSkeleton
                .accessibilityLabel(String(localized: "Loading offline conversation"))
        case .empty, .ready:
            VStack(spacing: 7) {
                Image(systemName: isSavedMessages ? "bookmark.fill" : "bubble.left.and.bubble.right")
                    .font(.system(size: 22, weight: .medium))
                Text(
                    isSavedMessages
                        ? String(localized: "Save something for yourself")
                        : String(localized: "No messages yet")
                )
                    .font(.subheadline.weight(.semibold))
                Text(
                    isSavedMessages
                        ? String(localized: "Keep notes, media, links and files here. Downloaded items stay available offline.")
                        : String(localized: "Messages you send will appear here and stay available offline.")
                )
                    .font(.caption)
                    .multilineTextAlignment(.center)
            }
            .accessibilityIdentifier(isSavedMessages ? "saved-messages-empty-state" : "")
            .foregroundStyle(TojTheme.secondaryText)
            .padding(.top, 36)
            .padding(.horizontal, 32)
        case .failedLocal:
            VStack(spacing: 10) {
                Label(
                    String(localized: "Offline conversation could not be opened"),
                    systemImage: "externaldrive.badge.exclamationmark"
                )
                    .font(.subheadline.weight(.semibold))
                Button(String(localized: "Try offline copy again")) {
                    model.retryConversationLocalLoad()
                }
                    .buttonStyle(.glass)
            }
            .foregroundStyle(TojTheme.secondaryText)
            .padding(.top, 32)
        }
    }

    private var savedMessageSkeleton: some View {
        VStack(spacing: 9) {
            skeletonBubble(width: 0.62, alignment: .leading)
            skeletonBubble(width: 0.48, alignment: .trailing)
            skeletonBubble(width: 0.74, alignment: .leading)
        }
        .padding(.top, 14)
        .redacted(reason: .placeholder)
    }

    private func skeletonBubble(width: CGFloat, alignment: Alignment) -> some View {
        GeometryReader { proxy in
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .fill(TojTheme.raised.opacity(0.72))
                .frame(width: proxy.size.width * width, height: 50)
                .frame(maxWidth: .infinity, alignment: alignment)
        }
        .frame(height: 50)
    }

    private var unreadDivider: some View {
        HStack(spacing: 10) {
            Rectangle().fill(Color.white.opacity(0.12)).frame(height: 0.5)
            Text("Unread messages")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(TojTheme.secondaryText)
            Rectangle().fill(Color.white.opacity(0.12)).frame(height: 0.5)
        }
        .accessibilityLabel("Start of unread messages")
        .padding(.vertical, 7)
    }

    /// Telegram's centered timeline capsule — date separators and system notes share it.
    private func timelinePill(_ text: Text, icon: String? = nil) -> some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
            }
            text
                .font(.caption2.weight(.semibold))
        }
        .foregroundStyle(TojTheme.text.opacity(0.72))
        .padding(.horizontal, 11)
        .padding(.vertical, 5)
        .background(Color.white.opacity(0.07), in: Capsule())
    }

    private var timelineItems: [TimelinePresentationItem] {
        let grouped = Dictionary(grouping: model.lines.compactMap { line in
            line.mediaGroupId.map { ($0, line) }
        }, by: { $0.0 })
        var emittedGroups = Set<String>()
        var items: [TimelinePresentationItem] = []
        for line in model.lines {
            let albumLines: [CloudAppModel.Line]
            if let groupId = line.mediaGroupId {
                guard emittedGroups.insert(groupId).inserted else { continue }
                albumLines = (grouped[groupId] ?? [])
                    .map { $0.1 }
                    .sorted {
                        ($0.mediaGroupIndex ?? Int.max) < ($1.mediaGroupIndex ?? Int.max)
                    }
            } else {
                albumLines = []
            }
            let representative = albumLines.first ?? line
            items.append(TimelinePresentationItem(
                line: representative,
                albumLines: albumLines,
                dayLabel: representative.presentationDayLabel,
                showsUnreadDivider: (albumLines.isEmpty ? [representative] : albumLines)
                    .contains(where: { $0.msgId == openingUnreadMsgId }),
                isFirstInGroup: representative.presentationIsFirstInGroup,
                isLastInGroup: (albumLines.last ?? representative).presentationIsLastInGroup
            ))
        }
        return items
    }

    /// Telegram's bottom bar grammar: three floating Liquid Glass elements — attach circle,
    /// expanding message capsule, mic/send circle — over the timeline, no solid backdrop.
    private var composer: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(alignment: .bottom, spacing: 8) {
                if model.capabilities.contains(.media) {
                    Button { showingAttachments = true } label: {
                        Image(systemName: "paperclip")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(TojTheme.text)
                            .frame(width: 46, height: 46)
                    }
                    .buttonStyle(.glass)
                    .disabled(model.composerMode.isRecording)
                    .accessibilityLabel("Add attachment")
                }

                messageField

                if canSend {
                    Button { send() } label: {
                        Image(systemName: model.composerMode.isEditing ? "checkmark" : "paperplane.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(TojTheme.onAccent)
                            .frame(width: 46, height: 46)
                            .background(TojTheme.accent, in: Circle())
                    }
                    .buttonStyle(.tojPressable)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.6).combined(with: .opacity))
                    .accessibilityLabel(model.composerMode.isEditing ? "Save edited message" : "Send")
                    .contextMenu {
                        if !model.composerMode.isEditing,
                           model.currentDraft?.attachments.isEmpty != false {
                            if !isSavedMessages {
                                Button("Send Without Sound", systemImage: "speaker.slash.fill") {
                                    send(silent: true)
                                }
                            }
                            Button(
                                isSavedMessages ? "Set Reminder" : "Schedule Message",
                                systemImage: isSavedMessages ? "bell.badge.fill" : "calendar.badge.clock"
                            ) {
                                showingSchedulePicker = true
                            }
                        }
                    }
                } else if model.capabilities.contains(.voiceNotes) {
                    voiceRecordControl
                } else {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(TojTheme.tertiaryText)
                        .frame(width: 46, height: 46)
                        .tojGlass(in: Circle())
                        .accessibilityHidden(true)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .animation(reduceMotion ? .easeOut(duration: 0.12) : TojTheme.microAnimation, value: model.composerMode)
        .animation(reduceMotion ? .easeOut(duration: 0.12) : TojTheme.microAnimation, value: canSend)
    }

    /// The message capsule: grows with the draft (1–8 lines); the reply/edit/recording strip
    /// docks inside the same glass, above the text.
    private var messageField: some View {
        VStack(spacing: 0) {
            if model.composerMode != .text {
                composerContext
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }

            if !model.mentionSuggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(model.mentionSuggestions) { member in
                            Button {
                                model.insertMention(member)
                                composerFocused = true
                            } label: {
                                HStack(spacing: 6) {
                                    CloudProfileAvatar(
                                        model: model,
                                        title: member.displayName,
                                        media: member.photo,
                                        size: 24
                                    )
                                    Text(member.displayName)
                                        .font(.caption.weight(.semibold))
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(TojTheme.raised, in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Mention \(member.displayName)")
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                }
            }

            if let attachments = model.currentDraft?.attachments, !attachments.isEmpty {
                draftAttachmentStrip(attachments)
            }

            HStack(alignment: .bottom, spacing: 4) {
                TextField("Message", text: Binding(
                    get: { model.draft },
                    set: { value in
                        model.draft = value
                        model.userEditedComposer(
                            dialogId: dialogId,
                            text: value,
                            focused: composerFocused
                        )
                    }
                ), axis: .vertical)
                    .focused($composerFocused)
                    .lineLimit(1...8)
                    .font(.body)
                    .foregroundStyle(TojTheme.text)
                    .tint(TojTheme.gold)
                    .submitLabel(.send)
                    .onSubmit { if canSend { send() } }
                    .accessibilityLabel("Message")
                    .disabled(model.composerMode.isRecording)
                    .onChange(of: composerFocused) { _, focused in
                        model.composerFocusChanged(dialogId: dialogId, focused: focused)
                    }

                if !model.draft.isEmpty, !model.composerMode.isRecording {
                    Menu {
                        Button("Bold", systemImage: "bold") { wrapDraft(prefix: "**", suffix: "**") }
                        Button("Italic", systemImage: "italic") { wrapDraft(prefix: "_", suffix: "_") }
                        Button("Spoiler", systemImage: "eye.slash") { wrapDraft(prefix: "||", suffix: "||") }
                        Button("Monospace", systemImage: "chevron.left.forwardslash.chevron.right") {
                            wrapDraft(prefix: "`", suffix: "`")
                        }
                    } label: {
                        Image(systemName: "textformat")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(TojTheme.secondaryText)
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Format message")
                }
            }
            .padding(.leading, 15)
            .padding(.trailing, 7)
            .padding(.vertical, 8)

            #if DEBUG
            if TelegramFastUITestFixture.enabled {
                Text(
                    model.uiFixtureDraftPersistenceComplete
                        ? "Draft saved locally"
                        : "Draft save pending"
                )
                .font(.system(size: 1))
                .foregroundStyle(.clear)
                .frame(width: 1, height: 1)
                .accessibilityLabel(
                    model.uiFixtureDraftPersistenceComplete
                        ? "Draft saved locally"
                        : "Draft save pending"
                )
            }
            #endif
        }
        .tojGlass(in: RoundedRectangle(cornerRadius: 23, style: .continuous), interactive: true)
    }

    private func wrapDraft(prefix: String, suffix: String) {
        guard !model.draft.isEmpty else { return }
        if model.draft.hasPrefix(prefix), model.draft.hasSuffix(suffix),
           model.draft.count >= prefix.count + suffix.count {
            model.draft.removeFirst(prefix.count)
            model.draft.removeLast(suffix.count)
        } else {
            model.draft = prefix + model.draft + suffix
        }
        composerFocused = true
        TojFeedback.selection()
    }

    private func draftAttachmentStrip(_ attachments: [LocalDraftAttachment]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments.sorted(by: { $0.position < $1.position })) { attachment in
                    DraftAttachmentChip(
                        model: model,
                        attachment: attachment,
                        total: attachments.count,
                        onRetry: { model.retryDraftAttachment(attachment) },
                        onRemove: { model.removeDraftAttachment(attachment) },
                        onMoveEarlier: {
                            model.moveDraftAttachment(attachment.attachmentId, by: -1)
                        },
                        onMoveLater: {
                            model.moveDraftAttachment(attachment.attachmentId, by: 1)
                        },
                        onDrop: { movingId in
                            model.moveDraftAttachment(
                                movingId,
                                before: attachment.attachmentId
                            )
                        }
                    )
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 9)
        }
        .accessibilityLabel("\(attachments.count) draft attachments")
    }

    private var composerContext: some View {
        HStack(spacing: 9) {
            Capsule()
                .fill(model.composerMode.isRecording ? TojTheme.danger : TojTheme.accent)
                .frame(width: 3, height: 30)
            Image(systemName: model.composerMode.contextIcon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(model.composerMode.isRecording ? TojTheme.danger : TojTheme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.composerMode.contextTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(TojTheme.text)
                Text(model.composerMode.contextPreview)
                    .font(.caption)
                    .foregroundStyle(TojTheme.secondaryText)
                    .lineLimit(1)
            }
            if model.composerMode.isRecording {
                HStack(alignment: .center, spacing: 2) {
                    ForEach(0..<12, id: \.self) { index in
                        Capsule()
                            .fill(TojTheme.danger.opacity(0.9))
                            .frame(width: 2, height: 5 + CGFloat(model.voiceRecordingLevel) * CGFloat(6 + (index % 5) * 3))
                    }
                }
                .frame(height: 28)
                .accessibilityHidden(true)
            }
            Spacer(minLength: 8)
            Button { model.cancelComposerMode() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 28, height: 28)
                    .background(Color.white.opacity(0.08), in: Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(TojTheme.secondaryText)
            .accessibilityLabel("Cancel")
        }
        .padding(.leading, 13)
        .padding(.trailing, 9)
        .padding(.top, 9)
    }

    @ViewBuilder
    private var voiceRecordControl: some View {
        if voiceLocked && model.composerMode.isRecording {
            HStack(spacing: 6) {
                Button {
                    voiceLocked = false
                    model.cancelVoiceRecording()
                    TojFeedback.selection()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(TojTheme.danger)
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(.glass)
                .accessibilityLabel("Cancel voice message")
                Button {
                    voiceLocked = false
                    Task { await finishVoiceRecordingAndFollowLatest() }
                } label: {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(TojTheme.onAccent)
                        .frame(width: 46, height: 46)
                        .background(TojTheme.accent, in: Circle())
                }
                .buttonStyle(.tojPressable)
                .accessibilityLabel("Send voice message")
            }
        } else {
            Group {
                if model.composerMode.isRecording {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 46, height: 46)
                        .background(TojTheme.danger, in: Circle())
                } else {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(TojTheme.text)
                        .frame(width: 46, height: 46)
                        .tojGlass(in: Circle(), interactive: true)
                }
            }
            .scaleEffect(voiceFingerDown ? 1.08 : 1)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged(handleVoiceDrag)
                    .onEnded(handleVoiceRelease)
            )
            .accessibilityLabel("Hold to record voice message")
            .accessibilityHint("Release to send, slide left to cancel, or slide up to lock")
        }
    }

    private func handleVoiceDrag(_ value: DragGesture.Value) {
        if !voiceFingerDown {
            voiceFingerDown = true
            voiceCancelled = false
            voiceStartTask?.cancel()
            TojFeedback.selection()
            voiceStartTask = Task {
                await model.beginVoiceRecording()
                guard !Task.isCancelled else { return }
                if !voiceFingerDown, !voiceLocked, !voiceCancelled, model.composerMode.isRecording {
                    await finishVoiceRecordingAndFollowLatest()
                }
            }
        }
        switch VoiceGestureIntent.resolve(translation: value.translation) {
        case .cancel where !voiceCancelled:
            voiceCancelled = true
            voiceLocked = false
            voiceFingerDown = false
            voiceStartTask?.cancel()
            model.cancelVoiceRecording()
            TojFeedback.selection()
        case .lock where !voiceCancelled && !voiceLocked:
            voiceLocked = true
            TojFeedback.selection()
        default:
            break
        }
    }

    private func handleVoiceRelease(_ value: DragGesture.Value) {
        voiceFingerDown = false
        guard !voiceCancelled else { voiceCancelled = false; return }
        guard !voiceLocked else { return }
        if model.composerMode.isRecording {
            Task { await finishVoiceRecordingAndFollowLatest() }
        }
    }

    private func send(silent: Bool = false, deliverAfter: Date? = nil) {
        guard canSend else { return }
        TojFeedback.sent()
        let shouldFollowSend = !model.composerMode.isEditing
        if shouldFollowSend { shouldFollowLatest = true }
        Task {
            await model.sendDraft(silent: silent, deliverAfter: deliverAfter)
            if shouldFollowSend { scrollToLatest() }
        }
    }

    private func finishVoiceRecordingAndFollowLatest() async {
        shouldFollowLatest = true
        await model.finishVoiceRecording()
        TojFeedback.sent()
        scrollToLatest()
    }

    private func followUserSendToLatest() {
        shouldFollowLatest = true
        scrollToLatest()
    }

    private func perform(_ action: MessageAction, on line: CloudAppModel.Line) {
        switch action {
        case .reply:
            model.beginReply(to: line)
            composerFocused = true
        case .react:
            reactionLine = line
        case .copy:
            UIPasteboard.general.string = line.text
            TojFeedback.selection()
        case .edit:
            model.beginEditing(line)
            composerFocused = true
        case .save:
            Task { await model.saveMessage(line) }
        case .forward:
            forwardLine = line
            showingForwarding = true
        case .delete:
            deleteLine = line
        case .retry:
            model.retryFailedMessage(line)
        case .remove:
            model.removeFailedMessage(line)
        case .report:
            reportLine = line
        case .inspect:
            detailsLine = line
        }
    }

    private var timelineLineIDs: [String] {
        timelineItems.map(\.line.id)
    }

    private var visibleTimelineLineIDs: [String] {
        let currentLineIDs = Set(timelineLineIDs)
        return visibleTimelineTargets.compactMap { target in
            guard case let .message(lineID) = target, currentLineIDs.contains(lineID) else {
                return nil
            }
            return lineID
        }
    }

    private func applyOpeningTimelineAnchor() {
        guard model.activeDialogId == dialogId else { return }
        switch model.openingTimelineAnchor {
        case let .provisionalFirstUnread(msgId), let .firstUnread(msgId), let .saved(msgId):
            guard let line = model.lines.first(where: { $0.msgId == msgId }) else {
                // A sparse first bootstrap page may not contain this semantic target yet. Keep
                // rendering the cached recent page while the model hydrates around the anchor.
                shouldFollowLatest = false
                isAtBottom = false
                return
            }
            didApplyOpeningAnchor = true
            shouldFollowLatest = false
            isAtBottom = false
            timelinePosition.scrollTo(id: TimelineTargetID.message(line.id), anchor: .top)
        case .bottom:
            guard !model.lines.isEmpty else {
                // SwiftUI cannot resolve the bottom sentinel before the first local rows exist.
                // Keep the command pending; the line-ID change will apply it after layout targets
                // are present instead of marking an empty scroll as complete.
                didApplyOpeningAnchor = false
                shouldFollowLatest = true
                isAtBottom = true
                return
            }
            didApplyOpeningAnchor = true
            scrollToLatest(animated: false, clearUnread: false)
        }
    }

    private func refreshOpeningUnreadDivider(for anchor: TimelineAnchor) {
        if case let .firstUnread(msgId) = anchor {
            openingUnreadMsgId = msgId
        } else {
            openingUnreadMsgId = nil
        }
    }

    private func loadEarlierPreservingPosition() {
        let existingLineIDs = timelineLineIDs
        let visibleAnchor = visibleTimelineTargets.first { target in
            if case .message = target { return true }
            return false
        }
        let positionAnchor = timelinePosition.viewID(type: TimelineTargetID.self).flatMap { target in
            if case .message = target { return target }
            return nil
        }
        let preservedAnchor = positionAnchor ?? visibleAnchor
        shouldFollowLatest = false
        Task {
            await model.loadEarlier()
            guard existingLineIDs != timelineLineIDs,
                  let preservedAnchor,
                  timelinePosition.viewID(type: TimelineTargetID.self) != preservedAnchor else {
                return
            }
            timelinePosition.scrollTo(id: preservedAnchor, anchor: .top)
        }
    }

    private func handleTimelineLineIDsChange(from oldIDs: [String], to newIDs: [String]) {
        guard didApplyOpeningAnchor else { return }
        if !shouldFollowLatest {
            return
        }
        guard TimelineScrollBehavior.addedMessagesWereAppended(
            oldIDs: oldIDs,
            newIDs: newIDs
        ) else { return }
        scrollToLatest()
    }

    private func updateTimelineVisibility(_ targets: [TimelineTargetID]) {
        visibleTimelineTargets = targets
        guard didApplyOpeningAnchor else { return }
        let renderedBottomIsVisible = targets.contains(.bottom)
        if renderedBottomIsVisible, model.canLoadLater, !model.loadingLater {
            shouldFollowLatest = false
            isAtBottom = false
            Task { await model.loadLater() }
        }
        let bottomIsVisible = renderedBottomIsVisible && !model.canLoadLater
        isAtBottom = bottomIsVisible
        if bottomIsVisible {
            shouldFollowLatest = true
        } else if timelineScrollPhase == .tracking
                    || timelineScrollPhase == .interacting
                    || timelineScrollPhase == .decelerating {
            shouldFollowLatest = false
        }
        publishTimelineViewport()
    }

    private func updateTimelineScrollPhase(from oldPhase: ScrollPhase, to newPhase: ScrollPhase) {
        timelineScrollPhase = newPhase
        guard didApplyOpeningAnchor, newPhase == .idle else { return }
        if !isAtBottom, oldPhase != .idle, oldPhase != .animating {
            shouldFollowLatest = false
        }
        publishTimelineViewport()
    }

    private func publishTimelineViewport() {
        guard didApplyOpeningAnchor, model.activeDialogId == dialogId else { return }
        model.updateTimelineViewport(
            dialogId: dialogId,
            visibleLineIds: visibleTimelineLineIDs,
            isAtBottom: isAtBottom
        )
    }

    private func scrollToLatest(animated: Bool = true, clearUnread _: Bool = true) {
        let action = { timelinePosition.scrollTo(edge: .bottom) }
        if animated {
            withAnimation(reduceMotion ? .easeOut(duration: 0.12) : TojTheme.microAnimation, action)
        } else {
            action()
        }
        shouldFollowLatest = true
        isAtBottom = true
    }
}

nonisolated enum TimelineScrollBehavior {
    static func addedMessagesWereAppended(oldIDs: [String], newIDs: [String]) -> Bool {
        guard !newIDs.isEmpty else { return false }
        // The first encrypted SQLite snapshot is an append from the view's perspective. Treating
        // [] -> messages as false was the exact blank-until-touch opening race.
        if oldIDs.isEmpty { return true }
        guard let previousLastID = oldIDs.last,
              let previousLastIndex = newIDs.firstIndex(of: previousLastID) else {
            return false
        }
        let previousIDs = Set(oldIDs)
        let indexAfterPreviousLast = newIDs.index(after: previousLastIndex)
        return newIDs[indexAfterPreviousLast...].contains { !previousIDs.contains($0) }
    }
}

nonisolated private enum TimelineTargetID: Hashable, Sendable {
    case message(String)
    case bottom
}

private struct TimelinePresentationItem: Identifiable {
    let line: CloudAppModel.Line
    let albumLines: [CloudAppModel.Line]
    let dayLabel: String?
    let showsUnreadDivider: Bool
    let isFirstInGroup: Bool
    let isLastInGroup: Bool

    var id: TimelineTargetID { .message(line.id) }
}

private struct DraftAttachmentChip: View {
    let model: CloudAppModel
    let attachment: LocalDraftAttachment
    let total: Int
    let onRetry: () -> Void
    let onRemove: () -> Void
    let onMoveEarlier: () -> Void
    let onMoveLater: () -> Void
    let onDrop: (String) -> Void
    @State private var thumbnail: UIImage?

    private var icon: String {
        switch attachment.media?.kind {
        case "photo": "photo.fill"
        case "video": "video.fill"
        default: "doc.fill"
        }
    }

    var body: some View {
        HStack(spacing: 7) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(TojTheme.raised)
                    .frame(width: 38, height: 38)
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 38, height: 38)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(TojTheme.gold)
                }
                Text("\(attachment.position + 1)")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(TojTheme.onAccent)
                    .frame(width: 16, height: 16)
                    .background(TojTheme.accent, in: Circle())
                    .offset(x: 15, y: -15)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(attachment.media?.displayName ?? String(localized: "Preparing"))
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                if attachment.state == "ready" {
                    Label("Ready", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(TojTheme.secure)
                } else if attachment.state == "failed" || attachment.state == "terminal" {
                    Button("Retry", action: onRetry)
                        .buttonStyle(.plain)
                        .foregroundStyle(TojTheme.danger)
                } else {
                    ProgressView(value: attachment.progress)
                        .tint(TojTheme.gold)
                        .frame(width: 58)
                }
            }
            .font(.caption2)

            Menu {
                Button("Move earlier", systemImage: "arrow.left", action: onMoveEarlier)
                    .disabled(attachment.position == 0)
                Button("Move later", systemImage: "arrow.right", action: onMoveLater)
                    .disabled(attachment.position >= total - 1)
                Button("Remove", systemImage: "trash", role: .destructive, action: onRemove)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.caption.weight(.bold))
                    .frame(width: 28, height: 32)
            }
            .foregroundStyle(TojTheme.secondaryText)
            .accessibilityIdentifier("draft-attachment-menu-\(attachment.attachmentId)")
        }
        .padding(.leading, 7)
        .padding(.trailing, 4)
        .padding(.vertical, 5)
        .background(TojTheme.strong, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(TojTheme.hairlineStrong, lineWidth: 0.5)
        )
        .draggable(attachment.attachmentId)
        .dropDestination(for: String.self) { values, _ in
            guard let movingId = values.first else { return false }
            onDrop(movingId)
            return true
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Attachment \(attachment.position + 1) of \(total), \(attachment.state)"
        )
        .accessibilityIdentifier("draft-attachment-\(attachment.attachmentId)")
        .task(id: attachment.media?.id) {
            guard let media = attachment.media,
                  media.kind == "photo" || media.kind == "video" else {
                thumbnail = nil
                return
            }
            thumbnail = await model.presentationImage(for: media, variant: .bubble720)
        }
    }
}

private struct VoiceCallServiceRow: View {
    let line: CloudAppModel.Line

    private var presentation: VoiceCallServicePresentation {
        .parse(body: line.text, callerIsCurrentAccount: line.mine)
    }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: presentation.systemImage)
                .foregroundStyle(TojTheme.secure)
            Text(presentation.title)
            if let duration = presentation.duration {
                Text(duration)
                    .foregroundStyle(TojTheme.secondaryText)
            }
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(TojTheme.text)
        .padding(.horizontal, 13)
        .padding(.vertical, 8)
        .background(TojTheme.strong.opacity(0.88), in: Capsule())
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

private struct TojMessageBubble: View {
    let model: CloudAppModel
    let line: CloudAppModel.Line
    let albumLines: [CloudAppModel.Line]
    let isLastInGroup: Bool
    let actions: [MessageAction]
    let onAction: (MessageAction) -> Void
    let onSwipeReply: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var replyOffset: CGFloat = 0
    @State private var showingMedia = false
    @State private var spoilersRevealed = false
    @Namespace private var mediaZoom

    var body: some View {
        HStack {
            if line.mine { Spacer(minLength: 76) }
            if isIncomingGroupMessage {
                Group {
                    if isLastInGroup {
                        CloudProfileAvatar(
                            model: model,
                            title: senderLabel,
                            media: line.senderAccountId.flatMap {
                                model.groupMemberPhoto(accountId: $0, dialogId: line.dialogId ?? "")
                            },
                            size: 28
                        )
                            .accessibilityHidden(true)
                    } else {
                        Color.clear
                            .frame(width: 28, height: 28)
                    }
                }
                .frame(width: 28, alignment: .bottom)
            }

            VStack(alignment: .leading, spacing: 4) {
                if showsSenderName {
                    Text(senderLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(TojTheme.gold)
                        .lineLimit(1)
                }
                if line.isForwarded {
                    Label("Forwarded message", systemImage: "arrowshape.turn.up.right.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(line.mine ? TojTheme.gold : TojTheme.secondaryText)
                        .padding(.horizontal, isVisualMedia ? 6 : 0)
                        .padding(.top, isVisualMedia ? 4 : 0)
                }
                if line.replyPreview != nil {
                    replyQuote
                }

                if !albumLines.isEmpty {
                    AlbumMediaBubble(
                        model: model,
                        lines: albumLines,
                        expectedCount: line.mediaGroupCount ?? albumLines.count,
                        onRetry: {
                            model.retryFailedMessage(
                                albumLines.first(where: {
                                    if case .failed = $0.delivery { return true }
                                    return false
                                }) ?? line
                            )
                        },
                        onRemove: { model.removeFailedMedia(line) }
                    )
                    .contentShape(Rectangle())
                    .matchedTransitionSource(id: line.id, in: mediaZoom)
                    .onTapGesture { showingMedia = true }
                } else if let media = line.media {
                    ProductionMediaBubble(
                        model: model, line: line, media: media,
                        onRetry: { model.retryFailedMessage(line) },
                        onRemove: { model.removeFailedMedia(line) }
                    )
                        .contentShape(Rectangle())
                        .matchedTransitionSource(id: line.id, in: mediaZoom)
                        .onTapGesture { if media.kind != "voice" { showingMedia = true } }
                } else if let attachment = line.attachment {
                    DemoAttachmentBubble(attachment: attachment)
                        .contentShape(Rectangle())
                        .matchedTransitionSource(id: line.id, in: mediaZoom)
                        .onTapGesture { showingMedia = true }
                        .accessibilityAddTraits(.isButton)
                        .accessibilityHint("Opens media viewer")
                }

                if hasCaptionText {
                    captionText
                        .padding(.horizontal, isVisualMedia ? 8 : 0)
                }

                if line.media == nil,
                   line.attachment == nil,
                   let url = RichMessageText.firstWebURL(in: line.text) {
                    SafeLinkPreviewCard(url: url, preview: line.linkPreview)
                        .padding(.top, 2)
                }

                if line.media == nil, let progress = line.transferProgress, progress < 1 {
                    ProgressView(value: progress)
                        .tint(TojTheme.secure)
                        .accessibilityLabel("Uploading")
                        .accessibilityValue("\(Int(progress * 100)) percent")
                }

                if !line.reactions.isEmpty {
                    reactionsRow
                } else if needsStandaloneMeta {
                    HStack {
                        Spacer(minLength: 0)
                        metaRow
                    }
                }
            }
            .padding(.horizontal, isVisualMedia ? 4 : 12)
            .padding(.vertical, isVisualMedia ? 4 : 7)
            .background(line.mine ? TojTheme.bubbleMine : TojTheme.strong)
            .clipShape(bubbleShape)
            .overlay(bubbleShape.stroke(line.mine ? TojTheme.gold.opacity(0.16) : TojTheme.hairline, lineWidth: 0.5))
            .offset(x: replyOffset)
            .background(alignment: line.mine ? .trailing : .leading) {
                Image(systemName: "arrowshape.turn.up.left.fill")
                    .foregroundStyle(TojTheme.secondaryText)
                    .opacity(min(1, abs(replyOffset) / 48))
                    .offset(x: line.mine ? 28 : -28)
            }

            if !line.mine { Spacer(minLength: 76) }
        }
        .contentShape(Rectangle())
        .simultaneousGesture(
            DragGesture(minimumDistance: 16)
                .onChanged { value in
                    let inward = line.mine ? min(0, value.translation.width) : max(0, value.translation.width)
                    replyOffset = max(-62, min(62, inward * 0.55))
                }
                .onEnded { _ in
                    if abs(replyOffset) > 28 {
                        TojFeedback.selection()
                        onSwipeReply()
                    }
                    withAnimation(TojTheme.microAnimation) { replyOffset = 0 }
                }
        )
        .contextMenu {
            ForEach(actions) { action in
                Button(role: action == .delete || action == .remove ? .destructive : nil) {
                    onAction(action)
                } label: {
                    Label(action.title, systemImage: action.systemImage)
                }
                .accessibilityIdentifier(action == .save ? "message-action-save" : "")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(
            line.mediaGroupId.map {
                "media-group-\($0)\(line.msgId == nil ? "-pending" : "")"
            }
                ?? line.media.map { "media-bubble-\($0.id)" }
                ?? "message-\(line.clientMsgId)"
        )
        .accessibilityLabel(accessibilityDescription)
        .accessibilityHint("Swipe to reply or use message actions")
        .accessibilityActions {
            ForEach(actions) { action in
                Button(action.title) { onAction(action) }
            }
        }
        .fullScreenCover(isPresented: $showingMedia) {
            Group {
                if albumLines.count > 1 {
                    TabView {
                        ForEach(albumLines) { albumLine in
                            if let media = albumLine.media {
                                ProductionMediaViewer(
                                    model: model,
                                    media: media,
                                    line: albumLine,
                                    title: model.dialogTitle(albumLine.dialogId ?? ""),
                                    subtitle: albumLine.presentationMediaTimestampLabel ?? "",
                                    onReply: { model.beginReply(to: albumLine) }
                                )
                                .tag(albumLine.id)
                            }
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .always))
                    .background(Color.black)
                } else if let media = line.media {
                    ProductionMediaViewer(
                        model: model, media: media, line: line,
                        title: model.dialogTitle(line.dialogId ?? ""),
                        subtitle: line.presentationMediaTimestampLabel ?? "",
                        onReply: { onAction(.reply) }
                    )
                } else if let attachment = line.attachment {
                    DemoMediaViewer(
                        attachment: attachment,
                        title: model.dialogTitle(line.dialogId ?? ""),
                        subtitle: line.presentationMediaTimestampLabel ?? "",
                        onDelete: actions.contains(.delete)
                            ? { Task { await model.deleteMessage(line) } }
                            : nil
                    )
                }
            }
            .navigationTransition(.zoom(sourceID: line.id, in: mediaZoom))
        }
        #if DEBUG
        // Demo/dev hook (same family as TOJ_DEMO_DIALOG): auto-present this line's media viewer.
        .task(id: line.id) {
            guard ProcessInfo.processInfo.environment["TOJ_DEMO_MEDIA"] == line.id,
                  line.media != nil || line.attachment != nil else { return }
            try? await Task.sleep(for: .milliseconds(450))
            showingMedia = true
        }
        #endif
    }

    /// Telegram tail grammar: bubbles stay fully rounded; only the last message of a sender's
    /// run pulls its bottom corner in toward the edge.
    private var bubbleShape: UnevenRoundedRectangle {
        let tail = isLastInGroup ? TojRadius.bubbleTail : TojRadius.bubble
        return UnevenRoundedRectangle(
            topLeadingRadius: TojRadius.bubble,
            bottomLeadingRadius: line.mine ? TojRadius.bubble : tail,
            bottomTrailingRadius: line.mine ? tail : TojRadius.bubble,
            topTrailingRadius: TojRadius.bubble,
            style: .continuous
        )
    }

    private var isVisualMedia: Bool {
        if !albumLines.isEmpty {
            return albumLines.allSatisfy {
                $0.media?.kind == "photo" || $0.media?.kind == "video"
            }
        }
        return line.media.map { $0.kind == "photo" || $0.kind == "video" } ?? false
    }

    private var showsSenderName: Bool {
        isIncomingGroupMessage && line.presentationIsFirstInGroup
    }

    private var isIncomingGroupMessage: Bool {
        !line.mine && model.dialogs.first(where: { $0.id == line.dialogId })?.type == "group"
    }

    private var senderLabel: String {
        line.senderDisplayName ?? String(localized: "Group member")
    }

    private var hasCaptionText: Bool {
        !line.text.isEmpty && (line.attachment == nil || line.text != line.attachment?.title)
    }

    /// Photo/video bubbles without a caption already carry time + ticks on the image overlay.
    private var showsMediaOverlayMeta: Bool {
        isVisualMedia && line.text.isEmpty
    }

    private var needsStandaloneMeta: Bool {
        !hasCaptionText && !showsMediaOverlayMeta
    }

    /// Telegram's signature layout: the timestamp flows with the last line of text. Invisible
    /// meta-sized text reserves the corner, and the real meta row is drawn over it — so a short
    /// last line shares the line with the time, and a full one wraps around it.
    private var captionText: some View {
        Group {
            if line.reactions.isEmpty {
                messageTextWithMetaReservation
            } else {
                messageText
            }
        }
        .textSelection(.enabled)
        .overlay(alignment: .bottomTrailing) {
            if line.reactions.isEmpty {
                metaRow
            }
        }
        .onTapGesture {
            guard RichMessageText.containsSpoiler(line.text) else { return }
            withAnimation(reduceMotion ? nil : TojTheme.microAnimation) {
                spoilersRevealed.toggle()
            }
        }
        .accessibilityHint(
            RichMessageText.containsSpoiler(line.text) && !spoilersRevealed
                ? "Contains hidden spoiler. Double tap to reveal."
                : ""
        )
    }

    private var messageText: Text {
        Text(RichMessageText.attributed(line.text, revealsSpoilers: spoilersRevealed))
            .font(.body)
            .foregroundStyle(TojTheme.text)
    }

    private var messageTextWithMetaReservation: Text {
        let reservation = Text(verbatim: "\u{2004}\u{2004}" + metaReservation)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.clear)
        return Text("\(messageText)\(reservation)")
    }

    private var metaReservation: String {
        var parts: [String] = []
        if line.isEdited { parts.append(String(localized: "edited")) }
        if let timestamp = line.presentationTimestampLabel { parts.append(timestamp) }
        if line.mine { parts.append(line.delivery == .seen ? "✓✓" : "✓") }
        return parts.joined(separator: " ")
    }

    private var metaRow: some View {
        HStack(spacing: 3) {
            if line.isEdited { Text("edited") }
            if let timestamp = line.presentationTimestampLabel { Text(timestamp) }
            if line.mine { DeliveryTicks(delivery: line.delivery) }
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(metaColor)
    }

    private var metaColor: Color {
        if case .failed = line.delivery { return TojTheme.danger }
        return line.mine ? TojTheme.gold.opacity(0.8) : TojTheme.secondaryText
    }

    private var replyQuote: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(TojTheme.gold)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(replyAuthor)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(TojTheme.gold)
                Text(line.replyPreview ?? "")
                    .font(.caption)
                    .foregroundStyle(TojTheme.text.opacity(0.78))
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .background(TojTheme.gold.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, isVisualMedia ? 6 : 0)
        .padding(.top, isVisualMedia ? 4 : 0)
    }

    private var replyAuthor: String {
        if let replyId = line.replyToMsgId,
           let original = model.lines.first(where: { $0.msgId == replyId }) {
            if original.mine {
                return String(localized: "You")
            }
            if isIncomingGroupMessage {
                return original.senderDisplayName ?? String(localized: "Group member")
            }
            return model.dialogTitle(line.dialogId ?? "")
        }
        return model.dialogTitle(line.dialogId ?? "")
    }

    /// Reactions live inside the bubble, Telegram-style: emoji pills (gold when it's my
    /// reaction, tap toggles) with the time + ticks finishing the row.
    private var reactionsRow: some View {
        HStack(alignment: .bottom, spacing: 4) {
            ForEach(line.reactions, id: \.self) { badge in
                reactionPill(badge)
            }
            if !showsMediaOverlayMeta {
                metaRow
                    .padding(.leading, 5)
                    .padding(.bottom, 1)
            }
        }
        .padding(.horizontal, isVisualMedia ? 6 : 0)
        .padding(.bottom, isVisualMedia ? 4 : 0)
    }

    private func reactionPill(_ badge: String) -> some View {
        let emoji = badge.split(separator: " ").first.map(String.init) ?? badge
        let isMine = line.myReaction == emoji
        return Button {
            guard actions.contains(.react) else { return }
            TojFeedback.selection()
            Task { await model.reactToMessage(line, reaction: emoji) }
        } label: {
            Text(badge)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isMine ? TojTheme.onAccent : TojTheme.text)
                .padding(.horizontal, 8)
                .frame(height: 25)
                .background(
                    isMine ? AnyShapeStyle(TojTheme.accent) : AnyShapeStyle(Color.white.opacity(0.10)),
                    in: Capsule()
                )
        }
        .buttonStyle(.tojPressable)
        .accessibilityLabel("Reaction \(badge)")
        .accessibilityAddTraits(isMine ? .isSelected : [])
    }

    private var accessibilityDescription: String {
        let sender = line.mine
            ? String(localized: "You")
            : (isIncomingGroupMessage ? senderLabel : String(localized: "Contact"))
        let state: String
        switch line.delivery {
        case .sending: state = String(localized: "sending")
        case .sent: state = String(localized: "sent")
        case .seen: state = String(localized: "seen")
        case .failed: state = String(localized: "failed")
        }
        let content = albumLines.isEmpty
            ? line.text
            : "Media group, \(albumLines.count) of \(line.mediaGroupCount ?? albumLines.count) items, \(line.text)"
        return "\(sender): \(content), \(state)"
    }
}

/// Telegram's delivery language: clock while sending, one check when the server has it,
/// a double check once seen. SF has no double-check glyph, so it's two overlapped checkmarks.
private struct DeliveryTicks: View {
    let delivery: CloudAppModel.Line.Delivery

    var body: some View {
        switch delivery {
        case .sending:
            Image(systemName: "clock")
                .font(.system(size: 9.5, weight: .semibold))
        case .sent:
            Image(systemName: "checkmark")
                .font(.system(size: 9.5, weight: .bold))
        case .seen:
            ZStack(alignment: .leading) {
                Image(systemName: "checkmark")
                Image(systemName: "checkmark")
                    .padding(.leading, 4)
            }
            .font(.system(size: 9.5, weight: .bold))
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 10, weight: .bold))
        }
    }
}

private struct DemoAttachmentBubble: View {
    let attachment: DemoAttachment

    var body: some View {
        switch attachment {
        case let .photo(name):
            ZStack(alignment: .bottomLeading) {
                LinearGradient(colors: [Color(hex: 0x27333A), Color(hex: 0x101C22)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "photo.fill")
                    .font(.system(size: 42, weight: .light))
                    .foregroundStyle(Color.white.opacity(0.72))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Text(name)
                    .font(.caption.weight(.semibold))
                    .padding(10)
            }
            .frame(width: 230, height: 145)
            .clipShape(RoundedRectangle(cornerRadius: TojRadius.tile, style: .continuous))
        case let .video(name, duration):
            attachmentTile(icon: "play.fill", title: name, detail: duration)
        case let .file(name, size):
            attachmentTile(icon: "doc.fill", title: name, detail: size)
        case let .voice(duration):
            HStack(spacing: 10) {
                Image(systemName: "play.fill").frame(width: 34, height: 34).background(TojTheme.text, in: Circle()).foregroundStyle(TojTheme.canvas)
                Image(systemName: "waveform").foregroundStyle(TojTheme.secondaryText)
                Text(duration).font(.caption).foregroundStyle(TojTheme.secondaryText)
            }
        case let .link(title, host):
            attachmentTile(icon: "link", title: title, detail: host)
        }
    }

    private func attachmentTile(icon: String, title: String, detail: String) -> some View {
        HStack(spacing: 11) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 42, height: 42)
                .background(TojTheme.raised, in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(TojTheme.secondaryText)
            }
        }
        .frame(maxWidth: 235, alignment: .leading)
    }
}

nonisolated enum MediaBubbleLayout {
    static func size(width: Int?, height: Int?, maxWidth: CGFloat = 268) -> CGSize {
        guard let width, let height, width > 0, height > 0 else {
            return CGSize(width: maxWidth, height: 180)
        }
        let ratio = CGFloat(width) / CGFloat(height)
        let desiredHeight = maxWidth / ratio
        if desiredHeight > 300 {
            return CGSize(width: min(maxWidth, max(160, 300 * ratio)), height: 300)
        }
        return CGSize(width: maxWidth, height: max(116, desiredHeight))
    }
}

/// Reports whether inline videos may autoplay. Like Telegram's "Autoplay on Wi-Fi" default, this is
/// on for un-metered, unconstrained links and off on cellular so autoplay never fights the throttled
/// gateway. One instance is shared through the environment.
@MainActor @Observable
final class MediaNetworkMonitor {
    private(set) var allowsAutoplay = false
    private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let allowed = path.status == .satisfied && !path.isExpensive && !path.isConstrained
            Task { @MainActor in self?.allowsAutoplay = allowed }
        }
        monitor.start(queue: DispatchQueue(label: "com.toj.media.network-monitor"))
    }

    deinit { monitor.cancel() }
}

/// Ensures only one inline video autoplays at a time (Telegram plays the most-visible clip). Bubbles
/// report their on-screen state; the most recently revealed one wins.
@MainActor @Observable
final class VideoAutoplayCoordinator {
    private(set) var activeID: String?
    private var visible: [String] = []

    func setVisible(_ id: String, _ isVisible: Bool) {
        visible.removeAll { $0 == id }
        if isVisible { visible.append(id) }
        let next = visible.last
        if next != activeID { activeID = next }
    }
}

/// A muted, seamlessly-looping inline preview that streams through the resource loader — the same
/// autoplay Telegram shows in the timeline. Builds a player only while `isActive`, tears it down
/// otherwise, so at most one clip streams at once.
private struct InlineVideoPlayerView: View {
    let model: CloudAppModel
    let media: CloudMedia
    let isActive: Bool
    @State private var player: AVQueuePlayer?
    @State private var looper: AVPlayerLooper?
    @State private var owner: StreamingMediaAsset?
    @State private var startTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            if let player {
                VideoLayerView(player: player).transition(.opacity)
            }
        }
        .onChange(of: isActive, initial: true) { _, active in
            if active { start() } else { stop() }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        guard player == nil else { return }
        startTask?.cancel()
        startTask = Task { @MainActor in
            guard let owner = await model.streamingVideoAsset(for: media),
                  !Task.isCancelled,
                  isActive,
                  player == nil
            else { return }
            self.owner = owner
            let queue = AVQueuePlayer()
            queue.isMuted = true
            queue.actionAtItemEnd = .none
            looper = AVPlayerLooper(player: queue, templateItem: AVPlayerItem(asset: owner.asset))
            player = queue
            queue.play()
        }
    }

    private func stop() {
        startTask?.cancel()
        startTask = nil
        player?.pause()
        looper = nil
        player = nil
        owner = nil
    }
}

private struct ProductionMediaBubble: View {
    let model: CloudAppModel
    let line: CloudAppModel.Line
    let media: CloudMedia
    let onRetry: () -> Void
    let onRemove: () -> Void
    @Environment(VideoAutoplayCoordinator.self) private var coordinator: VideoAutoplayCoordinator?
    @Environment(MediaNetworkMonitor.self) private var network: MediaNetworkMonitor?
    @State private var thumbnail: UIImage?

    /// A sent (not uploading, not failed) video is the only thing that can autoplay.
    private var isFinishedVideo: Bool {
        guard media.kind == "video", line.transferProgress == nil else { return false }
        if case .failed = line.delivery { return false }
        return true
    }

    /// Autoplay only on an un-metered link (network policy); playback of the active clip is muted.
    private var autoplayEligible: Bool {
        isFinishedVideo && (network?.allowsAutoplay ?? false)
    }

    private var isAutoplaying: Bool {
        autoplayEligible && coordinator?.activeID == media.id
    }

    var body: some View {
        Group {
            switch media.kind {
            case "photo", "video":
                MediaBubbleContent(
                    media: media, line: line, thumbnail: thumbnail,
                    onRetry: onRetry, onRemove: onRemove,
                    videoOverlay: videoOverlay, isAutoplaying: isAutoplaying
                )
                .task(id: media.id) {
                    guard thumbnail == nil else { return }
                    thumbnail = await model.presentationImage(for: media, variant: .bubble720)
                }
                .onScrollVisibilityChange(threshold: 0.6) { visible in
                    coordinator?.setVisible(media.id, visible && autoplayEligible)
                }
                .onDisappear { coordinator?.setVisible(media.id, false) }
            case "voice":
                VoiceNotePlaybackView(model: model, media: media)
            default:
                HStack(spacing: 11) {
                    Image(systemName: "doc.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 42, height: 42)
                        .background(TojTheme.raised, in: Circle())
                    VStack(alignment: .leading, spacing: 3) {
                        Text(media.displayName).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(media.formattedSize).font(.caption).foregroundStyle(TojTheme.secondaryText)
                    }
                }
                .frame(maxWidth: 235, alignment: .leading)
                .accessibilityLabel("\(media.displayName), \(media.formattedSize)")
            }
        }
    }

    /// The muted looping preview, layered over the thumbnail while a sent video is on screen. Kept
    /// mounted (idle until active) so its player state survives becoming the active clip.
    private var videoOverlay: AnyView {
        guard isFinishedVideo else { return AnyView(EmptyView()) }
        // Pin identity so wrapping in AnyView can't reset the player's state across re-renders.
        return AnyView(InlineVideoPlayerView(model: model, media: media, isActive: isAutoplaying).id(media.id))
    }
}

enum AlbumSlotAssignment {
    static func linesBySlot(
        _ lines: [CloudAppModel.Line]
    ) -> [Int: CloudAppModel.Line] {
        Dictionary(
            lines.compactMap { line in
                line.mediaGroupIndex.map { ($0, line) }
            },
            uniquingKeysWith: { current, _ in current }
        )
    }

    static func slotCount(
        lines: [CloudAppModel.Line],
        expectedCount: Int
    ) -> Int {
        min(10, max(lines.count, expectedCount))
    }
}

private struct AlbumMediaBubble: View {
    let model: CloudAppModel
    let lines: [CloudAppModel.Line]
    let expectedCount: Int
    let onRetry: () -> Void
    let onRemove: () -> Void

    private var visual: Bool {
        lines.allSatisfy { $0.media?.kind == "photo" || $0.media?.kind == "video" }
    }

    private var slotCount: Int {
        AlbumSlotAssignment.slotCount(lines: lines, expectedCount: expectedCount)
    }

    private var linesBySlot: [Int: CloudAppModel.Line] {
        AlbumSlotAssignment.linesBySlot(lines)
    }

    var body: some View {
        Group {
            if visual {
                LazyVGrid(
                    columns: [
                        GridItem(.fixed(126), spacing: 3),
                        GridItem(.fixed(126), spacing: 3),
                    ],
                    spacing: 3
                ) {
                    ForEach(0..<slotCount, id: \.self) { index in
                        if let line = linesBySlot[index], let media = line.media {
                            AlbumVisualCell(model: model, line: line, media: media)
                        } else {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(TojTheme.raised)
                                .overlay {
                                    Image(systemName: "ellipsis")
                                        .foregroundStyle(TojTheme.tertiaryText)
                                }
                                .frame(width: 126, height: 104)
                                .accessibilityLabel("Album item unavailable")
                        }
                    }
                }
            } else {
                VStack(spacing: 2) {
                    ForEach(0..<slotCount, id: \.self) { index in
                        if let item = linesBySlot[index], let media = item.media {
                            HStack(spacing: 10) {
                                Image(systemName: "doc.fill")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(TojTheme.gold)
                                    .frame(width: 36, height: 36)
                                    .background(TojTheme.raised, in: Circle())
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(media.displayName)
                                        .font(.subheadline.weight(.semibold))
                                        .lineLimit(1)
                                    Text(media.formattedSize)
                                        .font(.caption)
                                        .foregroundStyle(TojTheme.secondaryText)
                                }
                                Spacer(minLength: 6)
                            }
                            .padding(.horizontal, 7)
                            .padding(.vertical, 5)
                        } else {
                            HStack {
                                ProgressView().controlSize(.small)
                                Text("Waiting for album item")
                                    .font(.caption)
                                    .foregroundStyle(TojTheme.secondaryText)
                                Spacer()
                            }
                            .padding(8)
                        }
                    }
                }
                .frame(width: 252)
            }
        }
        .overlay {
            if lines.contains(where: {
                if case .failed = $0.delivery { return true }
                return false
            }) {
                HStack(spacing: 8) {
                    Button("Retry", action: onRetry)
                    Button("Remove", role: .destructive, action: onRemove)
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.bordered)
                .padding(8)
                .background(.ultraThinMaterial, in: Capsule())
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Media group, \(lines.count) of \(slotCount) items")
    }
}

private struct AlbumVisualCell: View {
    let model: CloudAppModel
    let line: CloudAppModel.Line
    let media: CloudMedia
    @State private var thumbnail: UIImage?

    var body: some View {
        ZStack {
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
            } else {
                LinearGradient(
                    colors: [Color(hex: 0x27333A), Color(hex: 0x101C22)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                ProgressView().tint(TojTheme.text)
            }
            if media.kind == "video" {
                Image(systemName: "play.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(.black.opacity(0.45), in: Circle())
            }
            if line.delivery == .sending {
                ProgressView()
                    .tint(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.black.opacity(0.2))
            }
        }
        .frame(width: 126, height: 104)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .task(id: media.id) {
            thumbnail = await model.presentationImage(for: media, variant: .bubble720)
        }
        .accessibilityLabel("\(media.displayName), album item \(line.mediaGroupIndex.map { $0 + 1 } ?? 1)")
    }
}

/// Pure photo/video bubble composition — the Telegram-style thumbnail with its overlays.
/// Kept free of the model (network/store) so it renders from plain state and is previewable.
private struct MediaBubbleContent: View {
    let media: CloudMedia
    let line: CloudAppModel.Line
    let thumbnail: UIImage?
    let onRetry: () -> Void
    let onRemove: () -> Void
    var videoOverlay: AnyView = AnyView(EmptyView())
    var isAutoplaying: Bool = false

    private var mediaSize: CGSize {
        MediaBubbleLayout.size(width: media.width, height: media.height)
    }

    var body: some View {
        mediaThumbnail
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                // The muted looping preview sits above the still thumbnail, below the badges.
                videoOverlay.clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .overlay {
                if isTransferring {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(.black.opacity(0.22))
                }
            }
            .overlay(alignment: .topLeading) { topLeadingBadge }
            .overlay { centerControl }
            .overlay(alignment: .bottomTrailing) {
                if line.text.isEmpty, !isFailed { metaBadge }
            }
            .accessibilityLabel("\(media.displayName), \(media.formattedSize)")
    }

    @ViewBuilder private var mediaThumbnail: some View {
        if let thumbnail {
            Image(uiImage: thumbnail)
                .resizable()
                .scaledToFill()
                .frame(width: mediaSize.width, height: mediaSize.height)
                .clipped()
        } else {
            ZStack {
                LinearGradient(
                    colors: [Color(hex: 0x27333A), Color(hex: 0x101C22)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                // While uploading, the center ring already communicates activity — no extra spinner.
                if !isTransferring { ProgressView().tint(TojTheme.text) }
            }
            .frame(width: mediaSize.width, height: mediaSize.height)
        }
    }

    /// Center overlay: cancellable progress ring while uploading, retry card on failure,
    /// a play affordance on a finished video, and nothing on a finished photo.
    @ViewBuilder private var centerControl: some View {
        if isFailed {
            failedOverlay
        } else if isTransferring {
            Button(action: onRemove) {
                UploadProgressRing(progress: line.transferProgress ?? 0, indeterminate: isIndeterminate)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel upload")
        } else if media.kind == "video", !isAutoplaying {
            // A sent video shows a play affordance until it begins autoplaying muted inline.
            Image(systemName: "play.fill")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(.black.opacity(0.4), in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.2), lineWidth: 0.5))
                .accessibilityHidden(true)
        }
    }

    /// Top-left pill: live "uploaded / total" bytes while a video uploads, or its duration once sent.
    @ViewBuilder private var topLeadingBadge: some View {
        if isTransferring, media.kind == "video", let text = uploadByteText {
            metaPill { Text(text) }.padding(8)
        } else if !isTransferring, !isFailed, media.kind == "video", let duration = media.formattedDuration {
            metaPill {
                HStack(spacing: 3) {
                    // The mute glyph appears only while the clip is genuinely autoplaying muted.
                    if isAutoplaying { Image(systemName: "speaker.slash.fill").font(.system(size: 9, weight: .bold)) }
                    Text(duration)
                }
            }
            .padding(8)
        }
    }

    /// Bottom-right pill: timestamp + delivery marker (clock while sending, checks once sent).
    private var metaBadge: some View {
        metaPill {
            HStack(spacing: 3) {
                if line.isEdited { Text("edited") }
                if let timestamp = line.presentationTimestampLabel { Text(timestamp) }
                if line.mine { DeliveryTicks(delivery: line.delivery) }
            }
        }
        .padding(8)
    }

    private func metaPill<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        content()
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(.black.opacity(0.5), in: Capsule())
    }

    private var failedOverlay: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill").font(.title2)
            if case let .failed(message) = line.delivery {
                Text(message).font(.caption).lineLimit(2).multilineTextAlignment(.center)
            }
            HStack(spacing: 8) {
                Button("Retry", action: onRetry).buttonStyle(.borderedProminent)
                Button("Remove", role: .destructive, action: onRemove).buttonStyle(.bordered)
            }
        }
        .foregroundStyle(.white)
        .padding(12)
        .background(.black.opacity(0.74), in: RoundedRectangle(cornerRadius: 14))
        .padding(14)
    }

    private var isFailed: Bool {
        if case .failed = line.delivery { return true }
        return false
    }

    private var isTransferring: Bool {
        line.transferProgress != nil && !isFailed
    }

    private var isIndeterminate: Bool {
        line.transferStage == .preparing || line.transferStage == .finalizing
    }

    private var uploadByteText: String? {
        guard media.byteSize > 0, let progress = line.transferProgress, progress > 0 else { return nil }
        let total = media.byteSize
        let uploaded = min(total, Int64((Double(total) * progress).rounded()))
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return "\(formatter.string(fromByteCount: uploaded)) / \(formatter.string(fromByteCount: total))"
    }
}

/// Telegram-style upload indicator: a thin white ring that fills clockwise with progress (or
/// spins while preparing/finalizing), wrapping a white ✕ so a tap cancels the transfer.
private struct UploadProgressRing: View {
    let progress: Double
    let indeterminate: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var rotating = false

    var body: some View {
        ZStack {
            Circle().fill(.black.opacity(0.55)).frame(width: 54, height: 54)
            Circle().stroke(.white.opacity(0.25), lineWidth: 2.5).frame(width: 42, height: 42)
            if indeterminate, !reduceMotion {
                Circle()
                    .trim(from: 0, to: 0.28)
                    .stroke(.white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .frame(width: 42, height: 42)
                    .rotationEffect(.degrees(rotating ? 360 : 0))
                    .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: rotating)
                    .onAppear { rotating = true }
            } else {
                Circle()
                    .trim(from: 0, to: max(0.03, min(1, progress)))
                    .stroke(.white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .frame(width: 42, height: 42)
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.2), value: progress)
            }
            Image(systemName: "xmark")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: 54, height: 54)
        .accessibilityValue("\(Int((progress * 100).rounded())) percent")
    }
}

private struct VoiceNotePlaybackView: View {
    let model: CloudAppModel
    let media: CloudMedia
    @State private var player: AVAudioPlayer?
    @State private var isPlaying = false
    @State private var isLoading = false
    @State private var progress = 0.0
    @State private var downloadProgress = 0.0
    @State private var error: String?
    @State private var loadingTask: Task<Void, Never>?
    @State private var playbackTask: Task<Void, Never>?
    @State private var playbackRate: Float = 1

    var body: some View {
        HStack(spacing: 10) {
            Button(action: toggle) {
                Group {
                    if isLoading { ProgressView(value: downloadProgress).tint(TojTheme.canvas) }
                    else if error != nil { Image(systemName: "arrow.clockwise") }
                    else { Image(systemName: isPlaying ? "pause.fill" : "play.fill") }
                }
                .frame(width: 38, height: 38)
                .background(TojTheme.text, in: Circle())
                .foregroundStyle(TojTheme.canvas)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 2) {
                    ForEach(0..<24, id: \.self) { index in
                        Capsule()
                            .fill(Double(index) / 24 <= progress ? TojTheme.secure : TojTheme.secondaryText.opacity(0.42))
                            .frame(width: 3, height: CGFloat(7 + (index * 7 % 15)))
                    }
                }
                .frame(width: 135, height: 22)
                .overlay {
                    Slider(
                        value: Binding(
                            get: { progress },
                            set: { value in
                                progress = value
                                if let player { player.currentTime = player.duration * value }
                            }
                        ), in: 0...1
                    )
                    .tint(.clear)
                    .opacity(0.02)
                }
                .accessibilityLabel("Voice message position")
                HStack {
                    Text(error ?? elapsedLabel)
                        .lineLimit(1)
                    Spacer()
                    Text(media.formattedDuration ?? "0:00")
                    Button(rateLabel) { cyclePlaybackRate() }
                        .font(.caption2.bold())
                        .buttonStyle(.plain)
                        .foregroundStyle(TojTheme.secure)
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(TojTheme.secondaryText)
            }
        }
        .onDisappear {
            loadingTask?.cancel()
            playbackTask?.cancel()
            player?.stop()
        }
    }

    private var elapsedLabel: String {
        let elapsed = Int((player?.duration ?? 0) * progress)
        return String(format: "%d:%02d", elapsed / 60, elapsed % 60)
    }

    private func toggle() {
        if let player {
            if player.isPlaying {
                player.pause()
                isPlaying = false
            } else {
                player.play()
                isPlaying = true
                monitorPlayback()
            }
            return
        }
        error = nil
        isLoading = true
        downloadProgress = 0
        loadingTask?.cancel()
        loadingTask = Task {
            defer { loadingTask = nil }
            do {
                let data = try await model.mediaData(for: media) { value in
                    await MainActor.run { downloadProgress = value }
                }
                try Task.checkCancellation()
                let loaded = try AVAudioPlayer(data: data)
                loaded.enableRate = true
                loaded.rate = playbackRate
                guard loaded.prepareToPlay() else { throw MediaPresentationError.unreadable }
                player = loaded
                isLoading = false
                loaded.play()
                isPlaying = true
                monitorPlayback()
            } catch is CancellationError {
                isLoading = false
            } catch {
                isLoading = false
                self.error = error.localizedDescription
            }
        }
    }

    private func monitorPlayback() {
        playbackTask?.cancel()
        playbackTask = Task {
            while !Task.isCancelled, let player, player.isPlaying {
                progress = player.duration > 0 ? player.currentTime / player.duration : 0
                try? await Task.sleep(for: .milliseconds(100))
            }
            if player?.isPlaying == false, progress > 0.99 { progress = 0; player?.currentTime = 0 }
            isPlaying = false
        }
    }

    private var rateLabel: String {
        playbackRate == 1 ? "1×" : playbackRate == 1.5 ? "1.5×" : "2×"
    }

    private func cyclePlaybackRate() {
        playbackRate = playbackRate == 1 ? 1.5 : playbackRate == 1.5 ? 2 : 1
        player?.enableRate = true
        player?.rate = playbackRate
    }
}

private struct ZoomablePhotoView: View {
    let image: UIImage
    var onSingleTap: () -> Void = {}
    @State private var scale: CGFloat = 1
    @State private var baseScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var baseOffset: CGSize = .zero

    var body: some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .scaleEffect(scale)
            .offset(offset)
            .contentShape(Rectangle())
            .gesture(
                MagnifyGesture()
                    .onChanged { value in scale = min(5, max(1, baseScale * value.magnification)) }
                    .onEnded { _ in
                        baseScale = scale
                        if scale == 1 { offset = .zero; baseOffset = .zero }
                    }
            )
            .simultaneousGesture(
                DragGesture()
                    .onChanged { value in
                        guard scale > 1 else { return }
                        offset = CGSize(
                            width: baseOffset.width + value.translation.width,
                            height: baseOffset.height + value.translation.height
                        )
                    }
                    .onEnded { _ in baseOffset = offset }
            )
            .onTapGesture(count: 2) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    scale = scale > 1 ? 1 : 2.5
                    baseScale = scale
                    if scale == 1 { offset = .zero; baseOffset = .zero }
                }
            }
            .onTapGesture(count: 1) { onSingleTap() }
            .accessibilityLabel("Photo")
            .accessibilityHint("Pinch or double tap to zoom")
    }
}

/// Renders an `AVPlayer` through a bare `AVPlayerLayer` so the fullscreen viewer can lay its own
/// Liquid Glass controls over the video instead of the default `VideoPlayer` chrome.
private struct VideoLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerLayerUIView {
        let view = PlayerLayerUIView()
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ uiView: PlayerLayerUIView, context: Context) {
        if uiView.playerLayer.player !== player { uiView.playerLayer.player = player }
    }
}

private final class PlayerLayerUIView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        playerLayer.videoGravity = .resizeAspect
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private struct ProductionMediaViewer: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let model: CloudAppModel
    let media: CloudMedia
    let line: CloudAppModel.Line
    let title: String
    let subtitle: String
    let onReply: () -> Void

    @State private var photoImage: UIImage?
    @State private var thumbnailImage: UIImage?
    @State private var player: AVPlayer?
    @State private var temporaryURL: URL?
    @State private var error: String?
    @State private var downloadProgress = 0.0
    @State private var saveMessage: String?
    @State private var chromeVisible = true
    @State private var confirmingDelete = false
    // Video playback (custom controls — no native chrome so we can overlay Liquid Glass).
    @State private var duration = 0.0
    @State private var isPlaying = false
    @State private var isScrubbing = false
    @State private var scrubTime = 0.0
    // Bumped when an async seek lands so a paused scrubber re-reads the playhead.
    @State private var seekGeneration = 0
    @State private var streamingOwner: StreamingMediaAsset?  // retains the resource-loader delegate
    @State private var shareFetchTask: Task<Void, Never>?

    private var isVideoReady: Bool { media.kind == "video" && player != nil && error == nil }
    private var canReply: Bool { model.actions(for: line).contains(.reply) }
    private var canDelete: Bool { model.actions(for: line).contains(.delete) }
    private var isSaveable: Bool { (media.kind == "photo" || media.kind == "video") && temporaryURL != nil }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            contentLayer
            chromeLayer
                .opacity(chromeVisible ? 1 : 0)
                .allowsHitTesting(chromeVisible)
                .animation(
                    reduceMotion ? .easeOut(duration: 0.1) : .easeInOut(duration: 0.22),
                    value: chromeVisible
                )
        }
        .preferredColorScheme(.dark)
        .accessibilityIdentifier("media-viewer-\(media.id)")
        .task(id: media.id) { await load() }
        .onReceive(playStatePublisher) { status in
            isPlaying = status == .playing
        }
        .onReceive(NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification)) { note in
            guard let item = note.object as? AVPlayerItem, item === player?.currentItem else { return }
            isPlaying = false
            chromeVisible = true
        }
        .onDisappear { teardown() }
        .confirmationDialog(
            "Delete this message?", isPresented: $confirmingDelete, titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task { await model.deleteMessage(line); dismiss() }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Media", isPresented: Binding(
            get: { saveMessage != nil }, set: { if !$0 { saveMessage = nil } }
        )) {
            Button("OK") { saveMessage = nil }
        } message: { Text(saveMessage ?? "") }
    }

    /// Live playhead straight from the player — read per frame by the scrubber, never polled into state.
    private var liveTime: Double {
        guard let player else { return 0 }
        let seconds = player.currentTime().seconds
        guard seconds.isFinite else { return 0 }
        return min(duration, max(0, seconds))
    }

    private var playStatePublisher: AnyPublisher<AVPlayer.TimeControlStatus, Never> {
        player?.publisher(for: \.timeControlStatus).receive(on: DispatchQueue.main).eraseToAnyPublisher()
            ?? Empty().eraseToAnyPublisher()
    }

    // MARK: Content

    @ViewBuilder private var contentLayer: some View {
        if let error {
            VStack(spacing: 16) {
                ContentUnavailableView(
                    "Could not open media", systemImage: "exclamationmark.triangle",
                    description: Text(error)
                )
                Button("Try again") { Task { await load() } }
                    .buttonStyle(.borderedProminent)
            }
        } else if media.kind == "photo", photoImage != nil || thumbnailImage != nil {
            // Telegram order: the cached thumbnail fills the screen instantly; the full-resolution
            // image cross-fades over it when ready; a ring shows only while pixels are in flight.
            ZStack {
                if let photoImage {
                    ZoomablePhotoView(image: photoImage, onSingleTap: toggleChrome)
                        .transition(.opacity)
                } else if let thumbnailImage {
                    Image(uiImage: thumbnailImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .onTapGesture { toggleChrome() }
                        .transition(.opacity)
                }
            }
            .ignoresSafeArea()
            .overlay {
                if photoImage == nil {
                    MediaDownloadRing(progress: downloadProgress)
                }
            }
        } else if media.kind == "video", let player {
            VideoLayerView(player: player)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { toggleChrome() }
        } else if media.kind == "file", temporaryURL != nil {
            VStack(spacing: 20) {
                Image(systemName: "doc.fill").font(.system(size: 58)).foregroundStyle(TojTheme.secondaryText)
                Text(media.displayName).font(.headline)
                Text(media.formattedSize).foregroundStyle(TojTheme.secondaryText)
            }
        } else {
            ZStack {
                if let thumbnailImage {
                    Image(uiImage: thumbnailImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                MediaDownloadRing(progress: downloadProgress)
            }
            .ignoresSafeArea()
        }
    }

    // MARK: Liquid Glass chrome

    private var chromeLayer: some View {
        VStack(spacing: 0) {
            topBar
            Spacer(minLength: 0)
            if isVideoReady {
                videoScrubber
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            }
            bottomBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 14)
        .overlay { if isVideoReady { centerPlayPause } }
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            Button { dismiss() } label: { viewerGlassIcon("chevron.left") }
                .buttonStyle(.tojPressable)
                .accessibilityLabel("Back")
            Spacer(minLength: 8)
            moreMenu
        }
        .overlay {
            // Telegram: the title capsule is a button — tapping it returns to the chat.
            Button { dismiss() } label: {
                VStack(spacing: 1) {
                    Text(title)
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
            .accessibilityLabel("\(title). Back to chat")
        }
    }

    private var moreMenu: some View {
        Menu {
            Button { dismiss() } label: { Label("Show in Chat", systemImage: "bubble.left.and.text.bubble.right") }
            if media.kind == "photo" || media.kind == "video" {
                Button { Task { await saveCurrentToPhotos() } } label: {
                    Label(media.kind == "video" ? "Save Video" : "Save Image", systemImage: "square.and.arrow.down")
                }
            }
            if canReply {
                Button { dismiss(); onReply() } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") }
            }
            if canDelete {
                Button(role: .destructive) { confirmingDelete = true } label: { Label("Delete", systemImage: "trash") }
            }
        } label: {
            viewerGlassIcon("ellipsis")
        }
        .buttonStyle(.tojPressable)
        .accessibilityLabel("More")
    }

    private var bottomBar: some View {
        HStack {
            if let temporaryURL, error == nil {
                ShareLink(item: temporaryURL) { viewerGlassIcon("arrowshape.turn.up.right") }
                    .buttonStyle(.tojPressable)
                    .accessibilityLabel("Share")
            } else {
                // Keep the slot so the bar stays symmetric while the shareable file is prepared.
                viewerGlassIcon("arrowshape.turn.up.right")
                    .opacity(0.45)
                    .accessibilityHidden(true)
            }
            Spacer()
            if canDelete {
                Button { confirmingDelete = true } label: { viewerGlassIcon("trash") }
                    .buttonStyle(.tojPressable)
                    .accessibilityLabel("Delete")
            } else {
                Color.clear.frame(width: 46, height: 46)
            }
        }
    }

    /// The one true viewer control: every top/bottom button renders through this so they are
    /// pixel-identical — 46 pt circle, 17 pt semibold glyph, interactive Liquid Glass.
    private func viewerGlassIcon(_ system: String) -> some View {
        TojGlassIconLabel(systemImage: system)
    }

    private var centerPlayPause: some View {
        Button(action: togglePlayback) {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(.white)
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                .frame(width: 78, height: 78)
                .contentShape(Circle())
                .tojGlass(in: Circle(), interactive: true)
                .overlay(Circle().stroke(TojTheme.gold.opacity(0.45), lineWidth: 0.8))
        }
        .buttonStyle(.tojPressable)
        .animation(.easeInOut(duration: 0.2), value: isPlaying)
        .accessibilityLabel(isPlaying ? "Pause" : "Play")
    }

    /// Telegram's scrubber strip: elapsed / bar / duration in one glass capsule. TimelineView
    /// re-reads the playhead every display frame, so the fill glides instead of stepping.
    private var videoScrubber: some View {
        TimelineView(.animation(minimumInterval: nil, paused: !isPlaying && !isScrubbing)) { _ in
            HStack(spacing: 12) {
                Text(timeLabel(isScrubbing ? scrubTime : liveTime))
                    .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(.white)
                MediaScrubberBar(
                    fraction: duration > 0 ? (isScrubbing ? scrubTime : liveTime) / duration : 0,
                    isScrubbing: isScrubbing,
                    onScrub: { fraction in
                        isScrubbing = true
                        scrubTime = fraction * max(0.1, duration)
                    },
                    onCommit: {
                        seek(to: scrubTime)
                        isScrubbing = false
                    }
                )
                Text(timeLabel(duration))
                    .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            .tojGlass(in: Capsule())
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Video position")
    }

    // MARK: Behavior

    private func toggleChrome() {
        chromeVisible.toggle()
    }

    private func togglePlayback() {
        guard let player else { return }
        if player.timeControlStatus == .playing {
            player.pause()
            isPlaying = false
        } else {
            if liveTime >= duration - 0.1 { seek(to: 0) }
            player.play()
            isPlaying = true
        }
    }

    private func seek(to seconds: Double) {
        player?.seek(
            to: CMTime(seconds: seconds, preferredTimescale: 600),
            toleranceBefore: .zero, toleranceAfter: .zero
        ) { _ in
            Task { @MainActor in seekGeneration += 1 }
        }
    }

    private func timeLabel(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func saveCurrentToPhotos() async {
        guard let temporaryURL else {
            saveMessage = String(localized: "Still preparing this media…")
            return
        }
        await saveToPhotos(temporaryURL)
    }

    private func teardown() {
        player?.pause()
        player = nil
        streamingOwner = nil
        shareFetchTask?.cancel()
        if let temporaryURL { Task { await model.removeTemporaryMediaURL(temporaryURL) } }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func load() async {
        error = nil
        photoImage = nil
        thumbnailImage = nil
        player?.pause()
        player = nil
        streamingOwner = nil
        shareFetchTask?.cancel()
        if let temporaryURL { await model.removeTemporaryMediaURL(temporaryURL) }
        temporaryURL = nil
        downloadProgress = 0
        duration = 0
        isPlaying = false
        do {
            if media.kind == "video" {
                // The cached poster fills the frame while the stream spins up, so the viewer
                // never opens onto a bare ring.
                thumbnailImage = await model.presentationImage(for: media, variant: .videoPoster)
                try Task.checkCancellation()
                try await loadStreamingVideo()
                return
            }
            // The bubble's thumbnail is already cached — put it on screen immediately so the
            // viewer never opens onto a spinner, then fetch the full pixels behind it.
            if media.kind == "photo" {
                thumbnailImage = await model.presentationImage(for: media, variant: .bubble720)
                try Task.checkCancellation()
            }
            if media.kind == "photo" {
                let availability = await model.mediaAvailability(for: media, variant: .screen2048)
                try Task.checkCancellation()
                switch availability {
                case .decoded, .localRepresentation, .localComplete:
                    break
                default:
                    // Full pixels are not local yet: stream them with real progress so the ring
                    // is honest, then decode from the completed encrypted cache below.
                    _ = try await model.mediaData(for: media) { value in
                        await MainActor.run { downloadProgress = value }
                    }
                    try Task.checkCancellation()
                }
                let image = await model.presentationImage(for: media, variant: .screen2048)
                try Task.checkCancellation()
                guard let image else {
                    throw MediaPresentationError.unreadable
                }
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) {
                    photoImage = image
                }
                downloadProgress = 1
                shareFetchTask = Task { @MainActor in
                    guard let dialogId = line.dialogId,
                          let downloaded = try? await model.mediaData(for: media)
                    else { return }
                    _ = try? await model.transferTemporaryMediaURL(
                        data: downloaded,
                        fileExtension: preferredFileExtension,
                        mediaId: media.id,
                        dialogId: dialogId
                    ) { url in
                        guard !Task.isCancelled else { return false }
                        temporaryURL = url
                        return true
                    }
                }
                return
            }
            // Files need a local URL to preview and share.
            let downloaded = try await model.mediaData(for: media) { value in
                await MainActor.run { downloadProgress = value }
            }
            try Task.checkCancellation()
            guard let dialogId = line.dialogId else {
                throw MediaPresentationError.unreadable
            }
            let transferred = try await model.transferTemporaryMediaURL(
                data: downloaded,
                fileExtension: preferredFileExtension,
                mediaId: media.id,
                dialogId: dialogId
            ) { url in
                guard !Task.isCancelled else { return false }
                temporaryURL = url
                return true
            }
            if !transferred { throw CancellationError() }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Plays the video by streaming it through the resource loader — the first frame appears after the
    /// header + first chunk arrive instead of after a full download. Share/Save get the whole file in
    /// the background (reusing the streaming chunk cache).
    private func loadStreamingVideo() async throws {
        guard let owner = await model.streamingVideoAsset(for: media) else {
            throw MediaPresentationError.unreadable
        }
        let asset = owner.asset
        let playable = try await asset.load(.isPlayable)
        let assetDuration = try await asset.load(.duration).seconds
        guard playable, assetDuration.isFinite, assetDuration > 0, assetDuration <= 3_600,
              let track = try await asset.loadTracks(withMediaType: .video).first
        else { throw MediaPresentationError.unreadable }
        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let transformed = naturalSize.applying(transform)
        let width = Int64(abs(transformed.width).rounded(.up))
        let height = Int64(abs(transformed.height).rounded(.up))
        guard width > 0, height > 0, width <= 8_192, height <= 8_192,
              width * height <= 40_000_000
        else { throw MediaPresentationError.unreadable }
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
        streamingOwner = owner
        let newPlayer = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        duration = assetDuration
        player = newPlayer
        newPlayer.play()
        isPlaying = true
        shareFetchTask = Task { @MainActor in
            guard let dialogId = line.dialogId,
                  let data = try? await model.mediaData(for: media)
            else { return }
            _ = try? await model.transferTemporaryMediaURL(
                data: data,
                fileExtension: preferredFileExtension,
                mediaId: media.id,
                dialogId: dialogId
            ) { url in
                guard !Task.isCancelled else { return false }
                temporaryURL = url
                return true
            }
        }
    }

    private var preferredFileExtension: String {
        if let value = media.fileName.map({ URL(filePath: $0).pathExtension }), !value.isEmpty {
            return value
        }
        return UTType(mimeType: media.contentType)?.preferredFilenameExtension
            ?? (media.kind == "video" ? "mp4" : media.kind == "photo" ? "jpg" : "bin")
    }

    private func saveToPhotos(_ url: URL) async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            saveMessage = "Photos access is off. You can enable it in Settings."
            return
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                if media.kind == "video" {
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                } else {
                    PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url)
                }
            }
            saveMessage = "Saved to Photos"
        } catch {
            saveMessage = error.localizedDescription
        }
    }
}

/// Telegram's scrubber line: a thin white capsule that fills continuously, no knob; it thickens
/// slightly under the finger and the whole track is draggable to seek.
private struct MediaScrubberBar: View {
    let fraction: Double
    let isScrubbing: Bool
    let onScrub: (Double) -> Void
    let onCommit: () -> Void

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.3))
                Capsule().fill(.white)
                    .frame(width: max(0, min(1, fraction)) * width)
            }
            .frame(height: isScrubbing ? 7 : 4)
            .frame(maxHeight: .infinity, alignment: .center)
            .animation(.easeInOut(duration: 0.15), value: isScrubbing)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard width > 0 else { return }
                        onScrub(min(1, max(0, value.location.x / width)))
                    }
                    .onEnded { _ in onCommit() }
            )
        }
        .frame(height: 30)
    }
}

/// Telegram's download indicator: a thin white ring over the media that fills with progress,
/// spinning while the transfer has not reported bytes yet.
private struct MediaDownloadRing: View {
    let progress: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var rotating = false

    var body: some View {
        ZStack {
            Circle().fill(.black.opacity(0.45)).frame(width: 54, height: 54)
            Circle().stroke(.white.opacity(0.25), lineWidth: 2.5).frame(width: 42, height: 42)
            if progress <= 0.01, !reduceMotion {
                Circle()
                    .trim(from: 0, to: 0.28)
                    .stroke(.white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .frame(width: 42, height: 42)
                    .rotationEffect(.degrees(rotating ? 360 : 0))
                    .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: rotating)
                    .onAppear { rotating = true }
            } else {
                Circle()
                    .trim(from: 0, to: max(0.03, min(1, progress)))
                    .stroke(.white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .frame(width: 42, height: 42)
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.2), value: progress)
            }
        }
        .accessibilityLabel("Downloading")
        .accessibilityValue("\(Int((progress * 100).rounded())) percent")
    }
}

private enum MediaPresentationError: LocalizedError {
    case unreadable
    var errorDescription: String? { String(localized: "The downloaded media is damaged or unsupported") }
}

private extension ComposerMode {
    var isRecording: Bool {
        if case .recording = self { return true }
        return false
    }

    var isEditing: Bool {
        if case .editing = self { return true }
        return false
    }

    var contextIcon: String {
        switch self {
        case .replying: "arrowshape.turn.up.left"
        case .editing: "pencil"
        case .recording: "waveform"
        case .attachmentPreview, .uploading: "paperclip"
        case .disabled: "exclamationmark.triangle"
        case .text: "text.cursor"
        }
    }

    var contextTitle: String {
        switch self {
        case .replying: String(localized: "Replying")
        case .editing: String(localized: "Editing message")
        case .recording: String(localized: "Recording voice message")
        case .attachmentPreview: String(localized: "Attachment preview")
        case .uploading: String(localized: "Uploading")
        case .disabled: String(localized: "Messaging unavailable")
        case .text: ""
        }
    }

    var contextPreview: String {
        switch self {
        case let .replying(_, preview): preview
        case let .editing(_, original): original
        case let .recording(seconds): String(format: "%d:%02d · Slide left to cancel · up to lock", seconds / 60, seconds % 60)
        case let .attachmentPreview(attachment): attachment.title
        case let .uploading(attachment, progress): "\(attachment.title) · \(Int(progress * 100))%"
        case let .disabled(reason): reason
        case .text: ""
        }
    }
}

private struct ScheduleMessageSheet: View {
    let isReminder: Bool
    let completion: (Date) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var date = Date().addingTimeInterval(60 * 60)

    private var range: ClosedRange<Date> {
        let minimum = Date().addingTimeInterval(60)
        let maximum = Calendar.current.date(byAdding: .year, value: 1, to: minimum)
            ?? minimum.addingTimeInterval(365 * 24 * 60 * 60)
        return minimum...maximum
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Image(systemName: isReminder ? "bell.badge.fill" : "calendar.badge.clock")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(TojTheme.accent)
                    .frame(width: 66, height: 66)
                    .background(TojTheme.raised, in: Circle())

                DatePicker(
                    isReminder ? "Remind me" : "Send on",
                    selection: $date,
                    in: range,
                    displayedComponents: [.date, .hourAndMinute]
                )
                .datePickerStyle(.compact)
                .tint(TojTheme.accent)

                Button {
                    completion(max(date, range.lowerBound))
                } label: {
                    Text(isReminder ? "Set Reminder" : "Schedule Message")
                        .font(.headline)
                        .foregroundStyle(TojTheme.onAccent)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(TojTheme.accent, in: Capsule())
                }
                .buttonStyle(.tojPressable)

                Text("The message stays in the encrypted outbox and sends when its time arrives. It will retry automatically if the network is unavailable.")
                    .font(.footnote)
                    .foregroundStyle(TojTheme.secondaryText)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(TojTheme.canvas)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

nonisolated private enum ScheduledReminderCenter {
    static func schedule(at date: Date, fallbackBody: String) async {
        guard date > Date() else { return }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional else { return }

        let content = UNMutableNotificationContent()
        content.title = String(localized: "Toj Reminder")
        // Avoid copying private message text onto the lock screen. The original remains in the
        // encrypted Saved Messages timeline; the notification opens Toj to read it.
        content.body = fallbackBody.isEmpty
            ? String(localized: "Open Saved Messages to view your reminder.")
            : String(localized: "You have a reminder in Saved Messages.")
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: max(1, date.timeIntervalSinceNow),
            repeats: false
        )
        try? await center.add(UNNotificationRequest(
            identifier: "toj.reminder.\(UUID().uuidString.lowercased())",
            content: content,
            trigger: trigger
        ))
    }
}

private struct ProductionAttachmentPicker: View {
    let model: CloudAppModel
    let onDone: () -> Void
    let onSent: () -> Void
    @StateObject private var library = RecentMediaLibrary()
    @State private var mediaItems: [PhotosPickerItem] = []
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var videoItems: [PhotosPickerItem] = []
    @State private var selectedAsset: PHAsset?
    @State private var selectedFile: PreparedFileSelection?
    @State private var importingFile = false
    @State private var showingCamera = false
    @State private var showingContactPicker = false
    @State private var locationProvider = OneShotLocationProvider()
    @State private var working = false
    @State private var error: String?

    private var maximumSelectionCount: Int {
        guard model.capabilities.contains(.mediaGroups) else { return 1 }
        return max(1, 10 - (model.currentDraft?.attachments.count ?? 0))
    }
    @State private var selectionTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            attachmentHeader
            mediaContent
            attachmentControls
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TojTheme.base)
        .task { await library.load() }
        .onChange(of: mediaItems) { _, items in
            guard !items.isEmpty else { return }
            selectedFile = nil
            selectionTask?.cancel()
            selectionTask = Task { await loadMediaItems(items) }
        }
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            selectedFile = nil
            selectionTask?.cancel()
            selectionTask = Task { await loadMediaItems(items) }
        }
        .onChange(of: videoItems) { _, items in
            guard !items.isEmpty else { return }
            selectedFile = nil
            selectionTask?.cancel()
            selectionTask = Task { await loadMediaItems(items) }
        }
        .fileImporter(isPresented: $importingFile, allowedContentTypes: [.data, .item]) { result in
            selectionTask?.cancel()
            selectionTask = Task { await loadFile(result) }
        }
        .fullScreenCover(isPresented: $showingCamera) {
            CameraCapturePicker { result in
                showingCamera = false
                guard let result else { return }
                selectionTask?.cancel()
                selectionTask = Task { await loadCapture(result) }
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showingContactPicker) {
            ContactAttachmentPicker { selection in
                showingContactPicker = false
                guard let selection else { return }
                selectedAsset = nil
                selectedFile = selection
                error = nil
                TojFeedback.selection()
            }
        }
        .onDisappear {
            selectionTask?.cancel()
            if working { model.cancelComposerMode() }
        }
    }

    private var attachmentHeader: some View {
        ZStack {
            Capsule()
                .fill(Color.white.opacity(0.18))
                .frame(width: 42, height: 5)
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.top, 8)

            HStack {
                Button(action: onDone) {
                    Image(systemName: "xmark")
                        .font(.system(size: 19, weight: .semibold))
                        .frame(width: 48, height: 48)
                        .background(TojTheme.strong, in: Circle())
                        .overlay(Circle().stroke(TojTheme.hairlineStrong, lineWidth: 0.5))
                }
                .buttonStyle(.tojPressable)
                .foregroundStyle(TojTheme.text)
                .accessibilityLabel("Close attachments")

                Spacer()
                if selectedFile != nil {
                    AttachmentFileTitle()
                } else {
                    PhotosPicker(
                        selection: $mediaItems,
                        maxSelectionCount: maximumSelectionCount,
                        selectionBehavior: .ordered,
                        matching: .any(of: [.images, .videos])
                    ) {
                        AttachmentLibraryTitle()
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Browse photo and video library")
                }
                Spacer()
                Color.clear.frame(width: 48, height: 48)
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
        }
        .frame(height: 82)
    }

    @ViewBuilder
    private var mediaContent: some View {
        if let selectedFile {
            SelectedFilePreview(
                file: selectedFile,
                onReplace: { importingFile = true },
                onRemove: {
                    self.selectedFile = nil
                    error = nil
                    TojFeedback.selection()
                }
            )
        } else {
            switch library.authorizationStatus {
        case .authorized, .limited:
            if library.assets.isEmpty {
                attachmentEmptyState(
                    title: "No recent media",
                    detail: "Choose a photo or video from the library, or send a file.",
                    icon: "photo.on.rectangle.angled"
                )
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 3),
                        spacing: 2
                    ) {
                        ForEach(library.assets, id: \.localIdentifier) { asset in
                            RecentMediaTile(
                                asset: asset,
                                selected: selectedAsset?.localIdentifier == asset.localIdentifier,
                                disabled: working
                            ) {
                                guard !working else { return }
                                selectedAsset = selectedAsset?.localIdentifier == asset.localIdentifier ? nil : asset
                                error = nil
                                TojFeedback.selection()
                            }
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        case .denied, .restricted:
            photoPrivacyState
        case .notDetermined:
            VStack(spacing: 12) {
                ProgressView().tint(TojTheme.gold)
                Text("Loading recent media…")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(TojTheme.secondaryText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            @unknown default:
                attachmentEmptyState(
                    title: "Choose something to send",
                    detail: "Photos, videos, and files are available below.",
                    icon: "paperclip"
                )
            }
        }
    }

    private func attachmentEmptyState(
        title: LocalizedStringKey,
        detail: LocalizedStringKey,
        icon: String
    ) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(TojTheme.gold)
                .frame(width: 62, height: 62)
                .background(TojTheme.strong, in: Circle())
            Text(title)
                .font(TojTheme.heading(.headline, weight: .bold))
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(TojTheme.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 290)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var photoPrivacyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(TojTheme.gold)
                .frame(width: 62, height: 62)
                .background(TojTheme.strong, in: Circle())
            Text("Recent media is private")
                .font(TojTheme.heading(.headline, weight: .bold))
            Text("Use Photo below, or allow access to show previews here.")
                .font(.subheadline)
                .foregroundStyle(TojTheme.secondaryText)
                .multilineTextAlignment(.center)
            Button("Open Settings") {
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                UIApplication.shared.open(url)
            }
            .buttonStyle(.bordered)
            .tint(TojTheme.gold)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var attachmentControls: some View {
        VStack(spacing: 10) {
            if working {
                HStack(spacing: 12) {
                    ProgressView().tint(TojTheme.gold)
                    Text("Loading attachment…")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Button("Cancel", role: .cancel) { cancelSelection() }
                        .font(.subheadline.weight(.semibold))
                }
                .padding(.horizontal, 16)
                .frame(height: 48)
                .background(TojTheme.raised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .padding(.horizontal, 12)
            } else if let selectedFile {
                Button {
                    sendFile(selectedFile)
                } label: {
                    Label("Add file", systemImage: "plus")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(TojTheme.onAccent)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(TojTheme.accent, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.tojPressable)
                .padding(.horizontal, 12)
            } else if selectedAsset != nil {
                Button {
                    guard let selectedAsset else { return }
                    selectionTask?.cancel()
                    selectionTask = Task {
                        if selectedAsset.mediaType == .video {
                            await loadVideo(selectedAsset)
                        } else {
                            await loadPhoto(selectedAsset)
                        }
                    }
                } label: {
                    Label(
                        selectedAsset?.mediaType == .video ? "Add video" : "Add photo",
                        systemImage: "plus"
                    )
                        .font(.headline.weight(.bold))
                        .foregroundStyle(TojTheme.onAccent)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(TojTheme.accent, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.tojPressable)
                .padding(.horizontal, 12)
            }

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 16)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 3) {
                Button { showingCamera = true } label: {
                    AttachmentActionLabel(title: "Camera", icon: "camera.fill")
                }
                .buttonStyle(.tojPressable)
                .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))

                Button {
                    selectedAsset = nil
                    selectedFile = nil
                    Task { await library.load() }
                } label: {
                    AttachmentActionLabel(title: "Recents", icon: "photo.stack.fill", selected: true)
                }
                .buttonStyle(.tojPressable)

                PhotosPicker(
                    selection: $photoItems,
                    maxSelectionCount: maximumSelectionCount,
                    selectionBehavior: .ordered,
                    matching: .images
                ) {
                    AttachmentActionLabel(title: "Photo", icon: "photo.fill")
                }
                .buttonStyle(.tojPressable)

                PhotosPicker(
                    selection: $videoItems,
                    maxSelectionCount: maximumSelectionCount,
                    selectionBehavior: .ordered,
                    matching: .videos
                ) {
                    AttachmentActionLabel(title: "Video", icon: "video.fill")
                }
                .buttonStyle(.tojPressable)

                Button { importingFile = true } label: {
                    AttachmentActionLabel(title: "File", icon: "doc.fill", selected: selectedFile != nil)
                }
                .buttonStyle(.tojPressable)

                Button { showingContactPicker = true } label: {
                    AttachmentActionLabel(title: "Contact", icon: "person.crop.circle.fill")
                }
                .buttonStyle(.tojPressable)

                Button {
                    selectionTask?.cancel()
                    selectionTask = Task { await addCurrentLocation() }
                } label: {
                    AttachmentActionLabel(title: "Location", icon: "location.fill")
                }
                .buttonStyle(.tojPressable)
                }
            }
            .disabled(working)
            .padding(8)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .stroke(TojTheme.hairlineStrong, lineWidth: 0.5)
            )
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
        }
        .padding(.top, 8)
        .background(TojTheme.base.opacity(0.96))
    }

    private func loadMedia(_ item: PhotosPickerItem) async {
        if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
            await loadVideo(item)
        } else {
            await loadPhoto(item)
        }
    }

    /// Imports in picker order and releases each source buffer before requesting the next item, so
    /// a 10-item selection never retains all PhotosPicker payloads at once.
    private func loadMediaItems(_ items: [PhotosPickerItem]) async {
        working = true
        defer {
            working = false
            mediaItems = []
            photoItems = []
            videoItems = []
        }
        do {
            for item in items {
                try Task.checkCancellation()
                guard let source = try await item.loadTransferable(type: Data.self) else {
                    throw PickerError.unreadable
                }
                if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
                    let fitted = try await MediaAssetDataLoader.fittedVideoData(source)
                    try await prepareAndStageVideo(fitted, finishSelection: false)
                } else {
                    try await prepareAndStagePhoto(source, finishSelection: false)
                }
            }
            selectionTask = nil
            onSent()
            onDone()
        } catch is CancellationError {
            return
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadPhoto(_ item: PhotosPickerItem) async {
        working = true
        defer { working = false }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw PickerError.unreadable
            }
            try Task.checkCancellation()
            try await prepareAndStagePhoto(data)
        } catch is CancellationError {
            return
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadCapture(_ capture: CameraCaptureResult) async {
        working = true
        defer { working = false }
        do {
            switch capture {
            case let .photo(data):
                try await prepareAndStagePhoto(data)
            case let .video(data):
                let fitted = try await MediaAssetDataLoader.fittedVideoData(data)
                try Task.checkCancellation()
                try await prepareAndStageVideo(fitted)
            }
        } catch is CancellationError {
            return
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func addCurrentLocation() async {
        working = true
        defer { working = false }
        do {
            let location = try await locationProvider.request()
            try Task.checkCancellation()
            let latitude = String(format: "%.6f", location.coordinate.latitude)
            let longitude = String(format: "%.6f", location.coordinate.longitude)
            let link = "https://maps.apple.com/?ll=\(latitude),\(longitude)"
            model.draft = model.draft.isEmpty
                ? "📍 \(String(localized: "Location"))\n\(link)"
                : model.draft + "\n\n📍 \(String(localized: "Location"))\n\(link)"
            onDone()
        } catch is CancellationError {
            return
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadPhoto(_ asset: PHAsset) async {
        working = true
        defer { working = false }
        do {
            let data = try await MediaAssetDataLoader.imageData(for: asset)
            try Task.checkCancellation()
            try await prepareAndStagePhoto(data)
        } catch is CancellationError {
            return
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func prepareAndStagePhoto(
        _ data: Data,
        finishSelection: Bool = true
    ) async throws {
        guard let prepared = await Task.detached(priority: .userInitiated, operation: {
            SafeMediaImageDecoder.preparePhotoUpload(data)
        }).value else { throw PickerError.unreadable }
        try Task.checkCancellation()
        try await model.stageDraftMedia(
            data: prepared.data,
            kind: "photo",
            contentType: prepared.contentType,
            fileName: "Photo.\(prepared.filenameExtension)",
            width: prepared.pixelWidth,
            height: prepared.pixelHeight,
            thumbnail: prepared.thumbnail
        )
        if finishSelection {
            working = false
            selectionTask = nil
            onSent()
            onDone()
        }
    }

    private func loadVideo(_ item: PhotosPickerItem) async {
        working = true
        defer { working = false }
        do {
            guard let source = try await item.loadTransferable(type: Data.self) else { throw PickerError.unreadable }
            try Task.checkCancellation()
            let data = try await MediaAssetDataLoader.fittedVideoData(source)
            try Task.checkCancellation()
            try await prepareAndStageVideo(data)
        } catch is CancellationError {
            return
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadVideo(_ asset: PHAsset) async {
        working = true
        defer { working = false }
        do {
            let data = try await MediaAssetDataLoader.videoData(for: asset)
            try Task.checkCancellation()
            try await prepareAndStageVideo(data)
        } catch is CancellationError {
            return
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func prepareAndStageVideo(
        _ data: Data,
        finishSelection: Bool = true
    ) async throws {
        guard data.count <= TojMediaLimits.maximumMessageBytesInt else { throw PickerError.tooLarge }
        guard let container = SafeMediaVideoInspector.container(for: data) else {
            throw PickerError.unsupportedVideo
        }
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "toj-video-\(UUID().uuidString)", directoryHint: .isDirectory)
        let url = directory.appending(path: "source.\(container.filenameExtension)")
        try await Task.detached(priority: .utility) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.complete],
                ofItemAtPath: directory.path
            )
            try data.write(to: url, options: [.atomic, .completeFileProtection])
        }.value
        defer {
            Task.detached(priority: .utility) {
                try? FileManager.default.removeItem(at: directory)
            }
        }

        let videoAsset = AVURLAsset(url: url)
        let duration = try await videoAsset.load(.duration)
        guard duration.seconds.isFinite, duration.seconds > 0 else { throw PickerError.unsupportedVideo }
        guard let track = try await videoAsset.loadTracks(withMediaType: .video).first else {
            throw PickerError.unsupportedVideo
        }
        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let size = naturalSize.applying(transform)
        let dimensions = (Int(abs(size.width)), Int(abs(size.height)))
        guard dimensions.0 > 0, dimensions.1 > 0 else { throw PickerError.unsupportedVideo }

        let generator = AVAssetImageGenerator(asset: videoAsset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        let image = try await generator.image(at: .zero).image
        let thumbnail = await Task.detached(priority: .userInitiated) {
            SafeMediaImageDecoder.thumbnailData(UIImage(cgImage: image))
        }.value
        try Task.checkCancellation()
        try await model.stageDraftMedia(
            data: data,
            kind: "video",
            contentType: container.contentType,
            fileName: "Video.\(container.filenameExtension)",
            durationMs: Int64(duration.seconds * 1_000),
            width: dimensions.0,
            height: dimensions.1,
            thumbnail: thumbnail
        )
        if finishSelection {
            working = false
            selectionTask = nil
            onSent()
            onDone()
        }
    }

    private func loadFile(_ result: Result<URL, Error>) async {
        working = true
        defer { working = false }
        do {
            let url = try result.get()
            let selection = try await Task.detached(priority: .userInitiated) {
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                let values = try url.resourceValues(forKeys: [
                    .contentTypeKey, .fileSizeKey, .isDirectoryKey, .isRegularFileKey,
                ])
                guard values.isDirectory != true else { throw PickerError.unreadable }
                if let fileSize = values.fileSize, fileSize > TojMediaLimits.maximumMessageBytesInt {
                    throw PickerError.tooLarge
                }
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                guard !data.isEmpty else { throw PickerError.emptyFile }
                guard data.count <= TojMediaLimits.maximumMessageBytesInt else { throw PickerError.tooLarge }
                guard let fileName = SafeMediaFileMetadata.sanitizedFileName(url.lastPathComponent) else {
                    throw PickerError.invalidFileName
                }
                return PreparedFileSelection(
                    data: data,
                    fileName: fileName,
                    contentType: values.contentType?.preferredMIMEType ?? "application/octet-stream"
                )
            }.value
            try Task.checkCancellation()
            selectedAsset = nil
            selectedFile = selection
            working = false
            selectionTask = nil
            error = nil
            TojFeedback.selection()
        } catch is CancellationError {
            return
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func sendFile(_ file: PreparedFileSelection) {
        selectedFile = nil
        selectionTask = nil
        Task {
            do {
                try await model.stageDraftMedia(
                    data: file.data,
                    kind: "file",
                    contentType: file.contentType,
                    fileName: file.fileName
                )
                onSent()
                onDone()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func cancelSelection() {
        selectionTask?.cancel()
        selectionTask = nil
        model.cancelComposerMode()
        working = false
        onDone()
    }
}

private struct AttachmentLibraryTitle: View {
    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 5) {
                Text("Recent media")
                    .font(TojTheme.heading(.headline, weight: .bold))
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(TojTheme.secondaryText)
            }
            Text("Encrypted before upload")
                .font(.caption2.weight(.medium))
                .foregroundStyle(TojTheme.secure)
        }
    }
}

private struct AttachmentFileTitle: View {
    var body: some View {
        VStack(spacing: 2) {
            Text("File ready")
                .font(TojTheme.heading(.headline, weight: .bold))
            Text("Encrypted before upload")
                .font(.caption2.weight(.medium))
                .foregroundStyle(TojTheme.secure)
        }
    }
}

nonisolated private struct PreparedFileSelection: Sendable {
    let data: Data
    let fileName: String
    let contentType: String

    var byteSize: Int64 { Int64(data.count) }
}

private struct SelectedFilePreview: View {
    let file: PreparedFileSelection
    let onReplace: () -> Void
    let onRemove: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [TojTheme.strong, TojTheme.raised],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 26, style: .continuous)
                            .stroke(TojTheme.gold.opacity(0.22), lineWidth: 1)
                    )
                Image(systemName: FileAttachmentPresentation.icon(for: file.contentType))
                    .font(.system(size: 48, weight: .medium))
                    .foregroundStyle(TojTheme.gold)
                Text(FileAttachmentPresentation.extensionLabel(file.fileName))
                    .font(.caption2.weight(.black))
                    .foregroundStyle(TojTheme.onAccent)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 5)
                    .background(TojTheme.gold, in: Capsule())
                    .padding(12)
            }
            .frame(width: 136, height: 136)

            VStack(spacing: 5) {
                Text(file.fileName)
                    .font(TojTheme.heading(.headline, weight: .bold))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                Text(ByteCountFormatter.string(fromByteCount: file.byteSize, countStyle: .file))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(TojTheme.secondaryText)
                Label("Ready for encrypted upload", systemImage: "cloud.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(TojTheme.secondaryText)
            }

            HStack(spacing: 10) {
                Button(action: onReplace) {
                    Label("Replace", systemImage: "arrow.triangle.2.circlepath")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(TojTheme.text)
                Button(role: .destructive, action: onRemove) {
                    Label("Remove", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: 340)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

nonisolated private enum FileAttachmentPresentation {
    static func icon(for contentType: String) -> String {
        if contentType == "application/pdf" { return "doc.richtext.fill" }
        if contentType.hasPrefix("image/") { return "photo.fill" }
        if contentType.hasPrefix("video/") { return "film.fill" }
        if contentType.hasPrefix("audio/") { return "waveform" }
        if contentType.hasPrefix("text/") { return "doc.text.fill" }
        if contentType.contains("zip") || contentType.contains("archive") || contentType.contains("compressed") {
            return "archivebox.fill"
        }
        return "doc.fill"
    }

    static func extensionLabel(_ fileName: String) -> String {
        let value = URL(fileURLWithPath: fileName).pathExtension
        return value.isEmpty ? "FILE" : String(value.prefix(5)).uppercased()
    }
}

private struct AttachmentActionLabel: View {
    nonisolated let title: String
    nonisolated let icon: String
    nonisolated let selected: Bool

    nonisolated init(title: String, icon: String, selected: Bool = false) {
        self.title = title
        self.icon = icon
        self.selected = selected
    }

    var body: some View {
        VStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .semibold))
                .frame(height: 24)
            Text(LocalizedStringKey(title))
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(selected ? TojTheme.gold : TojTheme.text)
        .frame(maxWidth: .infinity)
        .frame(height: 58)
        .background(
            selected ? TojTheme.gold.opacity(0.13) : Color.clear,
            in: RoundedRectangle(cornerRadius: 19, style: .continuous)
        )
    }
}

@MainActor
private final class RecentMediaLibrary: ObservableObject {
    @Published private(set) var authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @Published private(set) var assets: [PHAsset] = []

    func load() async {
        var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined {
            status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        authorizationStatus = status
        guard status == .authorized || status == .limited else {
            assets = []
            return
        }

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = 90
        let result = PHAsset.fetchAssets(with: options)
        var recent: [PHAsset] = []
        recent.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            if asset.mediaType == .image || asset.mediaType == .video {
                recent.append(asset)
            }
        }
        assets = recent
    }
}

private struct RecentMediaTile: View {
    let asset: PHAsset
    let selected: Bool
    let disabled: Bool
    let action: () -> Void
    @State private var image: UIImage?
    @State private var requestID = PHInvalidImageRequestID

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Rectangle()
                        .fill(TojTheme.strong)
                        .overlay(ProgressView().tint(TojTheme.secondaryText))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            ZStack {
                Circle()
                    .fill(selected ? TojTheme.gold : Color.black.opacity(0.28))
                Circle()
                    .stroke(selected ? TojTheme.gold : Color.white.opacity(0.88), lineWidth: 2)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.caption2.weight(.black))
                        .foregroundStyle(TojTheme.onAccent)
                }
            }
            .frame(width: 27, height: 27)
            .padding(8)

            if asset.mediaType == .video {
                HStack(spacing: 4) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 9, weight: .bold))
                    Text(Self.durationText(asset.duration))
                        .font(.caption2.weight(.bold).monospacedDigit())
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
                .background(Color.black.opacity(0.62), in: Capsule())
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(7)
            }

            if disabled {
                Color.black.opacity(0.24)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .overlay(
            Rectangle()
                .stroke(selected ? TojTheme.gold : Color.clear, lineWidth: 3)
        )
        .onAppear(perform: requestThumbnail)
        .onDisappear {
            if requestID != PHInvalidImageRequestID {
                PHImageManager.default().cancelImageRequest(requestID)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(asset.mediaType == .video ? "Recent video" : "Recent photo")
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private func requestThumbnail() {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        requestID = PHImageManager.default().requestImage(
            for: asset,
            targetSize: CGSize(width: 420, height: 420),
            contentMode: .aspectFill,
            options: options
        ) { result, info in
            guard let result, (info?[PHImageCancelledKey] as? Bool) != true else { return }
            image = result
        }
    }

    nonisolated private static func durationText(_ duration: TimeInterval) -> String {
        let total = max(0, Int(duration.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

nonisolated private enum MediaAssetDataLoader {
    private static let maxBytes = TojMediaLimits.maximumMessageBytesInt

    static func imageData(for asset: PHAsset) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.version = .current
            options.isNetworkAccessAllowed = true
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) {
                data, _, _, info in
                if (info?[PHImageCancelledKey] as? Bool) == true {
                    continuation.resume(throwing: CancellationError())
                } else if let error = info?[PHImageErrorKey] as? Error {
                    continuation.resume(throwing: error)
                } else if let data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: PickerError.unreadable)
                }
            }
        }
    }

    static func videoData(for asset: PHAsset) async throws -> Data {
        let source = try await videoAsset(for: asset).asset
        if let sourceURL = (source as? AVURLAsset)?.url,
           let size = await Task.detached(priority: .utility, operation: {
               try? sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
           }).value,
           size <= maxBytes {
            // Remux to faststart (moov atom at the front) so the video streams from the first chunk
            // instead of forcing a full download to locate the header. Lossless passthrough — no
            // re-encode. Fall back to the original bytes if passthrough isn't supported.
            if let faststart = try? await remuxFaststart(source), faststart.count <= maxBytes {
                return faststart
            }
            return try await Task.detached(priority: .userInitiated) {
                try Data(contentsOf: sourceURL, options: .mappedIfSafe)
            }.value
        }

        return try await exportForUpload(source)
    }

    private static func remuxFaststart(_ source: AVAsset) async throws -> Data {
        guard await AVAssetExportSession.compatibility(
            ofExportPreset: AVAssetExportPresetPassthrough, with: source, outputFileType: .mp4
        ) else { throw PickerError.unsupportedVideo }
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "toj-video-faststart-\(UUID().uuidString)", directoryHint: .isDirectory)
        try await Task.detached(priority: .utility) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.complete],
                ofItemAtPath: directory.path
            )
        }.value
        defer {
            Task.detached(priority: .utility) {
                try? FileManager.default.removeItem(at: directory)
            }
        }
        let outputURL = directory.appending(path: "faststart.mp4")
        guard let exporter = AVAssetExportSession(asset: source, presetName: AVAssetExportPresetPassthrough) else {
            throw PickerError.unsupportedVideo
        }
        exporter.shouldOptimizeForNetworkUse = true
        try await exporter.export(to: outputURL, as: .mp4)
        return try await Task.detached(priority: .userInitiated) {
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.complete],
                ofItemAtPath: outputURL.path
            )
            return try Data(contentsOf: outputURL, options: .mappedIfSafe)
        }.value
    }

    static func fittedVideoData(_ data: Data) async throws -> Data {
        guard data.count > maxBytes else { return data }
        guard let container = SafeMediaVideoInspector.container(for: data) else {
            throw PickerError.unsupportedVideo
        }
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "toj-video-source-\(UUID().uuidString)", directoryHint: .isDirectory)
        let sourceURL = directory.appending(path: "source.\(container.filenameExtension)")
        try await Task.detached(priority: .utility) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.complete],
                ofItemAtPath: directory.path
            )
            try data.write(to: sourceURL, options: [.atomic, .completeFileProtection])
        }.value
        defer {
            Task.detached(priority: .utility) {
                try? FileManager.default.removeItem(at: directory)
            }
        }
        return try await exportForUpload(AVURLAsset(url: sourceURL))
    }

    private static func exportForUpload(_ source: AVAsset) async throws -> Data {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "toj-video-export-\(UUID().uuidString)", directoryHint: .isDirectory)
        try await Task.detached(priority: .utility) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.complete],
                ofItemAtPath: directory.path
            )
        }.value
        defer {
            Task.detached(priority: .utility) {
                try? FileManager.default.removeItem(at: directory)
            }
        }
        let outputURL = directory.appending(path: "video.mp4")

        let duration = try await source.load(.duration)
        _ = try await source.load(.tracks)
        let preferredPreset = duration.seconds.isFinite && duration.seconds <= 60
            ? AVAssetExportPreset1280x720 : AVAssetExportPresetMediumQuality
        let preferredCompatible = await AVAssetExportSession.compatibility(
            ofExportPreset: preferredPreset, with: source, outputFileType: .mp4
        )
        let preset: String
        if preferredCompatible {
            preset = preferredPreset
        } else if await AVAssetExportSession.compatibility(
            ofExportPreset: AVAssetExportPresetMediumQuality, with: source, outputFileType: .mp4
        ) {
            preset = AVAssetExportPresetMediumQuality
        } else {
            throw PickerError.unsupportedVideo
        }
        guard let exporter = AVAssetExportSession(asset: source, presetName: preset) else {
            throw PickerError.unsupportedVideo
        }
        exporter.shouldOptimizeForNetworkUse = true
        try await exporter.export(to: outputURL, as: .mp4)
        let data = try await Task.detached(priority: .userInitiated) {
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.complete],
                ofItemAtPath: outputURL.path
            )
            return try Data(contentsOf: outputURL, options: .mappedIfSafe)
        }.value
        guard data.count <= maxBytes else { throw PickerError.tooLarge }
        return data
    }

    private static func videoAsset(for asset: PHAsset) async throws -> VideoAssetReference {
        try await withCheckedThrowingContinuation { continuation in
            let options = PHVideoRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.version = .current
            options.isNetworkAccessAllowed = true
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) {
                result, _, info in
                if (info?[PHImageCancelledKey] as? Bool) == true {
                    continuation.resume(throwing: CancellationError())
                } else if let error = info?[PHImageErrorKey] as? Error {
                    continuation.resume(throwing: error)
                } else if let result {
                    continuation.resume(returning: VideoAssetReference(asset: result))
                } else {
                    continuation.resume(throwing: PickerError.unreadable)
                }
            }
        }
    }
}

nonisolated private final class VideoAssetReference: @unchecked Sendable {
    let asset: AVAsset

    init(asset: AVAsset) {
        self.asset = asset
    }
}

private struct ContactAttachmentPicker: UIViewControllerRepresentable {
    let completion: @MainActor (PreparedFileSelection?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }

    func makeUIViewController(context: Context) -> CNContactPickerViewController {
        let picker = CNContactPickerViewController()
        picker.delegate = context.coordinator
        picker.displayedPropertyKeys = [CNContactPhoneNumbersKey, CNContactEmailAddressesKey]
        return picker
    }

    func updateUIViewController(_ uiViewController: CNContactPickerViewController, context: Context) {}

    final class Coordinator: NSObject, CNContactPickerDelegate {
        let completion: @MainActor (PreparedFileSelection?) -> Void

        init(completion: @escaping @MainActor (PreparedFileSelection?) -> Void) {
            self.completion = completion
        }

        func contactPickerDidCancel(_ picker: CNContactPickerViewController) {
            completion(nil)
        }

        func contactPicker(_ picker: CNContactPickerViewController, didSelect contact: CNContact) {
            do {
                let data = try CNContactVCardSerialization.data(with: [contact])
                guard !data.isEmpty, data.count <= TojMediaLimits.maximumMessageBytesInt else {
                    completion(nil)
                    return
                }
                let displayName = CNContactFormatter.string(from: contact, style: .fullName)
                    ?? String(localized: "Contact")
                let safeName = SafeMediaFileMetadata.sanitizedFileName(displayName + ".vcf")
                    ?? "Contact.vcf"
                completion(PreparedFileSelection(
                    data: data,
                    fileName: safeName,
                    contentType: UTType.vCard.preferredMIMEType ?? "text/vcard"
                ))
            } catch {
                completion(nil)
            }
        }
    }
}

@MainActor
private final class OneShotLocationProvider: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation, any Error>?
    private var timeoutTask: Task<Void, Never>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func request() async throws -> CLLocation {
        guard CLLocationManager.locationServicesEnabled() else {
            throw LocationShareError.servicesDisabled
        }
        guard continuation == nil else { throw LocationShareError.requestInProgress }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                timeoutTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(15))
                    guard !Task.isCancelled else { return }
                    self?.finish(.failure(LocationShareError.timedOut))
                }
                beginRequest(for: manager.authorizationStatus)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finish(.failure(CancellationError()))
            }
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard continuation != nil else { return }
        beginRequest(for: manager.authorizationStatus)
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last, location.horizontalAccuracy >= 0 else {
            finish(.failure(LocationShareError.unavailable))
            return
        }
        finish(.success(location))
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finish(.failure(error))
    }

    private func beginRequest(for status: CLAuthorizationStatus) {
        switch status {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            manager.requestLocation()
        case .denied, .restricted:
            finish(.failure(LocationShareError.permissionDenied))
        @unknown default:
            finish(.failure(LocationShareError.unavailable))
        }
    }

    private func finish(_ result: Result<CLLocation, any Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        manager.stopUpdatingLocation()
        continuation.resume(with: result)
    }
}

nonisolated private enum LocationShareError: LocalizedError, Sendable {
    case servicesDisabled
    case permissionDenied
    case requestInProgress
    case timedOut
    case unavailable

    var errorDescription: String? {
        switch self {
        case .servicesDisabled: String(localized: "Location Services are turned off")
        case .permissionDenied: String(localized: "Location access is required to share your position")
        case .requestInProgress: String(localized: "A location request is already in progress")
        case .timedOut: String(localized: "Your location could not be found in time")
        case .unavailable: String(localized: "Your current location is unavailable")
        }
    }
}

nonisolated private enum CameraCaptureResult: Sendable {
    case photo(Data)
    case video(Data)
}

private struct CameraCapturePicker: UIViewControllerRepresentable {
    let completion: @MainActor (CameraCaptureResult?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.delegate = context.coordinator
        picker.sourceType = .camera
        picker.mediaTypes = [UTType.image.identifier, UTType.movie.identifier]
        picker.cameraCaptureMode = .photo
        picker.videoQuality = .typeHigh
        picker.videoMaximumDuration = 180
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let completion: @MainActor (CameraCaptureResult?) -> Void

        init(completion: @escaping @MainActor (CameraCaptureResult?) -> Void) {
            self.completion = completion
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            completion(nil)
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage,
               let data = image.jpegData(compressionQuality: 0.92) {
                completion(.photo(data))
                return
            }
            guard let url = info[.mediaURL] as? URL else {
                completion(nil)
                return
            }
            Task {
                let result = await Task.detached(priority: .userInitiated) {
                    try? Data(contentsOf: url, options: .mappedIfSafe)
                }.value
                guard let result, !result.isEmpty,
                      result.count <= TojMediaLimits.maximumMessageBytesInt else {
                    completion(nil)
                    return
                }
                completion(.video(result))
            }
        }
    }
}

nonisolated private enum PickerError: LocalizedError, Sendable {
    case unreadable, emptyFile, tooLarge, unsupportedVideo, invalidFileName
    var errorDescription: String? {
        switch self {
        case .unreadable: String(localized: "That item could not be read")
        case .emptyFile: String(localized: "Empty files cannot be sent")
        case .tooLarge: String(localized: "That file is larger than 25 MB")
        case .unsupportedVideo: String(localized: "That video format could not be prepared")
        case .invalidFileName: String(localized: "That file name is not supported")
        }
    }
}

private struct DemoAttachmentPicker: View {
    let onSelect: (DemoAttachment) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Share something")
                .font(TojTheme.heading(.title, weight: .bold))
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                attachmentButton("Photo", icon: "photo.fill", attachment: .photo(name: "Photo"))
                attachmentButton("Video", icon: "video.fill", attachment: .video(name: "Evening video", duration: "0:24"))
                attachmentButton("File", icon: "doc.fill", attachment: .file(name: "Document.pdf", size: "1.8 MB"))
                attachmentButton("Link", icon: "link", attachment: .link(title: "Shared link", host: "toj.im"))
            }
            Label("Demo only — production shows connected capabilities", systemImage: "hammer.fill")
                .font(.caption)
                .foregroundStyle(TojTheme.secondaryText)
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(TojTheme.canvas)
    }

    private func attachmentButton(_ title: LocalizedStringKey, icon: String, attachment: DemoAttachment) -> some View {
        Button { onSelect(attachment) } label: {
            HStack(spacing: 11) {
                Image(systemName: icon).frame(width: 36, height: 36).background(TojTheme.strong, in: Circle())
                Text(title).font(.subheadline.weight(.semibold))
                Spacer()
            }
            .padding(13)
            .background(TojTheme.raised, in: RoundedRectangle(cornerRadius: TojRadius.field, style: .continuous))
        }
        .buttonStyle(.tojPressable)
    }
}

private struct DemoForwardingView: View {
    @Bindable var model: CloudAppModel
    let dialogs: [CloudAppModel.Dialog]
    let onDone: (String) -> Void

    var body: some View {
        NavigationStack {
            List(CloudAppModel.forwardingPickerDialogs(dialogs)) { dialog in
                Button {
                    TojFeedback.sent()
                    onDone(dialog.id)
                } label: {
                    HStack(spacing: 12) {
                        CloudProfileAvatar(
                            model: model,
                            title: dialog.title,
                            media: dialog.photo,
                            size: 42,
                            colorIndex: dialog.profileColorIndex,
                            systemImage: dialog.type == "saved" ? "bookmark.fill" : nil
                        )
                        Text(dialog.title).foregroundStyle(TojTheme.text)
                        Spacer()
                    }
                }
                .listRowBackground(TojTheme.raised)
            }
            .scrollContentBackground(.hidden)
            .background(TojTheme.canvas)
            .navigationTitle("Forward to")
        }
    }
}

private struct MessageDetailsView: View {
    let line: CloudAppModel.Line

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Message details").font(TojTheme.heading(.title, weight: .bold))
            Label(line.mine ? "Sent by you" : "Received from contact", systemImage: "person.fill")
            Label(line.timestamp.map(TojDateFormatting.message) ?? "Pending timestamp", systemImage: "clock")
            Label(deliveryText, systemImage: "checkmark.circle")
            if line.isEdited { Label("Edited", systemImage: "pencil") }
            Spacer()
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TojTheme.canvas)
    }

    private var deliveryText: String {
        switch line.delivery {
        case .sending: String(localized: "Queued for sending")
        case .sent: String(localized: "Sent")
        case .seen: String(localized: "Seen")
        case let .failed(reason): String(localized: "Failed: \(reason)")
        }
    }
}
