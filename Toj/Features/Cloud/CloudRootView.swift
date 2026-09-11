import SwiftUI

struct CloudRootView: View {
    #if DEBUG
    private static let isRunningUnitTests =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        && !TelegramFastUITestFixture.enabled
    #else
    private static let isRunningUnitTests =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    #endif
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var model = CloudAppModel.shared
    @State private var appLock = AppLockController.shared
    @State private var pendingLockedDeepLink: URL?

    var body: some View {
        Group {
            switch model.launchPhase {
            case .restoringLocal:
                CloudLocalLaunchView()
            case .recoveringStore:
                CloudLocalRecoveryView(status: model.status) {
                    Task { await model.retryLocalRecovery() }
                }
            case .signedOut:
                CloudAuthView(model: model)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.985)))
            case .localReady:
                if model.storedSession == nil {
                    CloudAuthView(model: model)
                } else {
                    CloudMainView(model: model)
                        .transition(.opacity)
                }
            }
        }
        .background(TojTheme.canvas.ignoresSafeArea())
        .animation(reduceMotion ? .easeOut(duration: 0.15) : TojTheme.stateAnimation, value: model.launchPhase)
        .task {
            guard !Self.isRunningUnitTests else { return }
            #if DEBUG
            if ProcessInfo.processInfo.environment["TOJ_DEMO_MODE"] == "1" {
                model.enterDemoMode()
                return
            }
            #endif
            await model.start()
        }
        .onChange(of: scenePhase) { _, phase in
            guard !Self.isRunningUnitTests else { return }
            if phase == .active {
                appLock.becameActive()
            } else {
                appLock.becameInactive()
            }
            Task {
                let isActive = phase == .active
                await model.setForegroundActive(isActive)
                if isActive { await model.activateForegroundServices() }
            }
        }
        .overlay(alignment: .top) {
            if model.callCoordinator.hasCall,
               !model.callCoordinator.isPresented,
               model.callCoordinator.state != .ended {
                TojActiveCallPill(coordinator: model.callCoordinator)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .overlay(alignment: .top) {
            if model.groupCallCoordinator.hasActiveCall,
               !model.groupCallCoordinator.isPresented {
                TojActiveGroupCallPill(coordinator: model.groupCallCoordinator)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .overlay {
            // This synchronous, opaque layer is present during the inactive transition itself;
            // the full-screen lock gate below owns interaction once the scene is active again.
            if appLock.privacyShieldVisible {
                TojTheme.canvas
                    .ignoresSafeArea()
                    .accessibilityHidden(true)
            }
        }
        .fullScreenCover(isPresented: Binding(
            get: { model.callCoordinator.isPresented },
            set: { presented in
                if !presented {
                    if model.callCoordinator.state == .ended { model.callCoordinator.dismissEnded() }
                    else { model.callCoordinator.minimize() }
                }
            }
        )) {
            TojCallScreen(coordinator: model.callCoordinator)
        }
        .fullScreenCover(isPresented: Binding(
            get: { model.groupCallCoordinator.isPresented },
            set: { presented in
                if !presented {
                    if model.groupCallCoordinator.state == .ended
                        || model.groupCallCoordinator.state == .failed {
                        model.groupCallCoordinator.dismissEndedCall()
                    } else {
                        model.groupCallCoordinator.isPresented = false
                    }
                }
            }
        )) {
            TojGroupCallScreen(coordinator: model.groupCallCoordinator)
        }
        .onOpenURL { url in
            // Do not let an external navigation mutate or reveal account state behind the lock.
            // Keep only the newest user intent and deliver it after device-owner authentication.
            if appLock.presentsGate {
                pendingLockedDeepLink = url
            } else {
                model.handleDeepLink(url)
            }
        }
        .onChange(of: appLock.presentsGate) { _, presentsGate in
            guard !presentsGate, let url = pendingLockedDeepLink else { return }
            pendingLockedDeepLink = nil
            model.handleDeepLink(url)
        }
        .fullScreenCover(isPresented: Binding(
            get: { appLock.presentsGate },
            set: { _ in }
        )) {
            AppLockGateView(controller: appLock)
                .interactiveDismissDisabled()
        }
        .sheet(isPresented: Binding(
            get: { !model.recoveredTwoFactorCodes.isEmpty },
            set: { _ in }
        )) {
            RecoveryCodesView(codes: model.recoveredTwoFactorCodes) {
                model.acknowledgeRecoveryCodes()
            }
            .interactiveDismissDisabled()
        }
        .alert("Replace saved chats?", isPresented: Binding(
            get: { model.requiresDifferentAccountCleanupConfirmation },
            set: { _ in }
        )) {
            Button("Keep saved chats", role: .cancel) {
                Task { await model.cancelDifferentAccountSignIn() }
            }
            Button("Erase and continue", role: .destructive) {
                Task { await model.confirmDifferentAccountSignIn() }
            }
        } message: {
            Text("This phone number belongs to a different Toj account. Continuing permanently removes the encrypted replica and pending outbox for the previous account from this device.")
        }
    }
}

private struct AppLockGateView: View {
    @Bindable var controller: AppLockController

    var body: some View {
        ZStack {
            TojTheme.canvas.ignoresSafeArea()
            VStack(spacing: 20) {
                TojMark(size: 76)
                if controller.isLocked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(TojTheme.gold)
                    Text("Toj is locked")
                        .font(TojTheme.heading(.title2, weight: .bold))
                        .foregroundStyle(TojTheme.text)
                    Text("Authenticate with Face ID, Touch ID, or your device passcode.")
                        .font(.subheadline)
                        .foregroundStyle(TojTheme.secondaryText)
                        .multilineTextAlignment(.center)
                    Button {
                        Task { await controller.unlock() }
                    } label: {
                        HStack(spacing: 8) {
                            if controller.authenticationInFlight { ProgressView() }
                            Text("Unlock Toj")
                        }
                        .frame(maxWidth: 280, minHeight: 52)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(TojTheme.gold)
                    .disabled(controller.authenticationInFlight)
                    if let error = controller.errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 300)
                    }
                }
            }
            .padding(28)
        }
        .task {
            if controller.isLocked { await controller.unlock() }
        }
    }
}

private struct CloudLocalLaunchView: View {
    var body: some View {
        VStack(spacing: 18) {
            TojMark(size: 76)
            ProgressView()
                .tint(TojTheme.gold)
                .accessibilityLabel("Opening encrypted messages")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TojTheme.canvas)
    }
}

private struct CloudLocalRecoveryView: View {
    let status: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "lock.trianglebadge.exclamationmark")
                .font(.system(size: 42, weight: .semibold))
                .foregroundStyle(TojTheme.gold)
            Text("Encrypted messages are unavailable")
                .font(TojTheme.heading(.title2, weight: .bold))
                .foregroundStyle(TojTheme.text)
            Text(status)
                .font(.subheadline)
                .foregroundStyle(TojTheme.secondaryText)
                .multilineTextAlignment(.center)
            Button("Try Again", action: retry)
                .buttonStyle(.borderedProminent)
                .tint(TojTheme.gold)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TojTheme.canvas)
    }
}

// MARK: - Authentication

private struct CloudAuthView: View {
    @Bindable var model: CloudAppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focusedField: Field?

    private enum Field { case phone, name, code, password, recovery, newPassword }

    private var canStart: Bool {
        model.canRequestCode && !model.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Spacer(minLength: 54)

                TojMark(size: 84)
                    .shadow(color: .black.opacity(0.65), radius: 28, y: 18)
                    .padding(.bottom, 28)

                Text(authTitle)
                    .font(TojTheme.heading(.largeTitle, weight: .bold))
                    .foregroundStyle(TojTheme.text)
                    .multilineTextAlignment(.center)

                Text(authSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(TojTheme.secondaryText)
                    .multilineTextAlignment(.center)
                    .padding(.top, 10)
                    .padding(.horizontal, 24)

                VStack(spacing: 12) {
                    if model.twoFactorChallengeId != nil {
                        if model.usesTwoFactorRecovery {
                            TojInputField(
                                title: "Recovery code",
                                placeholder: "XXXX-XXXX-XXXX-XXXX",
                                text: $model.twoFactorRecoveryCode,
                                contentType: nil,
                                keyboard: .asciiCapable
                            )
                            .focused($focusedField, equals: .recovery)
                            TojInputField(
                                title: "New two-step password",
                                placeholder: "At least 8 characters",
                                text: $model.twoFactorReplacementPassword,
                                contentType: .newPassword,
                                keyboard: .default,
                                isSecure: true
                            )
                            .focused($focusedField, equals: .newPassword)
                        } else {
                            TojInputField(
                                title: "Two-step password",
                                placeholder: "Password",
                                text: $model.twoFactorPassword,
                                contentType: .password,
                                keyboard: .default,
                                isSecure: true
                            )
                            .focused($focusedField, equals: .password)
                        }
                    } else if model.requestedCode {
                        TojInputField(
                            title: "Verification code",
                            placeholder: "000000",
                            text: $model.code,
                            contentType: .oneTimeCode,
                            keyboard: .numberPad
                        )
                        .focused($focusedField, equals: .code)
                        .transition(fieldTransition)
                    } else {
                        TojInputField(
                            title: "Phone number",
                            placeholder: "+992",
                            text: $model.phone,
                            contentType: .telephoneNumber,
                            keyboard: .phonePad
                        )
                        .focused($focusedField, equals: .phone)

                        TojInputField(
                            title: "Your name",
                            placeholder: "Display name",
                            text: $model.displayName,
                            contentType: .name,
                            keyboard: .default
                        )
                        .focused($focusedField, equals: .name)
                        #if DEBUG
                        if model.telegramOTPAvailable {
                            Toggle("Receive my code in Telegram", isOn: $model.useTelegramOTP)
                                .disabled(model.authRequestInFlight)
                            Text("Private staging test. Sends a Toj code to the Telegram account for this number, not by SMS.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        #endif
                    }
                }
                .padding(.top, 34)

                if shouldShowStatus {
                    Label(model.status, systemImage: statusIsError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(statusIsError ? Color.red : TojTheme.secure)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 12)
                        .transition(.opacity)
                }

                Button(action: primaryAction) {
                    HStack(spacing: 9) {
                        if model.authRequestInFlight || model.authVerifyInFlight {
                            ProgressView().tint(TojTheme.canvas)
                        }
                        Text(primaryTitle)
                            .font(.headline)
                    }
                    .frame(maxWidth: .infinity, minHeight: 54)
                }
                .buttonStyle(.plain)
                .foregroundStyle(TojTheme.onAccent)
                .background(TojTheme.accent, in: Capsule())
                .opacity(primaryEnabled ? 1 : 0.42)
                .disabled(!primaryEnabled)
                .padding(.top, 18)

                #if DEBUG
                Button {
                    focusedField = nil
                    model.enterDemoMode()
                } label: {
                    HStack(spacing: 11) {
                        Image(systemName: "sparkles")
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Explore demo")
                                .font(.subheadline.weight(.semibold))
                            Text("No account or SMS required")
                                .font(.caption2)
                                .foregroundStyle(TojTheme.secondaryText)
                        }
                        Spacer()
                        Image(systemName: "arrow.right")
                            .font(.caption.bold())
                    }
                    .foregroundStyle(TojTheme.text)
                    .padding(.horizontal, 18)
                    .frame(maxWidth: .infinity, minHeight: 58)
                }
                .buttonStyle(.glass)
                .padding(.top, 12)
                .accessibilityHint("Opens local sample chats without creating an account")
                #endif

                if model.twoFactorChallengeId != nil {
                    Button(model.usesTwoFactorRecovery ? "Use password instead" : "Use a recovery code") {
                        model.usesTwoFactorRecovery.toggle()
                        focusedField = model.usesTwoFactorRecovery ? .recovery : .password
                    }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(TojTheme.text)
                    .padding(.top, 18)
                } else if model.requestedCode {
                    HStack(spacing: 18) {
                        Button("Change number") { model.resetAuthCode() }
                        if model.resendSeconds > 0 {
                            Group {
                                switch model.resendCountdown {
                                case .seconds(let seconds): Text("Resend in \(seconds)s")
                                case .minutes(let minutes): Text("Resend in \(minutes)m")
                                }
                            }
                            .foregroundStyle(TojTheme.secondaryText)
                        } else {
                            Button("Send again") { Task { await model.requestCode() } }
                        }
                    }
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(TojTheme.text)
                    .padding(.top, 18)
                }

                Label("Cloud chats sync across your devices", systemImage: "cloud.fill")
                    .font(.caption)
                    .foregroundStyle(TojTheme.secondaryText)
                    .symbolRenderingMode(.hierarchical)
                    .padding(.top, 26)

                Spacer(minLength: 34)
            }
            .frame(maxWidth: 430)
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(TojTheme.canvas)
        .onChange(of: model.requestedCode) { _, requested in
            focusedField = requested ? .code : nil
        }
        .onChange(of: model.twoFactorChallengeId) { _, challenge in
            focusedField = challenge == nil ? nil : .password
        }
        .animation(reduceMotion ? .easeOut(duration: 0.15) : TojTheme.stateAnimation, value: model.requestedCode)
    }

    private var fieldTransition: AnyTransition {
        reduceMotion ? .opacity : .asymmetric(insertion: .opacity.combined(with: .move(edge: .trailing)), removal: .opacity)
    }

    private var primaryEnabled: Bool {
        if model.twoFactorChallengeId != nil { return model.canVerifySecondFactor }
        return model.requestedCode ? model.canVerifyCode : canStart
    }

    private var authTitle: LocalizedStringKey {
        if model.twoFactorChallengeId != nil { return "Two-step verification" }
        return model.requestedCode ? "Enter your code" : "Welcome to Toj"
    }

    private var authSubtitle: LocalizedStringKey {
        if model.twoFactorChallengeId != nil {
            return model.usesTwoFactorRecovery
                ? "Enter one saved recovery code and choose a replacement password."
                : "Enter the account password you set in Privacy and Security."
        }
        #if DEBUG
        if model.requestedCode && model.telegramOTPAvailable && model.useTelegramOTP {
            return "Check Telegram for your six-digit Toj code."
        }
        #endif
        return model.requestedCode
            ? "We sent a six-digit code to your phone."
            : "Fast, private messaging made for your people."
    }

    private var primaryTitle: LocalizedStringKey {
        if model.twoFactorChallengeId != nil {
            return model.usesTwoFactorRecovery ? "Recover and sign in" : "Continue"
        }
        return model.requestedCode ? "Sign in" : "Get code"
    }

    private var shouldShowStatus: Bool {
        model.status == "Code requested"
            || model.status.hasPrefix("Code request failed")
            || model.status.hasPrefix("Sign in failed")
            || model.status.hasPrefix("Two-step")
    }

    private var statusIsError: Bool {
        let value = model.status.lowercased()
        return value.contains("failed") || value.contains("could not") || value.contains("no account")
    }

    private func primaryAction() {
        focusedField = nil
        Task {
            if model.twoFactorChallengeId != nil {
                await model.verifySecondFactor()
            } else if model.requestedCode {
                await model.verifyCode()
            } else {
                await model.requestCode()
            }
        }
    }
}

private struct TojInputField: View {
    let title: LocalizedStringKey
    let placeholder: LocalizedStringKey
    @Binding var text: String
    let contentType: UITextContentType?
    let keyboard: UIKeyboardType
    var isSecure = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(TojTheme.secondaryText)
                .textCase(.uppercase)
            Group {
                if isSecure {
                    SecureField(placeholder, text: $text)
                } else {
                    TextField(placeholder, text: $text)
                }
            }
                .font(.body.weight(.medium))
                .foregroundStyle(TojTheme.text)
                .textContentType(contentType)
                .keyboardType(keyboard)
                .textInputAutocapitalization(keyboard == .default ? .words : .never)
        }
        .padding(.horizontal, 17)
        .frame(minHeight: 62)
        .background(TojTheme.raised, in: RoundedRectangle(cornerRadius: TojRadius.field, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: TojRadius.field, style: .continuous).stroke(TojTheme.hairline, lineWidth: 0.5))
    }
}

