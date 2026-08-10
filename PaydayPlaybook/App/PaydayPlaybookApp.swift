import SwiftUI
import SwiftData
import UserNotifications

@main
struct PaydayPlaybookApp: App {
    @StateObject private var appEnvironment = AppEnvironment()
    @StateObject private var router = AppRouter()
    @StateObject private var appLock = AppLockService()
    @Environment(\.scenePhase) private var scenePhase

    private let container: ModelContainer
    private let notificationDelegate = NotificationDelegate()

    init() {
        let schema = Schema([
            PlanVersion.self, IncomeRule.self, DebtAccount.self,
            PaydayPlanItem.self, PlannedCardBalance.self,
            PaydayCheckIn.self, CheckInCardPayment.self,
            LedgerEntry.self, BalanceSnapshot.self, ForecastSnapshot.self,
            NotificationPreference.self, Milestone.self, AppSettings.self
        ])
        var configuration = ModelConfiguration(schema: schema)
        #if DEBUG
        // When this app is only hosting unit tests, stay off the real store —
        // the tests build their own in-memory containers.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        }
        // UI tests use an isolated on-disk store so relaunch persistence is
        // real; `--uitest-reset` wipes it for a clean install.
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--uitest") {
            let storeURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("PaydayPlaybook-UITest.store")
            if arguments.contains("--uitest-reset") {
                try? FileManager.default.removeItem(at: storeURL)
                let shm = storeURL.deletingPathExtension().appendingPathExtension("store-shm")
                let wal = storeURL.deletingPathExtension().appendingPathExtension("store-wal")
                try? FileManager.default.removeItem(at: shm)
                try? FileManager.default.removeItem(at: wal)
            }
            configuration = ModelConfiguration(schema: schema, url: storeURL)
        }
        #endif
        do {
            container = try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Could not create SwiftData container: \(error)")
        }
        // The delegate must exist before launch finishes so a notification tap
        // that starts the app still deep-links (the route is buffered until the
        // UI registers its handler).
        UNUserNotificationCenter.current().delegate = notificationDelegate
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appEnvironment)
                .environmentObject(router)
                .environmentObject(appLock)
                .environmentObject(appEnvironment.notificationScheduler)
                .onAppear {
                    notificationDelegate.onRoute = { [weak router] userInfo in
                        router?.handleNotificationRoute(userInfo)
                    }
                    UNUserNotificationCenter.current().delegate = notificationDelegate
                }
                .onChange(of: scenePhase) { _, newPhase in
                    switch newPhase {
                    case .background:
                        appLock.lockIfEnabled()
                    case .active:
                        Task { await appEnvironment.notificationScheduler.refreshAuthorizationStatus() }
                    default:
                        break
                    }
                }
        }
        .modelContainer(container)
    }
}
