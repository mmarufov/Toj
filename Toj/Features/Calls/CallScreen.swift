import AVKit
import SwiftUI
import UIKit

struct TojCallScreen: View {
    @Bindable var coordinator: CallCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingSecurityConfirmation = false
    @State private var localIsPrimary = false
    @State private var previewOffset: CGSize = .zero
    @State private var previewDragOrigin: CGSize = .zero
    @State private var pictureInPictureCanStart = false

    var body: some View {
        Group {
            if coordinator.hasVideoExperience {
                videoCallScreen
            } else {
                voiceCallScreen
            }
        }
        .interactiveDismissDisabled(coordinator.state != .ended)
        .confirmationDialog(
            "Do the four emojis match?",
            isPresented: $showingSecurityConfirmation,
            titleVisibility: .visible
        ) {
            Button("They match") { coordinator.markSecurityVerified() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Compare them aloud with the other person. A mismatch can indicate interference with this call.")
        }
        .onAppear {
            configurePictureInPicture()
            updateOwningScene()
        }
        .onChange(of: coordinator.pictureInPictureVideoRenderer?.id) { _, _ in
            configurePictureInPicture()
        }
        .onChange(of: scenePhase) { _, _ in updateOwningScene() }
    }

    private var voiceCallScreen: some View {
        ZStack {
            LinearGradient(
                colors: [Color(hex: 0x111318), TojTheme.canvas],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                Button { coordinator.minimize() } label: {
                    Image(systemName: "chevron.down")
                        .frame(width: 46, height: 46)
                }
                .buttonStyle(.glass)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .accessibilityLabel("Minimize call")
                .disabled(coordinator.state == .ended)

                Spacer()

                ZStack {
                    if !reduceMotion && coordinator.state != .active && coordinator.state != .ended {
                        Circle()
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                            .frame(width: 154, height: 154)
                            .scaleEffect(1.15)
                    }
                    CloudProfileAvatar(
                        model: .shared,
                        title: coordinator.peerName,
                        media: CloudAppModel.shared.dialogs.first {
                            $0.id == coordinator.activeDialogId
                        }?.photo,
                        size: 122
                    )
                }

                Text(coordinator.peerName)
                    .font(TojTheme.heading(.title, weight: .bold))
                    .padding(.top, 22)

                callStatus
                    .font(.subheadline)
                    .foregroundStyle(statusColor)
                    .padding(.top, 7)

                securityButton

                if let failure = coordinator.failureMessage, coordinator.state == .ended {
                    Text(failure)
                        .font(.footnote)
                        .foregroundStyle(TojTheme.danger)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 34)
                        .padding(.top, 14)
                }

                Spacer()

                HStack(spacing: 18) {
                    control(
                        icon: coordinator.isMuted ? "mic.slash.fill" : "mic.fill",
                        title: "Mute",
                        selected: coordinator.isMuted
                    ) { Task { await coordinator.toggleMute() } }
                    control(
                        icon: coordinator.isSpeakerEnabled ? "speaker.wave.3.fill" : "speaker.wave.2.fill",
                        title: coordinator.audioRouteName,
                        selected: coordinator.isSpeakerEnabled
                    ) { Task { await coordinator.toggleSpeaker() } }
                }
                .disabled(coordinator.state == .ending || coordinator.state == .ended)

                terminalControl
            }
        }
    }

    private var videoCallScreen: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.ignoresSafeArea()
                primaryVideo
                    .ignoresSafeArea()

