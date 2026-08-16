import SwiftUI
import SwiftData
import UserNotifications

@main
struct PaydayPlaybookApp: App {
    @StateObject private var appEnvironment = AppEnvironment()
    @StateObject private var router = AppRouter()
    @StateObject private var appLock = AppLockService()
    @Environment(\.scenePhase) private var scenePhase
    /// Distinguishes the launch pass (which also covers migration) from
    /// later foreground passes, so diagnostics can tell them apart.
    @State private var didReconcileThisLaunch = false

    private let container: ModelContainer
    private let notificationDelegate = NotificationDelegate()

    init() {
        let schema = Schema([
            PlanVersion.self, IncomeRule.self, DebtAccount.self,
            PaydayPlanItem.self, PlannedCardBalance.self,
            PaydayCheckIn.self, CheckInCardPayment.self,
            LedgerEntry.self, BalanceSnapshot.self, ForecastSnapshot.self,
            NotificationPreference.self, Milestone.self, AppSettings.self,
            CashAccount.self, RecurringObligation.self, UserGoalProfile.self,
            OnboardingProgress.self, IncomeSchedule.self, IncomeChange.self,
            PlannedObligationReserve.self
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
        // Schema 1→2 logical upgrade, before any UI reads the store. A
        // failure rolls back and the untouched store retries next launch
        // (MVP_LAYOUT §7); the app still opens on the existing data.
        do {
            try MigrationService.migrateIfNeeded(context: container.mainContext)
        } catch {
            #if DEBUG
            print("Migration deferred: \(error.localizedDescription)")
            #endif
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
                        // Launch and foreground both reconcile: the rolling
                        // window advances, and anything that changed while
                        // the app was away (dates passing, a completed
                        // payday, permission revoked in iOS Settings, an
                        // archive done on another screen) is picked up here.
                        //
                        // The first pass of a session is also the pass that
                        // follows migration — `init` upgrades the store
                        // before any view reads it — so a schema change can
                        // never leave a stale schedule behind (V3-07).
                        Task {
                            let trigger: NotificationScheduler.ReconcileTrigger =
                                didReconcileThisLaunch ? .foreground : .launch
                            didReconcileThisLaunch = true
                            await appEnvironment.notificationScheduler.refreshAuthorizationStatus()
                            await appEnvironment.notificationScheduler.rescheduleAll(
                                context: container.mainContext,
                                dateProvider: appEnvironment.dateProvider,
                                trigger: trigger
                            )
                        }
                    default:
                        break
                    }
                }
                // A time-zone move or a DST transition changes when a local
                // wall-clock reminder actually fires; rebuild the schedule
                // so the intended local times survive the change.
                .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name.NSSystemTimeZoneDidChange)) { _ in
                    Task {
                        await appEnvironment.notificationScheduler.rescheduleAll(
                            context: container.mainContext,
                            dateProvider: appEnvironment.dateProvider,
                            trigger: .timeZoneChange
                        )
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
                    Task {
                        await appEnvironment.notificationScheduler.rescheduleAll(
                            context: container.mainContext,
                            dateProvider: appEnvironment.dateProvider,
                            trigger: .timeZoneChange
                        )
                    }
                }
        }
        .modelContainer(container)
    }
}