// MARK: - Main navigation

private enum MainTab: Hashable {
    case contacts
    case calls
    case chats
    case settings
    case search
}

private struct CloudMainView: View {
    @Bindable var model: CloudAppModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var selection: MainTab = .chats
    @State private var chatPath: [String] = []
    @State private var searchPath: [String] = []
    @State private var query = ""
    @State private var searchScope: SearchScope = .chats
    @State private var showingCompose = false
    @State private var splitDialogId: String?
    @State private var contactsStore = TojContactsStore()

    private var unreadCount: Int {
        model.dialogs.reduce(0) { $0 + ($1.isArchived ? 0 : $1.unreadCount) }
    }

    var body: some View {
        TabView(selection: $selection) {
            Tab("Contacts", systemImage: "person.crop.circle.fill", value: .contacts) {
                CloudContactsView(model: model, store: contactsStore)
            }

            Tab("Calls", systemImage: "phone.fill", value: .calls) {
                ComingSoonView(
                    title: "Calls", systemImage: "phone.fill",
                    detail: "Recent voice and video calls will appear here."
                )
            }

            Tab("Chats", systemImage: "bubble.left.and.bubble.right.fill", value: .chats) {
                chatNavigation(path: $chatPath, focusSearchOnAppear: false)
            }
            .badge(unreadCount)

            Tab("Settings", systemImage: "gearshape.fill", value: .settings) {
                CloudSettingsView(model: model)
            }

            Tab(value: .search, role: .search) {
                chatNavigation(path: $searchPath, focusSearchOnAppear: true)
            } label: {
                Label("Search", systemImage: "magnifyingglass")
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .tint(TojTheme.text)
        .background(TojTheme.canvas)
        .onChange(of: selection) { _, _ in
            TojFeedback.selection()
        }
        .onChange(of: model.pendingDeepLinkDialogId) { _, dialogId in
            guard let dialogId else { return }
            selection = .chats
            model.prepareConversationOpen(dialogId: dialogId)
            if horizontalSizeClass == .regular {
                splitDialogId = dialogId
            } else {
                chatPath = [dialogId]
            }
            model.consumePendingDeepLink()
        }
        #if DEBUG
        .task {
            if ProcessInfo.processInfo.environment["TOJ_DEMO_SEARCH"] == "1" {
                selection = .search
                return
            }
            if ProcessInfo.processInfo.environment["TOJ_DEMO_CONTACTS"] == "1" {
                selection = .contacts
                return
            }
            if ProcessInfo.processInfo.environment["TOJ_DEMO_SETTINGS"] == "1" {
                selection = .settings
                return
            }
            if let dialogId = ProcessInfo.processInfo.environment["TOJ_DEMO_DIALOG"], chatPath.isEmpty {
                selection = .chats
                model.prepareConversationOpen(dialogId: dialogId)
                chatPath = [dialogId]
            }
        }
        #endif
        .sheet(isPresented: $showingCompose) {
            NewChatSheet(model: model, contactsStore: contactsStore) { dialogId in
                showingCompose = false
                selection = .chats
                model.prepareConversationOpen(dialogId: dialogId)
                chatPath = [dialogId]
            }
            .presentationDetents([.height(330)])
            .presentationDragIndicator(.visible)
        }
    }

    @ViewBuilder
    private func chatNavigation(path: Binding<[String]>, focusSearchOnAppear: Bool) -> some View {
        if horizontalSizeClass == .regular {
            NavigationSplitView {
                CloudChatsView(
                    model: model,
                    query: $query,
                    searchScope: $searchScope,
                    focusSearchOnAppear: focusSearchOnAppear,
                    onCompose: { showingCompose = true },
                    onOpen: {
                        model.prepareConversationOpen(dialogId: $0)
                        splitDialogId = $0
                    }
                )
                .navigationSplitViewColumnWidth(min: 330, ideal: 390, max: 440)
            } detail: {
                if let splitDialogId {
                    TojConversationExperience(model: model, dialogId: splitDialogId)
                } else {
                    VStack(spacing: 14) {
                        TojMark(size: 64)
                        Text("Choose a conversation")
                            .font(TojTheme.heading(.title3))
                        Text("Your messages will appear here.")
                            .font(.subheadline)
                            .foregroundStyle(TojTheme.secondaryText)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(TojTheme.canvas)
                }
            }
            .navigationSplitViewStyle(.balanced)
        } else {
            NavigationStack(path: path) {
                CloudChatsView(
                    model: model,
                    query: $query,
                    searchScope: $searchScope,
                    focusSearchOnAppear: focusSearchOnAppear,
                    onCompose: { showingCompose = true },
                    onOpen: {
                        model.prepareConversationOpen(dialogId: $0)
                        path.wrappedValue.append($0)
                    }
                )
                .navigationDestination(for: String.self) { dialogId in
                    TojConversationExperience(model: model, dialogId: dialogId)
                }
            }
        }
    }
}

// MARK: - Chats

nonisolated enum ChatSearchDrawerBehavior {
    static let height: CGFloat = 52
    static let revealDeadZone: CGFloat = 14
    static let openThreshold: CGFloat = 22
    static let closeThreshold: CGFloat = 14

    static func revealIsArmed(startingAt offset: CGFloat) -> Bool {
        offset <= height + 0.5
    }

    static func revealProgress(at offset: CGFloat, revealWasArmed: Bool) -> CGFloat {
        guard revealWasArmed else { return 0 }
        let visibleHeight = height - min(max(offset, 0), height)
        let revealRange = height - revealDeadZone
        return min(max((visibleHeight - revealDeadZone) / revealRange, 0), 1)
    }

    static func shouldOpen(wasOpen: Bool, revealWasArmed: Bool, offset: CGFloat) -> Bool {
        guard revealWasArmed else { return false }
        let clampedOffset = max(offset, 0)
        guard clampedOffset < height else { return false }
        return wasOpen
            ? clampedOffset < closeThreshold
            : height - clampedOffset >= openThreshold
    }
}

nonisolated enum ChatFolderFilter: String, CaseIterable, Hashable, Sendable {
    case all
    case unread
    case personal
    case groups
    case muted

    var title: String {
        switch self {
        case .all: String(localized: "All")
        case .unread: String(localized: "Unread")
        case .personal: String(localized: "Personal")
        case .groups: String(localized: "Groups")
        case .muted: String(localized: "Muted")
        }
    }

    func includes(_ dialog: CloudAppModel.Dialog) -> Bool {
        guard !dialog.isArchived else { return false }
        return switch self {
        case .all: true
        case .unread: dialog.unreadCount > 0
        case .personal: dialog.type == "direct" || dialog.type == "saved"
        case .groups: dialog.type == "group"
        case .muted: dialog.isMuted
        }
    }
}

private struct ChatFolderManagerView: View {
    @Bindable var model: CloudAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var showingCreate = false
    @State private var editingFolder: CloudChatFolder?
    @State private var errorMessage: String?

    var body: some View {
        List {
            if model.chatFolders.isEmpty {
                ContentUnavailableView(
                    "No Custom Folders",
                    systemImage: "folder",
                    description: Text("Create a folder that stays in sync on every device.")
                )
            } else {
                ForEach(model.chatFolders) { folder in
                    Button {
                        editingFolder = folder
                    } label: {
                        HStack {
                            Label(folder.title, systemImage: folder.systemImageName)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(TojTheme.tertiaryText)
                        }
                    }
                    .buttonStyle(.plain)
                        .swipeActions {
                            Button("Delete", role: .destructive) {
                                Task {
                                    do { try await model.deleteChatFolder(folder) }
                                    catch { errorMessage = error.localizedDescription }
                                }
                            }
                        }
                }
                .onMove { source, destination in
                    guard source.count == 1, let sourceIndex = source.first else { return }
                    let moving = model.chatFolders[sourceIndex]
                    var reordered = model.chatFolders
                    reordered.move(fromOffsets: source, toOffset: destination)
                    guard let movedIndex = reordered.firstIndex(where: { $0.id == moving.id }) else { return }
                    let before = movedIndex + 1 < reordered.count ? reordered[movedIndex + 1] : nil
                    let after = movedIndex > 0 ? reordered[movedIndex - 1] : nil
                    guard before != nil || after != nil else { return }
                    Task {
                        do {
                            if let before {
                                try await model.moveChatFolder(moving, before: before)
                            } else {
                                try await model.moveChatFolder(moving, after: after)
                            }
                        }
                        catch { errorMessage = error.localizedDescription }
                    }
                }
            }
        }
        .navigationTitle("Chat Folders")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            ToolbarItem(placement: .primaryAction) {
                Button("New", systemImage: "plus") { showingCreate = true }
            }
        }
        .sheet(isPresented: $showingCreate) { ChatFolderEditorView(model: model, folder: nil) }
        .sheet(item: $editingFolder) { folder in
            ChatFolderEditorView(model: model, folder: folder)
        }
        .alert("Folder could not be changed", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) { Button("OK") { errorMessage = nil } } message: { Text(errorMessage ?? "") }
    }
}

private struct ChatFolderEditorView: View {
    @Bindable var model: CloudAppModel
    let folder: CloudChatFolder?
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var icon = "folder"
    @State private var includeDirect = true
    @State private var includeGroups = true
    @State private var includeSaved = false
    @State private var excludeRead = false
    @State private var excludeMuted = false
    @State private var excludeArchived = true
    @State private var ruleSelections: [String: String] = [:]
    @State private var initialized = false
    @State private var saving = false
    @State private var errorMessage: String?

    private var folderRules: [CloudChatFolderRule] {
        ruleSelections
            .filter { $0.value == "include" || $0.value == "exclude" }
            .sorted { $0.key < $1.key }
            .map { CloudChatFolderRule(dialogId: $0.key, rule: $0.value) }
    }

    private func ruleBinding(for dialogId: String) -> Binding<String> {
        Binding(
            get: { ruleSelections[dialogId] ?? "automatic" },
            set: { choice in
                if choice == "automatic" {
                    ruleSelections.removeValue(forKey: dialogId)
                } else {
                    ruleSelections[dialogId] = choice
                }
            }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Folder name", text: $title)
                Picker("Icon", selection: $icon) {
                    Label("Folder", systemImage: "folder").tag("folder")
                    Label("People", systemImage: "person.2").tag("personal")
                    Label("Unread", systemImage: "message.badge").tag("unread")
                    Label("Work", systemImage: "briefcase").tag("work")
                    Label("Favorite", systemImage: "star").tag("favorite")
                }
                Section("Include") {
                    Toggle("Personal chats", isOn: $includeDirect)
                    Toggle("Groups", isOn: $includeGroups)
                    Toggle("Saved Messages", isOn: $includeSaved)
                }
                Section("Exclude") {
                    Toggle("Read chats", isOn: $excludeRead)
                    Toggle("Muted chats", isOn: $excludeMuted)
                    Toggle("Archived chats", isOn: $excludeArchived)
                }
                if !model.dialogs.isEmpty {
                    Section {
                        ForEach(model.dialogs) { dialog in
                            Picker(dialog.title, selection: ruleBinding(for: dialog.id)) {
                                Text("Automatic").tag("automatic")
                                Text("Always Include").tag("include")
                                Text("Always Exclude").tag("exclude")
                            }
                        }
                    } header: {
                        Text("Specific Chats")
                    } footer: {
                        Text("Specific choices override the folder's automatic rules and sync to every device.")
                    }
                }
            }
            .navigationTitle(folder == nil ? "New Folder" : "Edit Folder")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(folder == nil ? "Create" : "Save") {
                        saving = true
                        Task {
                            do {
                                if let folder {
                                    try await model.updateChatFolder(
                                        folder,
                                        title: title,
                                        icon: icon,
                                        includeDirect: includeDirect,
                                        includeGroups: includeGroups,
                                        includeSaved: includeSaved,
                                        excludeRead: excludeRead,
                                        excludeMuted: excludeMuted,
                                        excludeArchived: excludeArchived,
                                        rules: folderRules
                                    )
                                } else {
                                    try await model.createChatFolder(
                                        title: title,
                                        icon: icon,
                                        includeDirect: includeDirect,
                                        includeGroups: includeGroups,
                                        includeSaved: includeSaved,
                                        excludeRead: excludeRead,
                                        excludeMuted: excludeMuted,
                                        excludeArchived: excludeArchived,
                                        rules: folderRules
                                    )
                                }
                                dismiss()
                            } catch {
                                errorMessage = error.localizedDescription
                                saving = false
                            }
                        }
                    }
                    .disabled(saving || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .alert("Folder was not created", isPresented: Binding(
                get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
            )) { Button("OK") { errorMessage = nil } } message: { Text(errorMessage ?? "") }
            .task {
                guard !initialized else { return }
                initialized = true
                guard let folder else { return }
                title = folder.title
                icon = folder.icon
                includeDirect = folder.includeDirect
                includeGroups = folder.includeGroups
                includeSaved = folder.includeSaved
                excludeRead = folder.excludeRead
                excludeMuted = folder.excludeMuted
                excludeArchived = folder.excludeArchived
                ruleSelections = Dictionary(uniqueKeysWithValues: folder.rules.map {
                    ($0.dialogId, $0.rule)
                })
            }
        }
    }
}

private struct ScheduledMessagesView: View {
    @Bindable var model: CloudAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var reschedulingDelivery: CloudScheduledDelivery?
    @State private var errorMessage: String?

    var body: some View {
        List {
            if model.scheduledDeliveries.filter({
                ["scheduled", "processing", "local_pending", "local_error", "cancel_pending", "reschedule_pending"]
                    .contains($0.state)
            }).isEmpty {
                ContentUnavailableView(
                    "No Scheduled Messages",
                    systemImage: "clock",
                    description: Text("Messages scheduled on the server will appear here on every device.")
                )
            }
            ForEach(model.scheduledDeliveries.filter {
                ["scheduled", "processing", "local_pending", "local_error", "cancel_pending", "reschedule_pending"]
                    .contains($0.state)
            }) { delivery in
                VStack(alignment: .leading, spacing: 5) {
                    Text(delivery.items.first?.body ?? "Attachment")
                        .lineLimit(2)
                    Text(ISO8601DateFormatter().date(from: delivery.deliverAt) ?? Date(), style: .date)
                        .font(.caption)
                        .foregroundStyle(TojTheme.secondaryText)
                    Text(ISO8601DateFormatter().date(from: delivery.deliverAt) ?? Date(), style: .time)
                        .font(.caption)
                        .foregroundStyle(TojTheme.secondaryText)
                    if delivery.state == "local_pending" {
                        Label("Waiting for connection — not scheduled yet", systemImage: "wifi.exclamationmark")
                            .font(.caption)
                            .foregroundStyle(TojTheme.secondaryText)
                    }
                    if delivery.state == "cancel_pending" {
                        Label("Cancellation pending — it may still send until confirmed", systemImage: "clock.badge.exclamationmark")
                            .font(.caption)
                            .foregroundStyle(TojTheme.secondaryText)
                    }
                    if delivery.state == "reschedule_pending" {
                        Label("New time saved — waiting to sync", systemImage: "arrow.triangle.2.circlepath")
                            .font(.caption)
                            .foregroundStyle(TojTheme.secondaryText)
                    }
                    if delivery.state == "local_error" {
                        Label("Scheduling failed — cancel to remove", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    if delivery.state != "processing"
                        && delivery.state != "cancel_pending"
                        && delivery.state != "local_error" {
                        reschedulingDelivery = delivery
                    }
                }
                .swipeActions {
                    Button("Cancel", role: .destructive) {
                        Task {
                            do { try await model.cancelScheduledDelivery(delivery) }
                            catch { errorMessage = error.localizedDescription }
                        }
                    }
                    .disabled(delivery.state == "processing" || delivery.state == "cancel_pending")
                    Button("Reschedule", systemImage: "calendar") {
                        reschedulingDelivery = delivery
                    }
                    .tint(TojTheme.gold)
                    .disabled(
                        delivery.state == "processing"
                            || delivery.state == "cancel_pending"
                            || delivery.state == "local_error"
                    )
                }
            }
        }
        .navigationTitle("Scheduled Messages")
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        .task { await model.refreshCloudProductivity() }
        .refreshable { await model.refreshCloudProductivity() }
        .sheet(item: $reschedulingDelivery) { delivery in
            RescheduleDeliveryView(model: model, delivery: delivery)
        }
        .alert("Scheduled message could not be changed", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) { Button("OK") { errorMessage = nil } } message: { Text(errorMessage ?? "") }
    }
}

private struct RescheduleDeliveryView: View {
    @Bindable var model: CloudAppModel
    let delivery: CloudScheduledDelivery
    @Environment(\.dismiss) private var dismiss
    @State private var date = Date().addingTimeInterval(300)
    @State private var initialized = false
    @State private var saving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                DatePicker(
                    "Deliver at",
                    selection: $date,
                    in: Date().addingTimeInterval(60)...,
                    displayedComponents: [.date, .hourAndMinute]
                )
            }
            .navigationTitle("Reschedule")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saving = true
                        Task {
                            do {
                                try await model.rescheduleDelivery(delivery, to: date)
                                dismiss()
                            } catch {
                                errorMessage = error.localizedDescription
                                saving = false
                            }
                        }
                    }
                    .disabled(saving || date < Date().addingTimeInterval(60))
                }
            }
            .task {
                guard !initialized else { return }
                initialized = true
                if let parsed = ISO8601DateFormatter().date(from: delivery.deliverAt),
                   parsed >= Date().addingTimeInterval(60) {
                    date = parsed
                }
            }
            .alert("Message was not rescheduled", isPresented: Binding(
                get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
            )) { Button("OK") { errorMessage = nil } } message: { Text(errorMessage ?? "") }
        }
    }
}

