import SwiftUI

@main
struct BrownmellonApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
        }
    }
}

/// Tabs plus the always-visible voice status bar. The tab selection is bound
/// to the router so "Hey Dojo, scan this" brings the Scan Card screen forward
/// while the photo is taken — the wearer's companion can see what's happening.
private struct RootView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var router: VoiceCommandRouter

    init(model: AppModel) {
        self.model = model
        self.router = model.router
    }

    var body: some View {
        VStack(spacing: 0) {
            VoiceStatusBar(router: router)
            Divider()

            TabView(selection: $router.activeTab) {
                if let datSession = model.datSession {
                    NavigationStack {
                        GlassesView(session: datSession)
                    }
                    .tabItem { Label("Glasses", systemImage: "eyeglasses") }
                    .tag(AppTab.glasses)
                }

                SchedulingView(router: router, datSession: model.datSession)
                    .tabItem { Label("Schedule", systemImage: "calendar") }
                    .tag(AppTab.schedule)

                AppointmentCardScanView(viewModel: model.scanCard)
                    .tabItem { Label("Scan Card", systemImage: "doc.text.viewfinder") }
                    .tag(AppTab.scanCard)

                ReadToMeView(viewModel: model.readToMe)
                    .tabItem { Label("Read To Me", systemImage: "text.viewfinder") }
                    .tag(AppTab.readToMe)

                AdScamCheckView(viewModel: model.adCheck)
                    .tabItem { Label("Check Ad", systemImage: "exclamationmark.shield") }
                    .tag(AppTab.checkAd)

                NavigationStack {
                    EmergencyContactSetupView(viewModel: model.emergency)
                }
                .tabItem { Label("Setup", systemImage: "person.crop.circle.badge.exclamationmark") }
                .tag(AppTab.setup)
            }
        }
        // The mic opens once, for the life of the app — not per tab.
        .onAppear { router.startListening() }
        // Meta AI hands registration / permission results back through the
        // brownmellon:// scheme declared in project.yml.
        .onOpenURL { url in
            Task { await DATGlassesSession.handle(url: url) }
        }
    }
}
