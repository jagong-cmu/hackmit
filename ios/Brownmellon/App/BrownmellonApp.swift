import SwiftUI
import MWDATCore

@main
struct BrownmellonApp: App {
    // GlassesSession: real Ray-Ban Meta (DAT + Bluetooth audio) on a physical
    // phone, photo-picker/TTS mock on Simulator where there's no Bluetooth.
    // CalendarService remains mocked until Google Calendar OAuth is set up.
    // Plain properties, not @StateObject: these are session/service
    // objects, not view state — the ViewModels are the ObservableObjects.
    private let glasses: GlassesSession
    private let datSession: DATGlassesSession?
    private let calendarService = MockCalendarService()

    init() {
        #if targetEnvironment(simulator)
        glasses = MockGlassesSession()
        datSession = nil
        #else
        do {
            try Wearables.configure()
        } catch {
            assertionFailure("Wearables SDK failed to configure: \(error)")
        }
        let session = DATGlassesSession()
        glasses = session
        datSession = session
        #endif
    }

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
                if let datSession {
                    NavigationStack {
                        GlassesView(session: datSession)
                    }
                    .tabItem { Label("Glasses", systemImage: "eyeglasses") }
                }

                SchedulingView(glasses: glasses, calendar: calendarService, backendBaseURL: backendBaseURL)
                    .tabItem { Label("Schedule", systemImage: "calendar") }

                AppointmentCardScanView(glasses: glasses, calendar: calendarService)
                    .tabItem { Label("Scan Card", systemImage: "doc.text.viewfinder") }

                ReadToMeView(glasses: glasses)
                    .tabItem { Label("Read To Me", systemImage: "text.viewfinder") }

                AdScamCheckView(glasses: glasses)
                    .tabItem { Label("Check Ad", systemImage: "exclamationmark.shield") }
            }
            // Meta AI hands registration / permission results back through the
            // brownmellon:// scheme declared in project.yml.
            .onOpenURL { url in
                Task { await DATGlassesSession.handle(url: url) }
            }
        }
    }
}