private struct CloudChatsView: View {
    @Bindable var model: CloudAppModel
    @Binding var query: String
    @Binding var searchScope: SearchScope
    let focusSearchOnAppear: Bool
    let onCompose: () -> Void
    var onOpen: ((String) -> Void)? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isEditing = false
    @State private var selectedDialogIds: Set<String> = []
    @State private var bulkActionInFlight = false
    @State private var isSearchDrawerOpen = false
    @State private var searchScrollOffset = ChatSearchDrawerBehavior.height
    @State private var searchRevealWasArmed = true
    @State private var showingArchivedChats = false
    @State private var showingFolderManager = false
    @State private var showingScheduledMessages = false
    @AppStorage("toj.chat-folder.selection") private var folderRawValue = ChatFolderFilter.all.rawValue
    @FocusState private var searchFocused: Bool

    private var isSearching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Built once the coordinator exists. Nil means the index is unavailable and the screen falls
    /// back to filtering titles, which is the old behaviour rather than a blank list.
    @State private var searchController: MessageSearchController?

    private var filteredDialogs: [CloudAppModel.Dialog] {
        let matches = model.dialogs(matching: query, scope: searchScope)
        guard !isSearching, !searchScope.browsesWithoutQuery else { return matches }
        if folderRawValue.hasPrefix("custom:"),
           let folder = model.chatFolders.first(where: {
               "custom:\($0.folderId)" == folderRawValue
           }) {
            return matches.filter { model.dialog($0, isIncludedIn: folder) }
        }
        return matches.filter(selectedFolder.includes)
    }

    private var selectedFolder: ChatFolderFilter {
        get { ChatFolderFilter(rawValue: folderRawValue) ?? .all }
        nonmutating set { folderRawValue = newValue.rawValue }
    }

    private var folderBinding: Binding<ChatFolderFilter> {
        Binding(get: { selectedFolder }, set: { selectedFolder = $0 })
    }