                LinearGradient(
                    colors: [.black.opacity(0.62), .clear, .black.opacity(0.78)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
                .allowsHitTesting(false)

                VStack(spacing: 0) {
                    videoHeader
                    Spacer()
                    videoStatus
                    videoControls
                        .padding(.bottom, max(18, geometry.safeAreaInsets.bottom + 8))
                }

                secondaryVideo
                    .frame(width: 124, height: 178)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(.white.opacity(0.24), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.45), radius: 16, y: 8)
                    .position(
                        x: clampedPreviewX(in: geometry.size),
                        y: clampedPreviewY(in: geometry.size, safeTop: geometry.safeAreaInsets.top)
                    )
                    .gesture(previewDrag(in: geometry.size, safeTop: geometry.safeAreaInsets.top))
                    .onTapGesture { localIsPrimary.toggle() }
                    .accessibilityLabel(localIsPrimary ? "Remote video preview" : "Your video preview")
                    .accessibilityHint("Double tap to swap the large video")

                TojPictureInPictureSourceAnchor(controller: coordinator.pictureInPicture)
                    .frame(width: 2, height: 2)
                    .opacity(0.01)
                    .allowsHitTesting(false)
            }
        }
        .background(Color.black)
    }

    private var videoHeader: some View {
        HStack(spacing: 12) {
            Button { coordinator.minimize() } label: {
                Image(systemName: "chevron.down")
                    .frame(width: 44, height: 44)
                    .background(.black.opacity(0.34), in: Circle())
            }
            .buttonStyle(.tojPressable)
            .accessibilityLabel("Minimize call")

            VStack(alignment: .leading, spacing: 3) {
                Text(coordinator.peerName)
                    .font(.headline)
                    .lineLimit(1)
                callStatus
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.76))
            }

            Spacer()

            if !coordinator.securityEmojis.isEmpty {
                Button { showingSecurityConfirmation = true } label: {
                    Text(coordinator.securityEmojis.joined())
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .frame(height: 38)
                        .background(.black.opacity(0.34), in: Capsule())
                }
                .buttonStyle(.tojPressable)
                .disabled(!coordinator.canVerifySecurity)
                .accessibilityLabel(coordinator.securityVerified
                    ? "Call security verified" : "Compare call security emojis")
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }

    @ViewBuilder
    private var primaryVideo: some View {
        if localIsPrimary {
            localVideoContent(primary: true)
        } else {
            remoteVideoContent(primary: true)
        }
    }

    @ViewBuilder
    private var secondaryVideo: some View {
        if localIsPrimary {
            remoteVideoContent(primary: false)
        } else {
            localVideoContent(primary: false)
        }
    }

    @ViewBuilder
    private func localVideoContent(primary: Bool) -> some View {
        ZStack {
            Color(hex: 0x171A20)
            if coordinator.localVideoState == .active,
               let handle = coordinator.localVideoRenderer {
                TojVideoRendererView(handle: handle, mirrored: coordinator.isUsingFrontCamera)
            } else {
                videoPlaceholder(
                    icon: coordinator.cameraNeedsSettings ? "video.slash.fill" : "person.crop.circle",
                    title: localPlaceholderTitle,
                    compact: !primary
                )
            }
        }
    }

    @ViewBuilder
    private func remoteVideoContent(primary: Bool) -> some View {
        ZStack {
            Color(hex: 0x111318)
            if coordinator.remoteVideoState == .active,
               coordinator.remoteVideoTrackAvailable,
               let handle = coordinator.remoteVideoRenderer {
                TojVideoRendererView(handle: handle, mirrored: false)
            } else {
                VStack(spacing: primary ? 16 : 7) {
                    CloudProfileAvatar(
                        model: .shared,
                        title: coordinator.peerName,
                        media: CloudAppModel.shared.dialogs.first {
                            $0.id == coordinator.activeDialogId
                        }?.photo,
                        size: primary ? 104 : 48
                    )
                    if primary {
                        Text(remotePlaceholderTitle)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.white.opacity(0.74))
                            .multilineTextAlignment(.center)
                    }
                }
                .padding()
            }
        }
    }

    private func videoPlaceholder(icon: String, title: String, compact: Bool) -> some View {
        VStack(spacing: compact ? 7 : 13) {
            Image(systemName: icon)
                .font(.system(size: compact ? 24 : 38, weight: .medium))
            if !compact {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .multilineTextAlignment(.center)
            }
        }
        .foregroundStyle(.white.opacity(0.75))
        .padding()
    }

    private var localPlaceholderTitle: String {
        if coordinator.cameraNeedsSettings { return String(localized: "Camera permission is off") }
        if coordinator.localVideoState == .paused {
            return coordinator.videoIsAutomaticallyPaused
                ? String(localized: "Video paused to protect audio")
                : String(localized: "Your video is paused")
        }
        return String(localized: "Your camera is off")
    }

    private var remotePlaceholderTitle: String {
        if coordinator.state == .reconnecting { return String(localized: "Reconnecting video…") }
        switch coordinator.remoteVideoPauseReason {
        case .network: return String(localized: "Video paused for a weak connection")
        case .background: return String(localized: "Video paused in the background")
        case .unavailable: return String(localized: "Video is temporarily unavailable")
        case nil: return String(localized: "Camera is off")
        }
    }

    private var videoStatus: some View {
        VStack(spacing: 7) {
            if coordinator.state == .reconnecting {
                Label("Reconnecting — audio has priority", systemImage: "wifi.exclamationmark")
            } else if coordinator.videoIsAutomaticallyPaused {
                Label("Video paused to protect audio", systemImage: "waveform.badge.exclamationmark")
            } else if coordinator.videoQualityTier == .low, coordinator.state == .active {
                Label("Weak network — lower video quality", systemImage: "wifi.exclamationmark")
            }

            if coordinator.cameraNeedsSettings, coordinator.isCameraEnabled == false {
                Button("Open Camera Settings") {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                }
                .font(.footnote.weight(.semibold))
                .buttonStyle(.borderedProminent)
            }

            if let failure = coordinator.failureMessage, coordinator.state != .ended {
                Text(failure)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(TojTheme.danger.opacity(0.88), in: Capsule())
            }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.bottom, 14)
    }

    private var videoControls: some View {
        Group {
            if coordinator.state == .ended {
                Button("Done") { coordinator.dismissEnded() }
                    .font(.headline)
                    .foregroundStyle(TojTheme.onAccent)
                    .frame(width: 150, height: 54)
                    .background(TojTheme.accent, in: Capsule())
                    .buttonStyle(.tojPressable)
            } else {
                LazyVGrid(
                    columns: Array(
                        repeating: GridItem(.flexible(), spacing: 13),
                        count: dynamicTypeSize.isAccessibilitySize ? 3 : 6
                    ),
                    spacing: 12
                ) {
                    compactControl(
                        icon: coordinator.isMuted ? "mic.slash.fill" : "mic.fill",
                        title: "Mute",
                        selected: coordinator.isMuted
                    ) { Task { await coordinator.toggleMute() } }
                    compactControl(
                        icon: coordinator.isCameraEnabled ? "video.fill" : "video.slash.fill",
                        title: "Camera",
                        selected: !coordinator.isCameraEnabled
                    ) { Task { await coordinator.toggleCamera() } }
                    compactControl(icon: "arrow.triangle.2.circlepath.camera.fill", title: "Flip", selected: false) {
                        Task { await coordinator.switchCamera() }
                    }
                    .disabled(!coordinator.isCameraEnabled)
                    videoRouteControl
                    compactControl(icon: "pip.enter", title: "PiP", selected: false) {
                        coordinator.pictureInPicture.start()
                    }
                    .disabled(!pictureInPictureCanStart)
                    compactControl(icon: "phone.down.fill", title: "End", selected: true, destructive: true) {
                        Task { await coordinator.requestEnd() }
                    }
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                .padding(.horizontal, 12)
                .disabled(coordinator.state == .ending)
            }
        }
    }

    @ViewBuilder
    private var securityButton: some View {
        if !coordinator.securityEmojis.isEmpty {
            Button { showingSecurityConfirmation = true } label: {
                VStack(spacing: 5) {
                    Text(coordinator.securityEmojis.joined(separator: "  "))
                        .font(.title3)
                    Text(coordinator.securityVerified ? "Verified for this call" : "Compare these emojis")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(coordinator.securityVerified ? TojTheme.secure : TojTheme.secondaryText)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(TojTheme.strong, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.tojPressable)
            .disabled(!coordinator.canVerifySecurity)
            .padding(.top, 18)
            .accessibilityHint("Compare all four emojis with the person on the call")
        }
    }

    @ViewBuilder
    private var terminalControl: some View {
        if coordinator.state == .ended {
            VStack(spacing: 12) {
                if coordinator.canOfferAudioFallback {
                    Button("Audio Call") {
                        Task { await coordinator.startAudioFallback() }
                    }
                    .font(.headline)
                    .foregroundStyle(TojTheme.onAccent)
                    .frame(width: 170, height: 54)
                    .background(TojTheme.accent, in: Capsule())
                    .buttonStyle(.tojPressable)
                    .accessibilityHint("Starts a separate secure audio call")
                }

                Button(coordinator.canOfferAudioFallback ? "Cancel" : "Done") {
                    coordinator.dismissEnded()
                }
                .font(.headline)
                .foregroundStyle(TojTheme.text)
                .frame(width: 150, height: 50)
                .background(TojTheme.strong, in: Capsule())
                .buttonStyle(.tojPressable)
            }
            .padding(.top, 34)
            .padding(.bottom, 46)
        } else {
            Button { Task { await coordinator.requestEnd() } } label: {
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

    @ViewBuilder
    private var callStatus: some View {
        if coordinator.state == .active, let connectedAt = coordinator.connectedAt {
            TimelineView(.periodic(from: connectedAt, by: 1)) { context in
                Text(duration(from: connectedAt, to: context.date))
                    .contentTransition(.numericText())
            }
        } else {
            Text(statusTitle)
        }
    }

    private var statusTitle: String {
        switch coordinator.state {
        case .idle: String(localized: "Call ended")
        case .preparing: String(localized: "Preparing secure call…")
        case .outgoingRinging: String(localized: "Ringing…")
        case .incomingRinging: coordinator.initialKind == .video
            ? String(localized: "Incoming video call") : String(localized: "Incoming voice call")
        case .keyExchange: String(localized: "Securing call…")
        case .connecting: String(localized: "Connecting…")
        case .active: String(localized: "Connected")
        case .reconnecting: String(localized: "Reconnecting…")
        case .ending: String(localized: "Ending call…")
        case .ended: endTitle
        }
    }

    private var endTitle: String {
        switch coordinator.endReason {
        case .declined: String(localized: "Declined")
        case .busy: String(localized: "Line busy")
        case .unanswered: String(localized: "No answer")
        case .answeredElsewhere: String(localized: "Answered on another device")
        case .networkLost: String(localized: "Connection lost")
        case .securityError: String(localized: "Security check failed")
        default: String(localized: "Call ended")
        }
    }

    private var statusColor: Color {
        coordinator.state == .ended && coordinator.failureMessage != nil
            ? TojTheme.danger : TojTheme.secondaryText
    }

    private func duration(from start: Date, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        if seconds >= 3_600 {
            return String(format: "%d:%02d:%02d", seconds / 3_600, (seconds / 60) % 60, seconds % 60)
        }
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private func control(
        icon: String,
        title: String,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 19, weight: .semibold))
                    .frame(width: 54, height: 54)
                    .background(selected ? TojTheme.text : TojTheme.strong, in: Circle())
                    .foregroundStyle(selected ? TojTheme.canvas : TojTheme.text)
                Text(title).font(.caption).lineLimit(1)
            }
            .frame(width: 94)
        }
        .buttonStyle(.tojPressable)
        .foregroundStyle(TojTheme.text)
    }

    private func compactControl(
        icon: String,
        title: String,
        selected: Bool,
        destructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 46, height: 46)
                    .background(
                        destructive ? TojTheme.danger
                            : selected ? Color.white : Color.white.opacity(0.13),
                        in: Circle()
                    )
                    .foregroundStyle(destructive ? .white : selected ? .black : .white)
                Text(title)
                    .font(.caption2.weight(.medium))
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.tojPressable)
        .foregroundStyle(.white)
        .accessibilityLabel(title)
    }

    private func clampedPreviewX(in size: CGSize) -> CGFloat {
        min(max(70, size.width - 78 + previewOffset.width), max(70, size.width - 70))
    }

    private func clampedPreviewY(in size: CGSize, safeTop: CGFloat) -> CGFloat {
        min(max(safeTop + 118, safeTop + 185 + previewOffset.height), max(safeTop + 118, size.height - 245))
    }

    private func previewDrag(in size: CGSize, safeTop: CGFloat) -> some Gesture {
        DragGesture()
            .onChanged { value in
                previewOffset = CGSize(
                    width: previewDragOrigin.width + value.translation.width,
                    height: previewDragOrigin.height + value.translation.height
                )
            }
            .onEnded { _ in
                let x = clampedPreviewX(in: size)
                let y = clampedPreviewY(in: size, safeTop: safeTop)
                previewOffset = CGSize(width: x - (size.width - 78), height: y - (safeTop + 185))
                previewDragOrigin = previewOffset
            }
    }

    private func configurePictureInPicture() {
        guard let renderer = coordinator.pictureInPictureVideoRenderer else {
            pictureInPictureCanStart = false
            return
        }
        coordinator.pictureInPicture.configure(renderer: renderer)
        pictureInPictureCanStart = coordinator.pictureInPicture.canStart
        coordinator.pictureInPicture.onOwningSceneChanged = { [weak coordinator] identifier, foreground in
            guard let coordinator else { return }
            Task {
                await coordinator.updateVideoScene(
                    sceneIdentifier: identifier,
                    isForeground: foreground,
                    pictureInPictureIsActive: coordinator.pictureInPicture.isActive
                )
            }
        }
        coordinator.pictureInPicture.onActiveStateChanged = { [weak coordinator] active in
            guard let coordinator else { return }
            guard let sceneIdentifier = coordinator.pictureInPicture.bindToCurrentScene() else { return }
            Task {
                await coordinator.updateVideoScene(
                    sceneIdentifier: sceneIdentifier,
                    isForeground: coordinator.pictureInPicture.owningSceneIsForeground,
                    pictureInPictureIsActive: active
                )
            }
        }
    }

    private var videoRouteControl: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().fill(Color.white.opacity(0.13))
                TojSystemRoutePicker()
                    .frame(width: 46, height: 46)
            }
            .frame(width: 46, height: 46)
            .simultaneousGesture(TapGesture().onEnded {
                coordinator.markAudioRouteSelectionIntent()
            })

            Text(coordinator.audioRouteName)
                .font(.caption2.weight(.medium))
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .foregroundStyle(.white)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Audio route, \(coordinator.audioRouteName)")
    }

    private func updateOwningScene() {
        guard let sceneIdentifier = coordinator.pictureInPicture.bindToCurrentScene() else { return }
        Task {
            await coordinator.updateVideoScene(
                sceneIdentifier: sceneIdentifier,
                isForeground: scenePhase == .active,
                pictureInPictureIsActive: coordinator.pictureInPicture.isActive
            )
        }
    }
}

