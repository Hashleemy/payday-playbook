import SwiftUI
import SwiftData

/// Gates the app on onboarding completion, applies the optional app lock,
/// and hosts the main tab layout.
struct RootView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var appEnvironment: AppEnvironment
    @EnvironmentObject private var appLock: AppLockService
    @Query private var settings: [AppSettings]
    @State private var coldLaunchHandled = false

    private var onboardingComplete: Bool {
        settings.first?.onboardingComplete ?? false
    }

    var body: some View {
        ZStack {
            if onboardingComplete {
                MainTabView()
            } else {
                OnboardingFlowView()
            }

            // Keep financial data out of the app-switcher snapshot.
            if appLock.isEnabled && scenePhase != .active && !appLock.isLocked {
                PrivacyShield()
                    .zIndex(9)
            }

            if appLock.isLocked {
                AppLockOverlay()
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        .onAppear {
            appLock.isEnabled = settings.first?.appLockEnabled ?? false
            if !coldLaunchHandled {
                coldLaunchHandled = true
                // A fresh process must authenticate too, not just resumes.
                appLock.lockIfEnabled()
            }
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--uitest-skip-onboarding") {
                try? completeOnboardingForUITest()
            }
            #endif
        }
        .onChange(of: settings.first?.appLockEnabled ?? false) { _, enabled in
            appLock.isEnabled = enabled
        }
    }

    #if DEBUG
    private func completeOnboardingForUITest() throws {
        let summary = try PlanSeeder.seedIfNeeded(context: modelContext)
        if let row = try modelContext.fetch(FetchDescriptor<AppSettings>()).first {
            row.onboardingComplete = true
            try modelContext.save()
        }
        _ = summary
    }
    #endif
}

/// Opaque cover shown while the app is inactive (app switcher, interruptions)
/// whenever the app lock is enabled.
struct PrivacyShield: View {
    var body: some View {
        ZStack {
            Rectangle()
                .fill(.regularMaterial)
                .ignoresSafeArea()
            Image(systemName: "lock.shield")
                .font(.system(size: 44))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
        }
    }
}

struct AppLockOverlay: View {
    @EnvironmentObject private var appLock: AppLockService

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.regularMaterial)
                .ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                Text("Payday Playbook is locked")
                    .font(.title3.weight(.semibold))
                if let error = appLock.lastError {
                    Text(error)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Button {
                    Task { await appLock.unlock() }
                } label: {
                    Label("Unlock", systemImage: "faceid")
                        .frame(minWidth: 160, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("Unlock with Face ID or passcode")
            }
            .padding()
        }
        .task {
            await appLock.unlock()
        }
    }
}

struct MainTabView: View {
    @EnvironmentObject private var router: AppRouter

    var body: some View {
        TabView(selection: $router.selectedTab) {
            TodayView()
                .tabItem { Label("Today", systemImage: "sun.max.fill") }
                .tag(AppTab.today)
            CalendarTabView()
                .tabItem { Label("Calendar", systemImage: "calendar") }
                .tag(AppTab.calendar)
            DebtsView()
                .tabItem { Label("Debts", systemImage: "creditcard.fill") }
                .tag(AppTab.debts)
            ProgressTabView()
                .tabItem { Label("Progress", systemImage: "chart.line.uptrend.xyaxis") }
                .tag(AppTab.progress)
        }
    }
}