    private var archivedDialogs: [CloudAppModel.Dialog] {
        model.dialogs.filter(\.isArchived)
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        searchDrawer
                            .id("chat-search")
                            .task { await syncSearchController() }
                            .onChange(of: query) { _, newValue in
                                searchController?.query = newValue
                            }
                            .onChange(of: searchScope) { _, newValue in
                                searchController?.scope = newValue
                            }
                        Color.clear
                            .frame(height: 0)
                            .id("chat-list-top")

                        if !isSearching, !searchScope.browsesWithoutQuery {
                            TojPillFilter(
                                items: ChatFolderFilter.allCases,
                                selection: folderBinding,
                                title: { $0.title }
                            )
                            .padding(.bottom, 7)
                            .accessibilityLabel("Chat folders")
                            if model.capabilities.contains(.chatFolders), !model.chatFolders.isEmpty {
                                ScrollView(.horizontal) {
                                    HStack(spacing: 8) {
                                        ForEach(model.chatFolders) { folder in
                                            let value = "custom:\(folder.folderId)"
                                            Button(folder.title) { folderRawValue = value }
                                                .buttonStyle(.bordered)
                                                .tint(folderRawValue == value ? TojTheme.accent : TojTheme.secondaryText)
                                                .accessibilityAddTraits(folderRawValue == value ? .isSelected : [])
                                        }
                                    }
                                }
                                .scrollIndicators(.hidden)
                                .padding(.bottom, 7)
                            }
                        }

                        if isSearching || searchScope.browsesWithoutQuery,
                           model.capabilities.contains(.localSearch) || model.capabilities.contains(.richSearch) {
                            TojPillFilter(items: SearchScope.allCases, selection: $searchScope) { $0.title }
                                .padding(.bottom, 6)
                                .accessibilityLabel("Search filters")
                        }

                        if !isSearching, !archivedDialogs.isEmpty, !searchScope.browsesWithoutQuery {
                            archivedChatsEntry
                        }

                        if let controller = searchController,
                           isSearching || searchScope.browsesWithoutQuery {
                            // Real message search. The chat-list filter below stays as the fallback
                            // for a device whose index is unavailable.
                            SearchResultsView(
                                controller: controller,
                                onOpenDialog: { onOpen?($0) },
                                onOpenMessage: { hit in
                                    // Focus is set before navigation so the conversation anchors on
                                    // the match instead of opening at the bottom and scrolling.
                                    model.prepareConversationOpen(
                                        dialogId: hit.dialogId, focusMsgId: hit.msgId
                                    )
                                    onOpen?(hit.dialogId)
                                }
                            )
                            .frame(minHeight: geometry.size.height * 0.7)
                        } else if filteredDialogs.isEmpty, archivedDialogs.isEmpty || isSearching {
                            emptyState
                                .padding(.top, 92)
                        } else {
                            ForEach(filteredDialogs) { dialog in
                                dialogLink(dialog)
                                .contextMenu {
                                    if model.capabilities.contains(.chatOrganization) {
                                        Button(dialog.isPinned ? "Unpin" : "Pin", systemImage: dialog.isPinned ? "pin.slash" : "pin") {
                                            model.togglePinned(dialog.id)
                                        }
                                    }
                                    if dialog.type != "saved",
                                       model.capabilities.contains(.chatOrganization)
                                        || (dialog.type == "group" && model.capabilities.contains(.groups)) {
                                        Button(dialog.isMuted ? "Unmute" : "Mute", systemImage: dialog.isMuted ? "speaker.wave.2" : "speaker.slash") {
                                            model.toggleMuted(dialog.id)
                                        }
                                    }
                                    if dialog.type != "saved",
                                       model.capabilities.contains(.chatOrganization) {
                                        Button(
                                            dialog.isArchived ? "Unarchive" : "Archive",
                                            systemImage: dialog.isArchived ? "tray.and.arrow.up" : "archivebox"
                                        ) {
                                            dialog.isArchived
                                                ? model.unarchive(dialog.id)
                                                : model.archive(dialog.id)
                                        }
                                    }
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    if dialog.type != "saved",
                                       model.capabilities.contains(.chatOrganization) {
                                        Button {
                                            dialog.isArchived
                                                ? model.unarchive(dialog.id)
                                                : model.archive(dialog.id)
                                        } label: {
                                            Label(
                                                dialog.isArchived ? "Unarchive" : "Archive",
                                                systemImage: dialog.isArchived ? "tray.and.arrow.up" : "archivebox"
                                            )
                                        }
                                        .tint(TojTheme.strong)
                                    }
                                    if dialog.type != "saved",
                                       model.capabilities.contains(.chatOrganization)
                                        || (dialog.type == "group" && model.capabilities.contains(.groups)) {
                                        Button { model.toggleMuted(dialog.id) } label: {
                                            Label(dialog.isMuted ? "Unmute" : "Mute", systemImage: dialog.isMuted ? "speaker.wave.2" : "speaker.slash")
                                        }
                                        .tint(.gray)
                                    }
                                }
                            }
                        }
                    }
                    .frame(minHeight: geometry.size.height + 54, alignment: .top)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 26)
                }
                .scrollDismissesKeyboard(.interactively)
                .onScrollGeometryChange(for: CGFloat.self) { scrollGeometry in
                    normalizedScrollOffset(scrollGeometry)
                } action: { _, newOffset in
                    if !searchRevealWasArmed, newOffset < ChatSearchDrawerBehavior.height {
                        searchScrollOffset = ChatSearchDrawerBehavior.height
                        proxy.scrollTo("chat-list-top", anchor: .top)
                    } else {
                        searchScrollOffset = newOffset
                    }
                }
                .onScrollPhaseChange { oldPhase, newPhase, context in
                    let offset = normalizedScrollOffset(context.geometry)
                    if newPhase == .tracking {
                        searchRevealWasArmed = ChatSearchDrawerBehavior.revealIsArmed(startingAt: offset)
                        return
                    }
                    guard oldPhase == .interacting,
                          newPhase == .decelerating || newPhase == .idle else { return }
                    settleSearchDrawer(
                        at: offset,
                        using: proxy
                    )
                }
                .onAppear {
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(80))
                        #if DEBUG
                        if ProcessInfo.processInfo.environment["TOJ_DEMO_EDIT"] == "1" {
                            isEditing = true
                        }
                        #endif
                        if focusSearchOnAppear {
                            isSearchDrawerOpen = true
                            searchRevealWasArmed = true
                            withAnimation(reduceMotion ? .easeOut(duration: 0.14) : TojTheme.stateAnimation) {
                                proxy.scrollTo("chat-search", anchor: .top)
                            }
                            searchFocused = true
                        } else {
                            isSearchDrawerOpen = false
                            searchRevealWasArmed = true
                            proxy.scrollTo("chat-list-top", anchor: .top)
                        }
                    }
                }
            }
        }
        .background(TojTheme.canvas)
        .navigationTitle("Chats")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(isEditing ? "Done" : "Edit") {
                    withAnimation(reduceMotion ? .easeOut(duration: 0.14) : TojTheme.stateAnimation) {
                        isEditing.toggle()
                        if !isEditing { selectedDialogIds.removeAll() }
                    }
                    TojFeedback.selection()
                }
                .font(.body.weight(.medium))
                .foregroundStyle(TojTheme.text)
            }
            ToolbarItem(placement: .principal) {
                Text("Chats")
                    .font(TojTheme.heading(.headline, weight: .semibold))
                    .foregroundStyle(TojTheme.text)
            }
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 10) {
                    if model.capabilities.contains(.chatFolders)
                        || model.capabilities.contains(.scheduledDelivery) {
                        Menu {
                            if model.capabilities.contains(.chatFolders) {
                                Button("Manage Folders", systemImage: "folder") {
                                    showingFolderManager = true
                                }
                            }
                            if model.capabilities.contains(.scheduledDelivery) {
                                Button("Scheduled Messages", systemImage: "clock") {
                                    showingScheduledMessages = true
                                }
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                    Button(action: onCompose) {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 17, weight: .semibold))
                    }
                    .accessibilityLabel("New chat")
                }
                .buttonStyle(.glass)
            }
        }
        .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .top, spacing: 0) {
            if model.replicaSyncState != .ready {
                QuietReplicaSyncBanner(state: model.replicaSyncState) {
                    model.retryReplicaSync()
                }
                .padding(.horizontal, 16)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if isEditing {
                bulkActionBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(
            reduceMotion ? .easeOut(duration: 0.14) : TojTheme.stateAnimation,
            value: model.replicaSyncState
        )
        .sheet(isPresented: $showingArchivedChats) {
            NavigationStack {
                ArchivedChatsView(model: model) { dialogId in
                    onOpen?(dialogId)
                    showingArchivedChats = false
                }
            }
        }
        .sheet(isPresented: $showingFolderManager) {
            NavigationStack { ChatFolderManagerView(model: model) }
        }
        .sheet(isPresented: $showingScheduledMessages) {
            NavigationStack { ScheduledMessagesView(model: model) }
        }
    }

    private var archivedChatsEntry: some View {
        Button {
            showingArchivedChats = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "archivebox.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(TojTheme.gold)
                    .frame(width: 44, height: 44)
                    .background(TojTheme.raised, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("Archived Chats")
                        .font(TojTheme.heading(.headline, weight: .semibold))
                        .foregroundStyle(TojTheme.text)
                    Text("\(archivedDialogs.count) archived chats")
                        .font(.subheadline)
                        .foregroundStyle(TojTheme.secondaryText)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(TojTheme.secondaryText)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(TojTheme.hairline)
                    .frame(height: 0.5)
                    .padding(.leading, 56)
            }
        }
        .buttonStyle(.tojPressable)
        .accessibilityIdentifier("archived-chats-entry")
    }

    /// Creates the controller once the coordinator is available, and keeps it fed.
    ///
    /// The controller owns debounce and cancellation, so the view only forwards state rather than
    /// deciding when to query.
    private func syncSearchController() async {
        await model.refreshSearchCoordinator()
        guard let store = model.searchStore, let coordinator = model.searchCoordinator else {
            searchController = nil
            return
        }
        if searchController == nil {
            searchController = MessageSearchController(
                backend: LocalMessageSearchBackend(store: store, coordinator: coordinator),
                dialogs: { model.dialogs }
            )
        }
        searchController?.query = query
        searchController?.scope = searchScope
    }

    private var searchDrawer: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(TojTheme.secondaryText)
            TextField("Search chats", text: $query)
                .focused($searchFocused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .accessibilityIdentifier("global-search-field")
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(TojTheme.secondaryText)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .font(.subheadline)
        .foregroundStyle(TojTheme.text)
        .padding(.horizontal, 14)
        .frame(height: 44)
        .tojGlass(in: Capsule(), interactive: true)
        .padding(.bottom, 8)
        .opacity(Double(searchDrawerRevealProgress))
        .scaleEffect(
            x: 1,
            y: 0.92 + (0.08 * searchDrawerRevealProgress),
            anchor: .top
        )
        .offset(y: -8 * (1 - searchDrawerRevealProgress))
        .allowsHitTesting(searchDrawerRevealProgress > 0.95)
    }

    private var searchDrawerRevealProgress: CGFloat {
        ChatSearchDrawerBehavior.revealProgress(
            at: searchScrollOffset,
            revealWasArmed: searchRevealWasArmed
        )
    }

    private func normalizedScrollOffset(_ geometry: ScrollGeometry) -> CGFloat {
        geometry.contentOffset.y + geometry.contentInsets.top
    }

    private func settleSearchDrawer(at offset: CGFloat, using proxy: ScrollViewProxy) {
        let clampedOffset = max(offset, 0)
        guard clampedOffset < ChatSearchDrawerBehavior.height else {
            isSearchDrawerOpen = false
            return
        }

        let shouldOpen = ChatSearchDrawerBehavior.shouldOpen(
            wasOpen: isSearchDrawerOpen,
            revealWasArmed: searchRevealWasArmed,
            offset: clampedOffset
        )

        isSearchDrawerOpen = shouldOpen
        if !shouldOpen {
            searchFocused = false
        }

        withAnimation(reduceMotion ? .easeOut(duration: 0.14) : .snappy(duration: 0.28, extraBounce: 0.08)) {
            proxy.scrollTo(shouldOpen ? "chat-search" : "chat-list-top", anchor: .top)
        }
    }

    @ViewBuilder
    private func dialogLink(_ dialog: CloudAppModel.Dialog) -> some View {
        Group {
            if isEditing, model.capabilities.contains(.chatOrganization) {
                Button {
                    if selectedDialogIds.contains(dialog.id) {
                        selectedDialogIds.remove(dialog.id)
                    } else {
                        selectedDialogIds.insert(dialog.id)
                    }
                    TojFeedback.selection()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: selectedDialogIds.contains(dialog.id) ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 23, weight: .semibold))
                            .foregroundStyle(selectedDialogIds.contains(dialog.id) ? TojTheme.gold : TojTheme.secondaryText)
                        CloudDialogRow(dialog: dialog, model: model)
                    }
                }
                .buttonStyle(.plain)
                .disabled(bulkActionInFlight)
                .accessibilityLabel(
                    selectedDialogIds.contains(dialog.id)
                        ? "Deselect \(dialog.title)"
                        : "Select \(dialog.title)"
                )
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            } else if let onOpen {
                Button { onOpen(dialog.id) } label: { CloudDialogRow(dialog: dialog, model: model) }
            } else {
                NavigationLink(value: dialog.id) { CloudDialogRow(dialog: dialog, model: model) }
            }
        }
        .buttonStyle(.tojPressable)
        .accessibilityIdentifier("chat-row-\(dialog.id)")
    }

    private var bulkActionBar: some View {
        HStack(spacing: 4) {
            bulkActionButton("Read", icon: "envelope.open.fill", action: .markRead)
            Menu {
                Button("Pin", systemImage: "pin.fill") { runBulkAction(.pin(true)) }
                Button("Unpin", systemImage: "pin.slash") { runBulkAction(.pin(false)) }
            } label: {
                bulkActionLabel("Pin", icon: "pin.fill")
            }
            .disabled(selectedDialogIds.isEmpty || bulkActionInFlight)

            Menu {
                Button("Mute", systemImage: "speaker.slash.fill") { runBulkAction(.mute(true)) }
                Button("Unmute", systemImage: "speaker.wave.2.fill") { runBulkAction(.mute(false)) }
            } label: {
                bulkActionLabel("Mute", icon: "speaker.slash.fill")
            }
            .disabled(selectedDialogIds.isEmpty || bulkActionInFlight)

            Menu {
                Button("Archive", systemImage: "archivebox.fill") { runBulkAction(.archive(true)) }
                Button("Unarchive", systemImage: "tray.and.arrow.up.fill") { runBulkAction(.archive(false)) }
            } label: {
                bulkActionLabel("Archive", icon: "archivebox.fill")
            }
            .disabled(selectedDialogIds.isEmpty || bulkActionInFlight)
        }
        .padding(.horizontal, 10)
        .padding(.top, 9)
        .padding(.bottom, 7)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Rectangle().fill(TojTheme.hairlineStrong).frame(height: 0.5)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Bulk chat actions, \(selectedDialogIds.count) selected")
    }

    private func bulkActionButton(
        _ title: LocalizedStringKey,
        icon: String,
        action: CloudAppModel.BulkDialogAction
    ) -> some View {
        Button { runBulkAction(action) } label: { bulkActionLabel(title, icon: icon) }
            .buttonStyle(.plain)
            .disabled(selectedDialogIds.isEmpty || bulkActionInFlight)
    }

    private func bulkActionLabel(_ title: LocalizedStringKey, icon: String) -> some View {
        VStack(spacing: 3) {
            if bulkActionInFlight {
                ProgressView().controlSize(.small).tint(TojTheme.gold)
            } else {
                Image(systemName: icon).font(.system(size: 16, weight: .semibold))
            }
            Text(title).font(.caption2.weight(.semibold))
        }
        .foregroundStyle(selectedDialogIds.isEmpty ? TojTheme.tertiaryText : TojTheme.text)
        .frame(maxWidth: .infinity, minHeight: 45)
        .contentShape(Rectangle())
    }

    private func runBulkAction(_ action: CloudAppModel.BulkDialogAction) {
        guard !selectedDialogIds.isEmpty, !bulkActionInFlight else { return }
        let selection = selectedDialogIds
        bulkActionInFlight = true
        Task {
            _ = await model.performBulkDialogAction(action, dialogIds: selection)
            guard !Task.isCancelled else { return }
            selectedDialogIds.removeAll()
            bulkActionInFlight = false
        }
    }

    private var emptyState: some View {
        let filtered = isSearching
        return VStack(spacing: 14) {
            TojMark(size: 66)
            Text(filtered ? "No results" : "No chats yet")
                .font(TojTheme.heading(.title3))
                .foregroundStyle(TojTheme.text)
            Text(filtered ? "Try another name, filter, or message." : "Start a private conversation with someone you know.")
                .font(.subheadline)
                .foregroundStyle(TojTheme.secondaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: 300)
    }
}

