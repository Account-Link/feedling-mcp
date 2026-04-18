import SwiftUI
import UserNotifications

@main
struct FeedlingTestApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var router = AppRouter()
    @StateObject private var chatViewModel = ChatViewModel()
    @StateObject private var identityViewModel = IdentityViewModel()
    @StateObject private var memoryViewModel = MemoryViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(LiveActivityManager.shared)
                .environmentObject(router)
                .environmentObject(chatViewModel)
                .environmentObject(identityViewModel)
                .environmentObject(memoryViewModel)
                .task {
                    // First-launch registration: if we're in cloud mode and lack
                    // credentials, generate a keypair and register to Feedling.
                    // Idempotent — no-ops if we already have creds.
                    await FeedlingAPI.shared.ensureRegisteredIfCloud()
                }
                .onOpenURL { url in
                    guard url.scheme == "feedlingtest" else { return }
                    router.selectedTab = .chat
                    Task { await chatViewModel.loadHistory() }
                }
        }
    }
}

class AppDelegate: NSObject, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
            if granted {
                DispatchQueue.main.async { application.registerForRemoteNotifications() }
            }
        }
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Task { @MainActor in
            LiveActivityManager.shared.registerDeviceToken(deviceToken)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        print("[APNs] ❌ Failed to register: \(error.localizedDescription)")
    }
}
