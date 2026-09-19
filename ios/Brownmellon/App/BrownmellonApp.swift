import SwiftUI

@main
struct BrownmellonApp: App {
    // Shared foundation mocks — see Core/Mocks. Swap these for the real
    // GlassesSession (DAT), CalendarService (Google Calendar, once OAuth
    // is set up — PRD § Deployment), and SecureLocalStore (Keychain, see
    // Core/KeychainSecureLocalStore.swift) once each is ready to wire in.
    // Plain properties, not @StateObject: these are session/service
    // objects, not view state — the ViewModels are the ObservableObjects.
    private let glasses = MockGlassesSession()
    private let calendarService = MockCalendarService()
    private let secureStore = MockSecureLocalStore()

    private var backendBaseURL: URL {
        if let override = Bundle.main.object(forInfoDictionaryKey: "BROWNMELLON_BACKEND_URL") as? String,
           let url = URL(string: override) {
            return url
        }
        return URL(string: "http://localhost:3000")!
    }

    var body: some Scene {
        WindowGroup {
            TabView {
                SchedulingView(glasses: glasses, calendar: calendarService, backendBaseURL: backendBaseURL)
                    .tabItem { Label("Schedule", systemImage: "calendar") }

                AppointmentCardScanView(glasses: glasses, calendar: calendarService)
                    .tabItem { Label("Scan Card", systemImage: "doc.text.viewfinder") }

                ReadToMeView(glasses: glasses)
                    .tabItem { Label("Read To Me", systemImage: "text.viewfinder") }

                AdScamCheckView(glasses: glasses)
                    .tabItem { Label("Check Ad", systemImage: "exclamationmark.shield") }

                NavigationStack {
                    EmergencyContactSetupView(store: secureStore)
                }
                .tabItem { Label("Setup", systemImage: "person.crop.circle.badge.exclamationmark") }
            }
        }
    }
}
