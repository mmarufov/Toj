import UIKit

@MainActor
final class TojAppDelegate: NSObject, UIApplicationDelegate {
    private var runtimePreparationTask: Task<Void, Never>?

    private static var shouldPrepareCloudRuntime: Bool {
        #if DEBUG
        if TelegramFastUITestFixture.enabled {
            return true
        }
        #endif
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] == nil
            && environment["TOJ_USE_M1_SKELETON"] != "1"
            && environment["TOJ_DEMO_MODE"] != "1"
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        BackgroundRuntimeCoordinator.shared.registerTasks()
        beginCloudRuntimePreparationIfNeeded()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(schedulePendingBackgroundWork(_:)),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        _ = CallKitAdapter.shared
        // PushKit may launch the process in the background without constructing a SwiftUI scene.
        // Restore the call-control session at process scope so a lock-screen answer never depends
        // on CloudRootView's task having run first.
        CallProcessBootstrap.shared.start()
        VoIPPushRegistrationCenter.shared.install()
        PushRegistrationCenter.shared.install()
        return true
    }

    @objc private func schedulePendingBackgroundWork(_ notification: Notification) {
        BackgroundRuntimeCoordinator.shared.schedulePendingWork()
    }

    private func beginCloudRuntimePreparationIfNeeded() {
        guard Self.shouldPrepareCloudRuntime, runtimePreparationTask == nil else { return }
        runtimePreparationTask = Task {
            await CloudAppModel.shared.prepareForBackgroundRuntime()
        }
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        PushRegistrationCenter.shared.receivedDeviceToken(deviceToken)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        PushRegistrationCenter.shared.registrationFailed(error)
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        beginCloudRuntimePreparationIfNeeded()
        Task {
            if let runtimePreparationTask {
                await runtimePreparationTask.value
            }
            let changed = await PushRegistrationCenter.shared.handleRemoteNotification()
            completionHandler(changed ? .newData : .noData)
        }
    }

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        beginCloudRuntimePreparationIfNeeded()
        BackgroundRuntimeCoordinator.shared.receiveBackgroundSessionEvents(
            identifier: identifier,
            completionHandler: completionHandler
        )
    }
}