private struct TojVideoRendererView: UIViewRepresentable {
    let handle: CallVideoRendererHandle
    let mirrored: Bool

    func makeUIView(context: Context) -> UIView {
        let container = UIView(frame: .zero)
        container.backgroundColor = .black
        container.clipsToBounds = true
        attachRenderer(to: container)
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        attachRenderer(to: container)
    }

    static func dismantleUIView(_ container: UIView, coordinator: Void) {
        for view in container.subviews { view.removeFromSuperview() }
    }

    private func attachRenderer(to container: UIView) {
        let renderer = handle.view
        if renderer.superview !== container {
            renderer.removeFromSuperview()
            renderer.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(renderer)
            NSLayoutConstraint.activate([
                renderer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                renderer.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                renderer.topAnchor.constraint(equalTo: container.topAnchor),
                renderer.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }
        renderer.transform = mirrored ? CGAffineTransform(scaleX: -1, y: 1) : .identity
    }
}

private struct TojSystemRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView(frame: .zero)
        picker.prioritizesVideoDevices = false
        picker.activeTintColor = UIColor.white
        picker.tintColor = UIColor.white
        picker.backgroundColor = .clear
        return picker
    }

    func updateUIView(_ picker: AVRoutePickerView, context: Context) {
        picker.activeTintColor = UIColor.white
        picker.tintColor = UIColor.white
    }
}

