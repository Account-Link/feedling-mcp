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
                    // First-launch setup, all idempotent:
                    // 1. identity keypair generation + Feedling Cloud
                    //    registration (no-ops if we already have creds)
                    // 2. content keypair generation for v1 envelope
                    //    encryption (Keychain-backed, lives forever)
                    // 3. pull the enclave's attestation + content pubkey so
                    //    outgoing chat/memory writes can be encrypted to it
                    // 4. silent re-wrap of any pre-Phase-A v0 rows into v1
                    //    envelopes. Gated on a UserDefaults flag so it only
                    //    runs once. Non-blocking — nothing on screen
                    //    depends on completion.
                    await FeedlingAPI.shared.ensureRegisteredIfCloud()
                    await FeedlingAPI.shared.ensureUserIdIfNeeded()
                    FeedlingAPI.shared.ensureContentKeypair()
                    await FeedlingAPI.shared.refreshEnclaveAttestation()
                    await FeedlingAPI.shared.runSilentV1MigrationIfNeeded()
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