/// Failure states appear immediately, but transient checking/updating states must persist for a
/// beat before the banner interrupts the chrome — a healthy fast launch stays visually silent.
private struct QuietReplicaSyncBanner: View {
    let state: ReplicaSyncState
    let retry: () -> Void
    @State private var visible: Bool

    init(state: ReplicaSyncState, retry: @escaping () -> Void) {
        self.state = state
        self.retry = retry
        _visible = State(initialValue: !state.showsProgress)
    }

    var body: some View {
        // Keep a concrete host in the hierarchy while the banner is delayed. A conditional
        // Group can collapse to EmptyView, which prevents the state-driven task below from
        // observing a quick checking -> failure transition and leaves the failure hidden.
        VStack(spacing: 0) {
            if visible {
                ReplicaSyncBanner(state: state, retry: retry)
                    .padding(.top, 6)
                    .padding(.bottom, 4)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .task(id: state) {
            if !state.showsProgress {
                visible = true
            } else if !visible {
                try? await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled else { return }
                visible = true
            }
        }
    }
}

private struct ReplicaSyncBanner: View {
    let state: ReplicaSyncState
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if state.showsProgress {
                ProgressView()
                    .controlSize(.small)
                    .tint(TojTheme.gold)
            } else {
                Image(systemName: state.systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.orange)
            }
            Text(state.title)
                .font(.footnote.weight(.medium))
                .foregroundStyle(TojTheme.text)
                .lineLimit(1)
            Spacer(minLength: 8)
            if state.showsRetry {
                Button(action: retry) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .font(.footnote.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(TojTheme.gold)
            }
        }
        .padding(.horizontal, 13)
        .frame(minHeight: 44)
        .tojGlass(in: Capsule(), interactive: state.showsRetry)
    }
}

private struct ArchivedChatsView: View {
    @Bindable var model: CloudAppModel
    let onOpen: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    private var dialogs: [CloudAppModel.Dialog] {
        model.dialogs.filter(\.isArchived)
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if dialogs.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "archivebox")
                            .font(.system(size: 38, weight: .medium))
                            .foregroundStyle(TojTheme.secondaryText)
                        Text("No archived chats")
                            .font(TojTheme.heading(.title3))
                            .foregroundStyle(TojTheme.text)
                        Text("Chats you archive will stay available here.")
                            .font(.subheadline)
                            .foregroundStyle(TojTheme.secondaryText)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 100)
                } else {
                    ForEach(dialogs) { dialog in
                        Button {
                            onOpen(dialog.id)
                        } label: {
                            CloudDialogRow(dialog: dialog, model: model)
                        }
                        .buttonStyle(.tojPressable)
                        .contextMenu {
                            preferenceActions(for: dialog)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            if model.capabilities.contains(.chatOrganization) {
                                Button {
                                    model.unarchive(dialog.id)
                                } label: {
                                    Label("Unarchive", systemImage: "tray.and.arrow.up")
                                }
                                .tint(TojTheme.strong)
                                Button {
                                    model.toggleMuted(dialog.id)
                                } label: {
                                    Label(
                                        dialog.isMuted ? "Unmute" : "Mute",
                                        systemImage: dialog.isMuted ? "speaker.wave.2" : "speaker.slash"
                                    )
                                }
                                .tint(.gray)
                            }
                        }
                        .accessibilityIdentifier("archived-chat-row-\(dialog.id)")
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 26)
        }
        .background(TojTheme.canvas)
        .navigationTitle("Archived Chats")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Close") { dismiss() }
            }
        }
    }

    @ViewBuilder
    private func preferenceActions(for dialog: CloudAppModel.Dialog) -> some View {
        if model.capabilities.contains(.chatOrganization) {
            Button("Unarchive", systemImage: "tray.and.arrow.up") {
                model.unarchive(dialog.id)
            }
            Button(
                dialog.isPinned ? "Unpin" : "Pin",
                systemImage: dialog.isPinned ? "pin.slash" : "pin"
            ) {
                model.togglePinned(dialog.id)
            }
            Button(
                dialog.isMuted ? "Unmute" : "Mute",
                systemImage: dialog.isMuted ? "speaker.wave.2" : "speaker.slash"
            ) {
                model.toggleMuted(dialog.id)
            }
        }
    }
}

/// Shared with the search screen, which renders the same chat row so a result looks identical to
/// the list it came from.
struct CloudDialogRow: View {
    let dialog: CloudAppModel.Dialog
    var model: CloudAppModel = .shared

    var body: some View {
        HStack(spacing: 12) {
            CloudProfileAvatar(
                model: model,
                title: dialog.title,
                media: dialog.photo,
                size: 56,
                highlighted: false,
                colorIndex: dialog.profileColorIndex,
                systemImage: dialog.type == "saved" ? "bookmark.fill" : nil
            )
            .accessibilityIdentifier(dialog.type == "saved" ? "saved-messages-avatar" : "")

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(dialog.title)
                        .font(TojTheme.heading(.headline, weight: .semibold))
                        .foregroundStyle(TojTheme.text)
                        .lineLimit(1)
                    if dialog.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(TojTheme.secondaryText)
                    }
                    if dialog.isMuted && dialog.type != "saved" {
                        Image(systemName: "speaker.slash.fill")
                            .font(.caption2)
                            .foregroundStyle(TojTheme.secondaryText)
                    }
                    if dialog.isArchived {
                        Image(systemName: "archivebox.fill")
                            .font(.caption2)
                            .foregroundStyle(TojTheme.secondaryText)
                            .accessibilityLabel("Archived")
                    }
                }

                HStack(spacing: 5) {
                    if dialog.isPending {
                        ProgressView().controlSize(.mini).tint(TojTheme.secondaryText)
                    }
                    if let typing = model.typingSummary(dialogId: dialog.id) {
                        Text(typing)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(TojTheme.secure)
                            .lineLimit(1)
                    } else if let draft = dialog.draftPreview {
                        HStack(spacing: 3) {
                            Text("Draft:")
                                .foregroundStyle(Color.red)
                            Text(draft)
                                .foregroundStyle(TojTheme.secondaryText)
                        }
                            .lineLimit(1)
                    } else {
                        if dialog.lastMessageMine, !dialog.isPending {
                            Image(systemName: "checkmark")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(TojTheme.secure)
                        }
                        if let systemImage = dialog.previewKind.systemImage {
                            Image(systemName: systemImage)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(TojTheme.secondaryText)
                        }
                        Text(dialog.subtitle)
                            .foregroundStyle(TojTheme.secondaryText)
                            .lineLimit(1)
                    }
                }
                .font(.subheadline)
                .lineLimit(1)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 5) {
                Text(TojDateFormatting.chatList(dialog.updatedAt))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(dialog.unreadCount > 0 ? TojTheme.text : TojTheme.secondaryText)
                if dialog.unreadCount > 0 {
                    HStack(spacing: 4) {
                        if dialog.mentionCount > 0 {
                            Text("@")
                                .font(.caption2.bold())
                                .foregroundStyle(TojTheme.text)
                                .frame(width: 21, height: 21)
                                .background(TojTheme.strong, in: Circle())
                                .accessibilityLabel("Mentioned")
                        }
                        Text(dialog.unreadCount > 99 ? "99+" : "\(dialog.unreadCount)")
                            .font(.caption2.bold())
                            .foregroundStyle(dialog.isMuted ? TojTheme.secondaryText : TojTheme.onAccent)
                            .frame(minWidth: 21, minHeight: 21)
                            .padding(.horizontal, dialog.unreadCount > 99 ? 3 : 0)
                            .background(dialog.isMuted ? TojTheme.strong : TojTheme.accent, in: Capsule())
                            .contentTransition(.numericText())
                            .accessibilityLabel("\(dialog.unreadCount) unread messages")
                    }
                }
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens conversation. Long press for chat actions.")
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(TojTheme.hairline)
                .frame(height: 0.5)
                .padding(.leading, 68)
        }
    }
}

struct CloudProfileAvatar: View {
    @Bindable var model: CloudAppModel
    let title: String
    let media: CloudMedia?
    var size: CGFloat = 52
    var highlighted = false
    var colorIndex: Int? = nil
    var systemImage: String? = nil
    @State private var photoData: Data?

    var body: some View {
        TojAvatar(
            title: title,
            size: size,
            highlighted: highlighted,
            colorIndex: colorIndex,
            systemImage: systemImage,
            photoData: photoData
        )
        .task(id: media?.id) {
            photoData = nil
            guard let media else { return }
            photoData = await model.thumbnailData(for: media)
        }
        .onDisappear { photoData = nil }
    }
}

private struct NewChatSheet: View {
    @Bindable var model: CloudAppModel
    let contactsStore: TojContactsStore
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool
    @State private var showingGroupCreation = false
    let onOpened: (String) -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("New chat")
                        .font(TojTheme.heading(.title, weight: .bold))
                    Text("Enter the phone number of a Toj user.")
                        .font(.subheadline)
                        .foregroundStyle(TojTheme.secondaryText)
                }

                HStack(spacing: 10) {
                    Image(systemName: "phone.fill")
                        .foregroundStyle(TojTheme.secondaryText)
                    TextField("Phone number", text: $model.peerPhone)
                        .textContentType(.telephoneNumber)
                        .keyboardType(.phonePad)
                        .focused($focused)
                }
                .padding(.horizontal, 16)
                .frame(height: 54)
                .background(TojTheme.raised, in: Capsule())
                .overlay(Capsule().stroke(TojTheme.hairline, lineWidth: 0.5))

                if model.status == "No account found" || model.status.hasPrefix("Open chat failed") {
                    Text(model.status)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                Button {
                    Task {
                        if let dialogId = await model.openPeer() {
                            TojFeedback.sent()
                            onOpened(dialogId)
                        }
                    }
                } label: {
                    Text("Open chat")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 52)
                }
                .buttonStyle(.glassProminent)
                .tint(TojTheme.accent)
                .foregroundStyle(TojTheme.onAccent)
                .disabled(model.peerPhone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if model.capabilities.contains(.groups) {
                    Button { showingGroupCreation = true } label: {
                        Label("New group", systemImage: "person.3.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 50)
                    }
                    .buttonStyle(.glass)
                    .accessibilityHint("Choose contacts and create a group")
                }

                Spacer()
            }
            .padding(22)
            .background(TojTheme.canvas)
            .toolbar(.hidden, for: .navigationBar)
        }
        .onAppear { focused = true }
        .sheet(isPresented: $showingGroupCreation) {
            GroupCreationView(model: model, store: contactsStore) { dialogId in
                showingGroupCreation = false
                dismiss()
                onOpened(dialogId)
            }
        }
    }
}

// MARK: - Contacts and settings

private struct ComingSoonView: View {
    let title: LocalizedStringKey
    let systemImage: String
    let detail: LocalizedStringKey

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: systemImage)
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(TojTheme.gold)
                .frame(width: 78, height: 78)
                .background(TojTheme.raised, in: Circle())
                .overlay(Circle().stroke(TojTheme.hairlineStrong, lineWidth: 0.5))
            Text(title)
                .font(TojTheme.heading(.title, weight: .bold))
            Text("Coming soon")
                .font(.headline)
                .foregroundStyle(TojTheme.secondaryText)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(TojTheme.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TojTheme.canvas)
    }
}

private struct CloudSettingsView: View {
    @Bindable var model: CloudAppModel
    @Environment(TojAppearancePreferences.self) private var appearance
    @State private var showingSignOut = false
    @State private var pendingLogoutItemCount = 0
    @State private var showingDeletionWarning = false
    @State private var showingDeletionCode = false
    @State private var showingClearMedia = false
    @State private var showingProfileEditor = false
    @State private var profilePhotoData: Data?
    @State private var navigationPath: [String] = []

    private var displayName: String {
        let candidate = model.storedSession?.displayName.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return candidate.isEmpty ? String(localized: "Toj") : candidate
    }

    private var phone: String {
        model.storedSession?.phone ?? ""
    }