@MainActor
private final class TojPictureInPictureSceneView: UIView {
    var onWindowSceneChanged: (() -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        onWindowSceneChanged?()
    }
}

@MainActor
final class TojVideoPictureInPictureController: NSObject {
    fileprivate let sourceView = TojPictureInPictureSceneView(frame: .zero)
    var onActiveStateChanged: ((Bool) -> Void)?
    var onOwningSceneChanged: ((String, Bool) -> Void)?

    private(set) var isActive = false
    private(set) var canStart = false
    private var rendererId: UUID?
    private weak var rendererView: UIView?
    private(set) var owningSceneIdentifier: String?
    private let videoCallViewController = AVPictureInPictureVideoCallViewController()
    private var controller: AVPictureInPictureController?

    var owningSceneIsForeground: Bool {
        guard let scene = sourceView.window?.windowScene,
              scene.session.persistentIdentifier == owningSceneIdentifier else { return false }
        return scene.activationState == .foregroundActive
    }

    override init() {
        super.init()
        sourceView.backgroundColor = .clear
        sourceView.isUserInteractionEnabled = false
        sourceView.onWindowSceneChanged = { [weak self] in
            guard let self, let identifier = self.bindToCurrentScene() else { return }
            self.onOwningSceneChanged?(identifier, self.owningSceneIsForeground)
        }
        videoCallViewController.preferredContentSize = CGSize(width: 720, height: 1_280)
        videoCallViewController.view.backgroundColor = .black
    }