    private var profilePhotoAccountId: String? {
        model.storedSession?.session.accountId
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ScrollView {
                LazyVStack(spacing: 20) {
                    ZStack(alignment: .topTrailing) {
                        SettingsProfileCard(
                            displayName: displayName,
                            phone: phone,
                            photoData: profilePhotoData,
                            colorIndex: model.profileDetails.colorIndex
                        )

                        Button {
                            showingProfileEditor = true
                            TojFeedback.selection()
                        } label: {
                            Text("Edit")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(TojTheme.text)
                                .padding(.horizontal, 17)
                                .frame(height: 44)
                                .contentShape(Capsule())
                                .tojGlass(in: Capsule(), interactive: true)
                        }
                        .buttonStyle(.tojPressable)
                        .accessibilityHint("Opens your profile details")
                        .padding(.top, 4)
                    }
                    .padding(.top, 16)

                    profilePhotoSyncBanner

                    TojSectionCard {
                        Button(action: openSavedMessages) {
                            SettingsRowLabel(
                                title: "Saved Messages",
                                icon: "bookmark.fill",
                                colors: [Color(hex: 0x4B401F), Color(hex: 0x211D13)],
                                value: savedMessagesRowValue,
                                showsDivider: true
                            )
                        }
                        .buttonStyle(.tojPressable(scale: 0.985))
                        .disabled(model.savedMessagesSetupInFlight)
                        .accessibilityIdentifier("settings-saved-messages")
                        .accessibilityHint(
                            model.savedMessagesDialogId == nil
                                ? String(localized: "Sets up your private notes conversation")
                                : String(localized: "Opens your private notes conversation")
                        )
                        settingsLink(
                            title: "Recent Calls",
                            icon: "phone.fill",
                            colors: [Color(hex: 0x57DC7C), Color(hex: 0x27B85A)],
                            divider: true,
                            detail: "Your voice and video call history will live here."
                        )
                        NavigationLink {
                            SettingsDevicesView(model: model)
                        } label: {
                            SettingsRowLabel(
                                title: "Devices",
                                icon: "iphone.gen3",
                                colors: [Color(hex: 0xFFC85A), Color(hex: 0xF59B22)],
                                value: model.devices.isEmpty ? nil : "\(model.devices.count)",
                                showsDivider: false
                            )
                        }
                        .buttonStyle(.tojPressable(scale: 0.985))
                    }

                    TojSectionCard {
                        settingsLink(
                            title: "Notifications and Sounds",
                            icon: "bell.badge.fill",
                            colors: [Color(hex: 0xFF746D), Color(hex: 0xF04444)],
                            divider: true,
                            detail: "Fine-tuned alerts, tones and notification controls are on the way."
                        )
                        NavigationLink {
                            PrivacySecuritySettingsView(model: model)
                        } label: {
                            SettingsRowLabel(
                                title: "Privacy and Security",
                                icon: "lock.fill",
                                colors: [Color(hex: 0xC4C7CE), Color(hex: 0x858B96)],
                                value: nil,
                                showsDivider: true
                            )
                        }
                        .buttonStyle(.tojPressable(scale: 0.985))
                        NavigationLink {
                            DataStorageSettingsView(model: model)
                        } label: {
                            SettingsRowLabel(
                                title: "Data and Storage",
                                icon: "externaldrive.fill",
                                colors: [Color(hex: 0x55DE81), Color(hex: 0x22B95A)],
                                value: nil,
                                showsDivider: true
                            )
                        }
                        .buttonStyle(.tojPressable(scale: 0.985))
                        NavigationLink {
                            AppearanceSettingsView()
                        } label: {
                            SettingsRowLabel(
                                title: "Appearance",
                                icon: "circle.lefthalf.filled",
                                colors: [Color(hex: 0x61CCFF), Color(hex: 0x299DDA)],
                                value: appearance.wallpaper.title,
                                showsDivider: true
                            )
                        }
                        .buttonStyle(.tojPressable(scale: 0.985))
                        settingsLink(
                            title: "Power Saving",
                            icon: "battery.25percent",
                            colors: [Color(hex: 0xFFC85C), Color(hex: 0xF49A22)],
                            value: "Off",
                            divider: true,
                            detail: "Power-saving controls will help Toj use less energy."
                        )
                        NavigationLink {
                            LanguageSettingsView()
                        } label: {
                            SettingsRowLabel(
                                title: "Language",
                                icon: "globe",
                                colors: [Color(hex: 0xCE70F4), Color(hex: 0x9D43D7)],
                                value: LocalizedStringKey(appearance.language.title),
                                showsDivider: false
                            )
                        }
                        .buttonStyle(.tojPressable(scale: 0.985))
                    }

                    TojSectionCard("Call privacy") {
                        Toggle(isOn: Binding(
                            get: { model.callPreferences.hidesIPAddress },
                            set: { model.callPreferences.hidesIPAddress = $0 }
                        )) {
                            VStack(alignment: .leading, spacing: 3) {
                                Label("Hide IP address in calls", systemImage: "network.badge.shield.half.filled")
                                    .font(.body.weight(.medium))
                                Text("Routes calls through Toj relays. This improves privacy but may add latency.")
                                    .font(.caption)
                                    .foregroundStyle(TojTheme.secondaryText)
                            }
                        }
                        .tint(TojTheme.secure)
                        .padding(.horizontal, 15)
                        .frame(minHeight: 68)
                        .disabled(model.callCoordinator.state.isInProgress)

                        Divider()
                            .overlay(Color.white.opacity(0.08))
                            .padding(.leading, 15)

                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Label("Use less data for video calls", systemImage: "antenna.radiowaves.left.and.right")
                                    .font(.body.weight(.medium))
                                Text("Audio always has priority. Low Data Mode and roaming use the lowest video tier.")
                                    .font(.caption)
                                    .foregroundStyle(TojTheme.secondaryText)
                            }
                            Spacer(minLength: 8)
                            Picker("Video call data usage", selection: Binding(
                                get: { model.callPreferences.dataUsagePolicy },
                                set: { model.callPreferences.dataUsagePolicy = $0 }
                            )) {
                                Text("Never").tag(CallDataUsagePolicy.never)
                                Text("Cellular Only").tag(CallDataUsagePolicy.cellularOnly)
                                Text("Always").tag(CallDataUsagePolicy.always)
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                        }
                        .padding(.horizontal, 15)
                        .frame(minHeight: 78)
                        .disabled(model.callCoordinator.state.isInProgress)
                    }

                    TojSectionCard("Info") {
                        settingsLink(
                            title: "Ask a Question",
                            icon: "questionmark.bubble.fill",
                            colors: [Color(hex: 0xFFC254), Color(hex: 0xF39A1E)],
                            divider: true,
                            detail: "A direct line to Toj support is coming soon."
                        )
                        settingsLink(
                            title: "Toj FAQ",
                            icon: "questionmark.circle.fill",
                            colors: [Color(hex: 0x63CFFF), Color(hex: 0x2D9FDC)],
                            divider: true,
                            detail: "Helpful answers and guides are being written now."
                        )
                        settingsLink(
                            title: "Toj Features",
                            icon: "lightbulb.fill",
                            colors: [Color(hex: 0xFFE95B), Color(hex: 0xF1BC19)],
                            divider: false,
                            detail: "Discover everything Toj can do as new features arrive."
                        )
                    }

                    TojSectionCard("Storage and account") {
                        SettingsAction(
                            title: model.clearingMediaCache
                                ? "Clearing downloaded media…"
                                : "Clear downloaded media",
                            systemImage: "externaldrive.badge.xmark",
                            value: ByteCountFormatter.string(fromByteCount: model.mediaCacheBytes, countStyle: .file),
                            showsDivider: true
                        ) {
                            showingClearMedia = true
                        }
                        SettingsAction(
                            title: "Sign out",
                            systemImage: "rectangle.portrait.and.arrow.right",
                            showsDivider: true
                        ) {
                            Task {
                                pendingLogoutItemCount = await model.pendingDestructiveLogoutItemCount()
                                showingSignOut = true
                            }
                        }
                        SettingsAction(
                            title: "Delete account",
                            systemImage: "trash.fill",
                            destructive: true,
                            showsDivider: false
                        ) {
                            showingDeletionWarning = true
                        }
                    }

                    #if DEBUG
                    if model.isDemoMode {
                        TojSectionCard("Design preview") {
                            NavigationLink {
                                PresentationStateGallery()
                            } label: {
                                HStack(spacing: 13) {
                                    TojIconTile(systemImage: "rectangle.3.group.fill")
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Interface state gallery")
                                            .font(.body.weight(.medium))
                                        Text("Loading, offline, media and call fixtures")
                                            .font(.caption)
                                            .foregroundStyle(TojTheme.secondaryText)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption.bold())
                                        .foregroundStyle(TojTheme.secondaryText)
                                }
                                .foregroundStyle(TojTheme.text)
                                .padding(.horizontal, 15)
                                .frame(minHeight: 58)
                            }
                            .buttonStyle(.tojPressable)
                        }
                    }
                    #endif
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 28)
            }
            .background(TojTheme.canvas)
            .navigationDestination(for: String.self) { dialogId in
                TojConversationExperience(model: model, dialogId: dialogId)
            }
            .toolbar(.hidden, for: .navigationBar)
            .task(id: profilePhotoAccountId) {
                await model.loadDevices()
                await model.loadProfileDetails()
                await model.refreshMediaCacheUsage()
                if let accountId = profilePhotoAccountId {
                    profilePhotoData = await EncryptedProfilePhotoStore.load(accountId: accountId)
                    if let cloudData = model.profilePhotoDisplayData {
                        profilePhotoData = cloudData
                    }
                } else {
                    profilePhotoData = nil
                }
                #if DEBUG
                if ProcessInfo.processInfo.environment["TOJ_DEMO_PROFILE_EDIT"] == "1" {
                    showingProfileEditor = true
                }
                #endif
            }
            .onChange(of: model.profilePhotoDisplayData) { _, value in
                profilePhotoData = value
            }
            .confirmationDialog(
                pendingLogoutItemCount > 0
                    ? "Discard pending work and sign out?"
                    : "Sign out of Toj?",
                isPresented: $showingSignOut,
                titleVisibility: .visible
            ) {
                Button(
                    pendingLogoutItemCount > 0
                        ? "Discard \(pendingLogoutItemCount) pending item\(pendingLogoutItemCount == 1 ? "" : "s")"
                        : "Sign out",
                    role: .destructive
                ) { Task { await model.signOut() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                if pendingLogoutItemCount > 0 {
                    Text("Pending messages, edits, chat settings, or uploads have not reached the cloud and will be permanently removed from this device.")
                } else {
                    Text("Your encrypted local replica and downloaded media will be removed from this device.")
                }
            }
            .confirmationDialog("Delete your Toj account?", isPresented: $showingDeletionWarning, titleVisibility: .visible) {
                Button("Request deletion code", role: .destructive) {
                    Task {
                        if await model.requestAccountDeletionCode() { showingDeletionCode = true }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your identifying account data will be erased. Delivered messages remain in other participants’ chat history.")
            }
            .confirmationDialog("Clear downloaded media?", isPresented: $showingClearMedia, titleVisibility: .visible) {
                Button("Clear media", role: .destructive) { Task { await model.clearMediaCache() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Pending uploads stay protected. Sent photos, videos, files and voice notes download again when opened.")
            }
            .sheet(isPresented: $showingDeletionCode) {
                AccountDeletionView(model: model)
            }
            .fullScreenCover(isPresented: $showingProfileEditor) {
                ProfileEditView(
                    model: model,
                    persistedPhotoData: $profilePhotoData,
                    photoAccountId: profilePhotoAccountId
                )
                .presentationBackground(TojTheme.canvas)
            }
        }
    }

    @ViewBuilder
    private var profilePhotoSyncBanner: some View {
        switch model.profilePhotoSyncState {
        case .pending:
            profilePhotoBanner(
                title: "Profile photo waiting to sync",
                systemImage: "arrow.triangle.2.circlepath.icloud",
                tint: TojTheme.secondaryText
            )
            .accessibilityIdentifier("profile-photo-sync-pending")
        case let .failed(message):
            VStack(alignment: .leading, spacing: 10) {
                profilePhotoBanner(
                    title: message,
                    systemImage: "exclamationmark.icloud.fill",
                    tint: TojTheme.danger
                )
                HStack(spacing: 18) {
                    Button("Retry") { Task { await model.retryProfilePhoto() } }
                    Button("Discard", role: .destructive) {
                        Task { await model.discardPendingProfilePhoto() }
                    }
                }
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 16)
            }
            .padding(.vertical, 12)
            .background(TojTheme.raised, in: RoundedRectangle(cornerRadius: TojRadius.card))
            .accessibilityIdentifier("profile-photo-sync-failed")
        case .conflict:
            VStack(alignment: .leading, spacing: 10) {
                profilePhotoBanner(
                    title: "Profile photo changed on another device",
                    systemImage: "arrow.triangle.branch",
                    tint: TojTheme.accent
                )
                HStack(spacing: 18) {
                    Button("Use cloud photo") { Task { await model.useCloudProfilePhoto() } }
                    Button("Use mine") { Task { await model.retryProfilePhoto() } }
                }
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 16)
            }
            .padding(.vertical, 12)
            .background(TojTheme.raised, in: RoundedRectangle(cornerRadius: TojRadius.card))
            .accessibilityIdentifier("profile-photo-sync-conflict")
        case .localOnly, .synced:
            EmptyView()
        }
    }

    private func profilePhotoBanner(
        title: String,
        systemImage: String,
        tint: Color
    ) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
    }

    private var savedMessagesRowValue: LocalizedStringKey? {
        if model.savedMessagesSetupInFlight { return "Setting up…" }
        if let failure = model.savedMessagesSetupFailure {
            return LocalizedStringKey(failure)
        }
        if model.savedMessagesDialogId == nil {
            switch model.savedMessagesCapabilityState {
            case .unknown:
                return "Connect to set up"
            case .unsupported:
                return "Unavailable"
            case .supported:
                break
            }
        }
        return nil
    }

    private func openSavedMessages() {
        if let dialogId = model.savedMessagesDialogId {
            model.prepareConversationOpen(dialogId: dialogId)
            navigationPath.append(dialogId)
            return
        }
        Task {
            guard let dialogId = await model.ensureSavedMessages() else { return }
            model.prepareConversationOpen(dialogId: dialogId)
            if navigationPath.last != dialogId {
                navigationPath.append(dialogId)
            }
        }
    }

    @ViewBuilder
    private func settingsLink(
        title: LocalizedStringKey,
        icon: String,
        colors: [Color],
        value: LocalizedStringKey? = nil,
        divider: Bool,
        detail: LocalizedStringKey
    ) -> some View {
        NavigationLink {
            SettingsComingSoonView(title: title, systemImage: icon, colors: colors, detail: detail)
        } label: {
            SettingsRowLabel(
                title: title,
                icon: icon,
                colors: colors,
                value: value,
                showsDivider: divider
            )
        }
        .buttonStyle(.tojPressable(scale: 0.985))
    }

}

private struct SettingsProfileCard: View {
    let displayName: String
    let phone: String
    let photoData: Data?
    let colorIndex: Int

    var body: some View {
        VStack(spacing: 14) {
            SettingsProfileAvatar(
                displayName: displayName,
                photoData: photoData,
                size: 94,
                colorIndex: colorIndex
            )
                .shadow(color: TojProfilePalette.primary(colorIndex).opacity(0.18), radius: 26, y: 12)

            VStack(spacing: 4) {
                Text(displayName)
                    .font(TojTheme.heading(.title2, weight: .bold))
                    .foregroundStyle(TojTheme.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                Text(phone)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(TojTheme.secondaryText)
                    .contentTransition(.numericText())
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
        .padding(.bottom, 10)
        .padding(.horizontal, 18)
        .accessibilityElement(children: .combine)
    }
}

struct SettingsProfileAvatar: View {
    let displayName: String
    let photoData: Data?
    let size: CGFloat
    let colorIndex: Int

    var body: some View {
        Group {
            if let photoData, let image = UIImage(data: photoData) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            } else {
                ZStack {
                    Circle()
                        .fill(
                            TojProfilePalette.gradient(colorIndex)
                        )
                    Text(displayName.trimmingCharacters(in: .whitespacesAndNewlines).first.map { String($0).uppercased() } ?? "T")
                        .font(TojTheme.heading(.largeTitle, weight: .medium))
                        .foregroundStyle(.white)
                }
                .frame(width: size, height: size)
            }
        }
        .overlay(Circle().stroke(Color.white.opacity(0.16), lineWidth: 1))
        .accessibilityHidden(true)
    }
}

struct SettingsIconTile: View {
    let systemImage: String
    let colors: [Color]
    var size: CGFloat = 34

    var body: some View {
        Image(systemName: systemImage)
            .symbolRenderingMode(.monochrome)
            .font(.system(size: size * 0.48, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: size * 0.29, style: .continuous)
            )
            .overlay(RoundedRectangle(cornerRadius: size * 0.29, style: .continuous).stroke(Color.white.opacity(0.16), lineWidth: 0.5))
            .shadow(color: (colors.last ?? .clear).opacity(0.16), radius: 7, y: 3)
            .accessibilityHidden(true)
    }
}

private struct SettingsRowLabel: View {
    let title: LocalizedStringKey
    let icon: String
    let colors: [Color]
    var value: LocalizedStringKey? = nil
    let showsDivider: Bool

    var body: some View {
        HStack(spacing: 14) {
            SettingsIconTile(systemImage: icon, colors: colors)
            Text(title)
                .font(.body.weight(.medium))
                .foregroundStyle(TojTheme.text)
                .lineLimit(1)
            Spacer(minLength: 10)
            if let value {
                Text(value)
                    .font(.body)
                    .foregroundStyle(TojTheme.secondaryText)
                    .lineLimit(1)
            }
            Image(systemName: "chevron.right")
                .font(.caption.bold())
                .foregroundStyle(TojTheme.tertiaryText)
        }
        .padding(.horizontal, 15)
        .frame(minHeight: 58)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            if showsDivider {
                Rectangle()
                    .fill(TojTheme.hairlineStrong)
                    .frame(height: 0.5)
                    .padding(.leading, 63)
            }
        }
    }
}

private struct SettingsComingSoonView: View {
    let title: LocalizedStringKey
    let systemImage: String
    let colors: [Color]
    let detail: LocalizedStringKey
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animated = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            ZStack {
                Circle()
                    .fill((colors.last ?? TojTheme.accent).opacity(0.14))
                    .frame(width: 156, height: 156)
                    .blur(radius: animated ? 18 : 8)
                    .scaleEffect(animated ? 1.08 : 0.9)
                SettingsIconTile(systemImage: systemImage, colors: colors, size: 82)
                    .shadow(color: (colors.last ?? .clear).opacity(0.28), radius: 28, y: 14)
            }
            .padding(.bottom, 30)

            Text(title)
                .font(TojTheme.heading(.title, weight: .bold))
                .foregroundStyle(TojTheme.text)
                .multilineTextAlignment(.center)
            Text("Coming soon")
                .font(.headline.weight(.semibold))
                .foregroundStyle(colors.first ?? TojTheme.accent)
                .padding(.top, 8)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(TojTheme.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
                .padding(.top, 10)
            Spacer()
            Text("We’re making it worth the wait.")
                .font(.caption.weight(.medium))
                .foregroundStyle(TojTheme.tertiaryText)
                .padding(.bottom, 28)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TojTheme.canvas)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                animated = true
            }
        }
    }
}

private struct PrivacySecuritySettingsView: View {
    @Bindable var model: CloudAppModel
    @State private var appLock = AppLockController.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                VStack(spacing: 10) {
                    SettingsIconTile(
                        systemImage: "lock.shield.fill",
                        colors: [Color(hex: 0xC4C7CE), Color(hex: 0x858B96)],
                        size: 72
                    )
                    Text("Privacy and Security")
                        .font(TojTheme.heading(.title2, weight: .bold))
                    Text("Control local access to this device, protect sign-in with a password, and review active sessions.")
                        .font(.subheadline)
                        .foregroundStyle(TojTheme.secondaryText)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 340)
                }
                .padding(.vertical, 18)

                TojSectionCard("App Lock") {
                    Toggle(isOn: Binding(
                        get: { appLock.isEnabled },
                        set: { enabled in
                            Task { _ = await appLock.setEnabled(enabled) }
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Require device authentication")
                                .font(.body.weight(.medium))
                            Text("Use Face ID, Touch ID, or your device passcode.")
                                .font(.caption)
                                .foregroundStyle(TojTheme.secondaryText)
                        }
                    }
                    .tint(TojTheme.secure)
                    .padding(.horizontal, 15)
                    .frame(minHeight: 68)
                    .disabled(appLock.authenticationInFlight)

                    if appLock.isEnabled {
                        Divider()
                            .overlay(TojTheme.hairlineStrong)
                            .padding(.leading, 15)
                        HStack {
                            Text("Auto-lock")
                                .font(.body.weight(.medium))
                            Spacer()
                            Menu(appLock.timeout.title) {
                                ForEach(AppLockTimeout.allCases) { timeout in
                                    Button {
                                        Task { _ = await appLock.setTimeout(timeout) }
                                    } label: {
                                        if appLock.timeout == timeout {
                                            Label(timeout.title, systemImage: "checkmark")
                                        } else {
                                            Text(timeout.title)
                                        }
                                    }
                                }
                            }
                            .disabled(appLock.authenticationInFlight)
                        }
                        .padding(.horizontal, 15)
                        .frame(minHeight: 58)
                    }
                }

                Text("App Lock protects against casual access on this device. It does not add message encryption or stop background sync, notifications, and calls.")
                    .font(.caption)
                    .foregroundStyle(TojTheme.secondaryText)
                    .padding(.horizontal, 8)

                TojSectionCard("Account protection") {
                    NavigationLink {
                        TwoFactorSettingsView(model: model)
                    } label: {
                        SettingsRowLabel(
                            title: "Two-Step Verification",
                            icon: "key.fill",
                            colors: model.twoFactorEnabled
                                ? [Color(hex: 0x55DE81), Color(hex: 0x22B95A)]
                                : [Color(hex: 0x727986), Color(hex: 0x414752)],
                            value: model.twoFactorEnabled ? "On" : "Off",
                            showsDivider: true
                        )
                    }
                    .buttonStyle(.tojPressable(scale: 0.985))

                    NavigationLink {
                        SettingsDevicesView(model: model)
                    } label: {
                        SettingsRowLabel(
                            title: "Active Sessions",
                            icon: "iphone.gen3",
                            colors: [Color(hex: 0xFFC85A), Color(hex: 0xF59B22)],
                            value: model.devices.isEmpty ? nil : "\(model.devices.count)",
                            showsDivider: false
                        )
                    }
                    .buttonStyle(.tojPressable(scale: 0.985))
                }

                if let error = appLock.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(16)
            .padding(.bottom, 24)
        }
        .background(TojTheme.canvas)
        .navigationTitle("Privacy and Security")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await model.loadTwoFactorStatus()
            await model.loadDevices()
        }
    }
}

private struct TwoFactorSettingsView: View {
    @Bindable var model: CloudAppModel
    @State private var stage: Stage = .overview
    @State private var password = ""
    @State private var confirmation = ""
    @State private var currentCredential = ""

    private enum Stage {
        case overview
        case code
        case configure
        case regenerate
        case disable
    }

    private var validPassword: Bool {
        password.count >= 8 && password.count <= 128 && password == confirmation
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                VStack(spacing: 10) {
                    SettingsIconTile(
                        systemImage: model.twoFactorEnabled ? "checkmark.shield.fill" : "key.fill",
                        colors: model.twoFactorEnabled
                            ? [Color(hex: 0x55DE81), Color(hex: 0x22B95A)]
                            : [Color(hex: 0x727986), Color(hex: 0x414752)],
                        size: 72
                    )
                    Text(model.twoFactorEnabled ? "Two-Step Verification is on" : "Add a sign-in password")
                        .font(TojTheme.heading(.title2, weight: .bold))
                        .multilineTextAlignment(.center)
                    Text("Your SMS code is always checked first. The password protects creation of every new device session.")
                        .font(.subheadline)
                        .foregroundStyle(TojTheme.secondaryText)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 340)
                }
                .padding(.vertical, 18)