    func bindToCurrentScene() -> String? {
        guard let scene = sourceView.window?.windowScene else { return nil }
        let identifier = scene.session.persistentIdentifier
        if let owningSceneIdentifier, owningSceneIdentifier != identifier { return nil }
        owningSceneIdentifier = identifier
        return identifier
    }

    func configure(renderer: CallVideoRendererHandle) {
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            canStart = false
            return
        }
        if rendererId != renderer.id {
            rendererView?.removeFromSuperview()
            let view = renderer.view
            view.removeFromSuperview()
            view.translatesAutoresizingMaskIntoConstraints = false
            videoCallViewController.view.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: videoCallViewController.view.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: videoCallViewController.view.trailingAnchor),
                view.topAnchor.constraint(equalTo: videoCallViewController.view.topAnchor),
                view.bottomAnchor.constraint(equalTo: videoCallViewController.view.bottomAnchor),
            ])
            rendererView = view
            rendererId = renderer.id
        }
        let source = AVPictureInPictureController.ContentSource(
            activeVideoCallSourceView: sourceView,
            contentViewController: videoCallViewController
        )
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = self
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        self.controller = controller
        canStart = true
    }

    func start() {
        guard canStart, let controller, !controller.isPictureInPictureActive,
              bindToCurrentScene() != nil else { return }
        controller.startPictureInPicture()
    }

    func stopAndReset() {
        controller?.stopPictureInPicture()
        controller?.delegate = nil
        controller = nil
        rendererView?.removeFromSuperview()
        rendererView = nil
        rendererId = nil
        owningSceneIdentifier = nil
        onOwningSceneChanged = nil
        canStart = false
        if isActive {
            isActive = false
            onActiveStateChanged?(false)
        }
    }
}