                switch stage {
                case .overview:
                    overview
                case .code:
                    securityCodeEntry
                case .configure:
                    passwordConfiguration
                case .regenerate:
                    recoveryCodeRegeneration
                case .disable:
                    disableConfirmation
                }
            }
            .padding(16)
            .padding(.bottom, 24)
        }
        .background(TojTheme.canvas)
        .navigationTitle("Two-Step Verification")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.loadTwoFactorStatus() }
    }

    private var overview: some View {
        VStack(spacing: 18) {
            if model.twoFactorEnabled {
                TojSectionCard("Recovery") {
                    HStack {
                        Label("Unused recovery codes", systemImage: "number.square.fill")
                        Spacer()
                        Text("\(model.twoFactorRecoveryCodesRemaining)")
                            .foregroundStyle(TojTheme.secondaryText)
                    }
                    .padding(.horizontal, 15)
                    .frame(minHeight: 58)
                }
            }

            Button(model.twoFactorEnabled ? "Change password and replace codes" : "Set up two-step verification") {
                beginStepUp(next: .configure)
            }
            .buttonStyle(.borderedProminent)
            .tint(TojTheme.gold)
            .frame(maxWidth: .infinity)

            if model.twoFactorEnabled {
                Button("Replace recovery codes") {
                    beginStepUp(next: .regenerate)
                }
                .buttonStyle(.bordered)

                Button("Turn off two-step verification", role: .destructive) {
                    beginStepUp(next: .disable)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var securityCodeEntry: some View {
        VStack(spacing: 16) {
            Text("Enter the fresh six-digit code sent to your phone.")
                .font(.subheadline)
                .foregroundStyle(TojTheme.secondaryText)
                .multilineTextAlignment(.center)
            TextField("6-digit code", text: $model.securityCode)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .multilineTextAlignment(.center)
                .font(.title2.monospacedDigit().weight(.semibold))
                .padding(.horizontal, 17)
                .frame(height: 56)
                .background(TojTheme.raised, in: Capsule())
            Button("Verify code") {
                Task {
                    if await model.verifySecurityChangeCode() {
                        stage = pendingStage
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(TojTheme.gold)
            .disabled(model.securityCode.filter(\.isNumber).count != 6 || model.securityChangeInFlight)
            Button("Send a new code") {
                Task { _ = await model.requestSecurityChangeCode() }
            }
            .disabled(model.securityChangeInFlight)
        }
    }

    private var passwordConfiguration: some View {
        VStack(spacing: 14) {
            if model.twoFactorEnabled {
                SecureField("Current password or recovery code", text: $currentCredential)
                    .textContentType(.password)
                    .tojSecurityField()
            }
            SecureField("New password", text: $password)
                .textContentType(.newPassword)
                .tojSecurityField()
            SecureField("Confirm new password", text: $confirmation)
                .textContentType(.newPassword)
                .tojSecurityField()
            Text("Use 8–128 characters. Spaces are kept exactly as entered. Ten new one-time recovery codes will be shown once.")
                .font(.caption)
                .foregroundStyle(TojTheme.secondaryText)
            Button(model.twoFactorEnabled ? "Update protection" : "Enable two-step verification") {
                Task {
                    let saved = await model.saveTwoFactor(
                        password: password,
                        currentCredential: model.twoFactorEnabled ? currentCredential : nil
                    )
                    if saved { stage = .overview }
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(TojTheme.gold)
            .disabled(!validPassword || (model.twoFactorEnabled && currentCredential.isEmpty) || model.securityChangeInFlight)
        }
    }

    private var disableConfirmation: some View {
        VStack(spacing: 14) {
            Text("Enter your current password or an unused recovery code. Other sessions will be signed out.")
                .font(.subheadline)
                .foregroundStyle(TojTheme.secondaryText)
                .multilineTextAlignment(.center)
            SecureField("Password or recovery code", text: $currentCredential)
                .textContentType(.password)
                .tojSecurityField()
            Button("Turn off two-step verification", role: .destructive) {
                Task {
                    if await model.disableTwoFactor(currentCredential: currentCredential) {
                        stage = .overview
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(TojTheme.danger)
            .disabled(currentCredential.isEmpty || model.securityChangeInFlight)
        }
    }

    private var recoveryCodeRegeneration: some View {
        VStack(spacing: 14) {
            Text("Enter your current password or an unused recovery code. Every old recovery code will stop working and other sessions will be signed out.")
                .font(.subheadline)
                .foregroundStyle(TojTheme.secondaryText)
                .multilineTextAlignment(.center)
            SecureField("Password or recovery code", text: $currentCredential)
                .textContentType(.password)
                .tojSecurityField()
            Button("Replace recovery codes") {
                Task {
                    if await model.regenerateTwoFactorRecoveryCodes(
                        currentCredential: currentCredential
                    ) {
                        stage = .overview
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(TojTheme.gold)
            .disabled(currentCredential.isEmpty || model.securityChangeInFlight)
        }
    }

    @State private var pendingStage: Stage = .configure

    private func beginStepUp(next: Stage) {
        pendingStage = next
        Task {
            if await model.requestSecurityChangeCode() {
                stage = .code
            }
        }
    }
}

private extension View {
    func tojSecurityField() -> some View {
        padding(.horizontal, 17)
            .frame(height: 56)
            .background(TojTheme.raised, in: Capsule())
    }
}

private struct RecoveryCodesView: View {
    let codes: [String]
    let onDone: () -> Void
    @State private var acknowledged = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    Image(systemName: "key.viewfinder")
                        .font(.system(size: 38, weight: .semibold))
                        .foregroundStyle(TojTheme.gold)
                        .frame(width: 82, height: 82)
                        .background(TojTheme.raised, in: Circle())
                    Text("Save your recovery codes")
                        .font(TojTheme.heading(.title2, weight: .bold))
                    Text("Each code works once after SMS verification. Keep them offline; Toj cannot show this batch again.")
                        .font(.subheadline)
                        .foregroundStyle(TojTheme.secondaryText)
                        .multilineTextAlignment(.center)

                    VStack(spacing: 0) {
                        ForEach(Array(codes.enumerated()), id: \.offset) { index, code in
                            Text(code)
                                .font(.body.monospaced().weight(.semibold))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, minHeight: 42)
                            if index < codes.count - 1 { Divider().overlay(TojTheme.hairline) }
                        }
                    }
                    .padding(.horizontal, 14)
                    .background(TojTheme.raised, in: RoundedRectangle(cornerRadius: 20))

                    ShareLink(item: codes.joined(separator: "\n")) {
                        Label("Save or share codes", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.bordered)

                    Toggle("I saved these recovery codes", isOn: $acknowledged)
                        .tint(TojTheme.secure)
                        .font(.subheadline.weight(.medium))

                    Button("Done", action: onDone)
                        .buttonStyle(.borderedProminent)
                        .tint(TojTheme.gold)
                        .disabled(!acknowledged)
                }
                .padding(22)
            }
            .background(TojTheme.canvas)
            .navigationTitle("Recovery Codes")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct SettingsDevicesView: View {
    @Bindable var model: CloudAppModel

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                VStack(spacing: 10) {
                    SettingsIconTile(
                        systemImage: "iphone.gen3",
                        colors: [Color(hex: 0xFFC85A), Color(hex: 0xF59B22)],
                        size: 72
                    )
                    Text("Active sessions")
                        .font(TojTheme.heading(.title2, weight: .bold))
                    Text("Review the devices signed in to your Toj account. You can end any session you don’t recognize.")
                        .font(.subheadline)
                        .foregroundStyle(TojTheme.secondaryText)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)
                }
                .padding(.vertical, 18)

                TojSectionCard("Devices") {
                    if model.loadingDevices && model.devices.isEmpty {
                        ProgressView("Loading devices")
                            .frame(maxWidth: .infinity)
                            .padding(24)
                    } else if model.devices.isEmpty {
                        Label("No active devices", systemImage: "iphone.slash")
                            .foregroundStyle(TojTheme.secondaryText)
                            .frame(maxWidth: .infinity)
                            .padding(24)
                    } else {
                        ForEach(Array(model.devices.enumerated()), id: \.element.id) { index, device in
                            DeviceRow(device: device, showsDivider: index < model.devices.count - 1) {
                                Task { await model.revokeDevice(device) }
                            }
                        }
                    }
                }
            }
            .padding(16)
            .padding(.bottom, 24)
        }
        .background(TojTheme.canvas)
        .navigationTitle("Devices")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await model.loadDevices() }
        .task { await model.loadDevices() }
    }
}

private struct DeviceRow: View {
    let device: CloudDevice
    var showsDivider = true
    let revoke: () -> Void

    var body: some View {
        HStack(spacing: 13) {
            TojIconTile(systemImage: device.platform == "ios" ? "iphone" : "desktopcomputer", tint: device.current ? TojTheme.secure : nil)
            VStack(alignment: .leading, spacing: 3) {
                Text(device.deviceName.flatMap { $0.isEmpty ? nil : $0 } ?? device.platform.capitalized)
                    .font(.subheadline.weight(.semibold))
                Text(device.current ? "This device" : TojDateFormatting.lastSeen(device.lastSeenAt ?? device.createdAt))
                    .font(.caption)
                    .foregroundStyle(device.current ? TojTheme.secure : TojTheme.secondaryText)
                if let expiresAt = device.sessionExpiresAt {
                    Text("Session expires \(TojDateFormatting.lastSeen(expiresAt))")
                        .font(.caption2)
                        .foregroundStyle(TojTheme.tertiaryText)
                }
            }
            Spacer()
            if !device.current {
                Button("Sign out", role: .destructive, action: revoke)
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.tojPressable)
            }
        }
        .padding(13)
        .overlay(alignment: .bottom) {
            if showsDivider {
                Rectangle().fill(TojTheme.hairline).frame(height: 0.5).padding(.leading, 62)
            }
        }
    }
}

private struct SettingsAction: View {
    let title: String
    let systemImage: String
    var value: String? = nil
    var destructive = false
    var showsDivider = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                SettingsIconTile(
                    systemImage: systemImage,
                    colors: destructive
                        ? [Color(hex: 0xFF746D), Color(hex: 0xE33E3E)]
                        : [Color(hex: 0x727986), Color(hex: 0x414752)]
                )
                Text(title)
                Spacer(minLength: 10)
                if let value {
                    Text(value)
                        .font(.body)
                        .foregroundStyle(TojTheme.secondaryText)
                }
            }
            .font(.body.weight(.medium))
            .foregroundStyle(destructive ? TojTheme.danger : TojTheme.text)
            .padding(.horizontal, 15)
            .frame(minHeight: 58)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                if showsDivider {
                    Rectangle()
                        .fill(TojTheme.hairlineStrong)
                        .frame(height: 0.5)
                        .padding(.leading, 63)
                }
            }
        }
        .buttonStyle(.tojPressable(scale: 0.985))
    }
}

private struct AccountDeletionView: View {
    @Bindable var model: CloudAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var showingFinalConfirmation = false
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                Text("Verify deletion")
                    .font(TojTheme.heading(.title, weight: .bold))
                Text("Enter the fresh six-digit code. This action cannot be undone.")
                    .font(.subheadline)
                    .foregroundStyle(TojTheme.secondaryText)

                TextField("6-digit code", text: $model.accountDeletionCode)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .focused($focused)
                    .padding(.horizontal, 17)
                    .frame(height: 56)
                    .background(TojTheme.raised, in: Capsule())

                Button("Request new code") {
                    Task { _ = await model.requestAccountDeletionCode() }
                }
                .disabled(model.accountDeletionInFlight)

                Button(role: .destructive) { showingFinalConfirmation = true } label: {
                    Text("Permanently delete account")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 54)
                }
                .buttonStyle(.glassProminent)
                .tint(.red)
                .disabled(model.accountDeletionInFlight || model.accountDeletionCode.filter(\.isNumber).count != 6)

                if model.accountDeletionInFlight {
                    ProgressView("Deleting account")
                }
                Spacer()
            }
            .padding(22)
            .background(TojTheme.canvas)
            .navigationTitle("Delete account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        model.cancelAccountDeletion()
                        dismiss()
                    }
                }
            }
            .alert("Permanently delete account?", isPresented: $showingFinalConfirmation) {
                Button("Delete forever", role: .destructive) {
                    Task { if await model.deleteAccount() { dismiss() } }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("All devices will be signed out and your identifying account data will be erased.")
            }
            .interactiveDismissDisabled(model.accountDeletionInFlight)
            .onAppear { focused = true }
            .onChange(of: model.storedSession == nil) { _, signedOut in if signedOut { dismiss() } }
            .onDisappear { model.cancelAccountDeletion() }
        }
    }
}

// MARK: - Formatting

enum TojDateFormatting {
    private static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoPlain = ISO8601DateFormatter()

    static func date(_ raw: String) -> Date? {
        isoFractional.date(from: raw) ?? isoPlain.date(from: raw)
    }

    static func chatList(_ raw: String) -> String {
        guard let date = date(raw) else { return "" }
        if Calendar.current.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if let days = Calendar.current.dateComponents([.day], from: date, to: Date()).day, days < 7 {
            return date.formatted(.dateTime.weekday(.abbreviated))
        }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    static func message(_ raw: String) -> String {
        date(raw)?.formatted(date: .omitted, time: .shortened) ?? ""
    }

    /// Media-viewer subtitle, e.g. "today at 02:49" / "yesterday at 14:11" / "14 Jul at 09:03".
    static func mediaTimestamp(_ raw: String) -> String {
        guard let date = date(raw) else { return "" }
        let time = date.formatted(date: .omitted, time: .shortened)
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return String(localized: "today at \(time)")
        }
        if calendar.isDateInYesterday(date) {
            return String(localized: "yesterday at \(time)")
        }
        let day = date.formatted(.dateTime.day().month(.abbreviated))
        return String(localized: "\(day) at \(time)")
    }

    static func lastSeen(_ raw: String) -> String {
        guard let date = date(raw) else { return String(localized: "Activity time unavailable") }
        return date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
    }

    /// In-chat date separator: "Today", "Yesterday", "July 14", or "August 11, 2025".
    static func dayHeader(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return String(localized: "Today") }
        if calendar.isDateInYesterday(date) { return String(localized: "Yesterday") }
        if calendar.isDate(date, equalTo: .now, toGranularity: .year) {
            return date.formatted(.dateTime.month(.wide).day())
        }
        return date.formatted(.dateTime.month(.wide).day().year())
    }
}

#Preview {
    CloudRootView()
        .preferredColorScheme(.dark)
}