extension TojVideoPictureInPictureController: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerWillStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        Task { @MainActor in
            isActive = true
            onActiveStateChanged?(true)
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        Task { @MainActor in
            isActive = false
            onActiveStateChanged?(false)
        }
    }
}

private struct TojPictureInPictureSourceAnchor: UIViewRepresentable {
    let controller: TojVideoPictureInPictureController

    func makeUIView(context: Context) -> UIView { controller.sourceView }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

struct TojActiveCallPill: View {
    @Bindable var coordinator: CallCoordinator

    var body: some View {
        Button { coordinator.present() } label: {
            HStack(spacing: 9) {
                Image(systemName: coordinator.hasVideoExperience ? "video.fill" : "phone.fill")
                Text(coordinator.peerName)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(coordinator.state == .reconnecting ? "Reconnecting…" : "Return to call")
                    .font(.caption)
                    .foregroundStyle(TojTheme.secondaryText)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(TojTheme.text)
            .padding(.horizontal, 15)
            .frame(height: 48)
            .background(TojTheme.raised, in: Capsule())
            .overlay(Capsule().stroke(TojTheme.secure.opacity(0.5), lineWidth: 1))
            .shadow(color: .black.opacity(0.3), radius: 15, y: 8)
        }
        .buttonStyle(.tojPressable)
        .accessibilityLabel("Return to \(coordinator.hasVideoExperience ? "video" : "voice") call with \(coordinator.peerName)")
    }
}
