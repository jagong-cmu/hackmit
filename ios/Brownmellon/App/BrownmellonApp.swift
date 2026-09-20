import SwiftUI
import MWDATCore

@main
struct BrownmellonApp: App {
    // GlassesSession: real Ray-Ban Meta (DAT + Bluetooth audio) on a physical
    // phone, photo-picker/TTS mock on Simulator where there's no Bluetooth.
    // CalendarService / SecureLocalStore are still mocks — swap for
    // GoogleCalendarService (needs an OAuth client ID, PRD § Deployment) and
    // KeychainSecureLocalStore when ready.
    // Plain properties, not @StateObject: these are session/service
    // objects, not view state — the ViewModels are the ObservableObjects.
    private let glasses: GlassesSession
    private let datSession: DATGlassesSession?
    private let calendarService = MockCalendarService()
    private let secureStore = MockSecureLocalStore()

    // v2 features (each PRD adds one line here, and one tab or Setup link).
    // A feature view model that is also a VoiceCommandHandler is owned here
    // and passed to *both* its view and the assistant's `handlers:`, so the
    // voice path and the on-screen path act on the same instance:
    // private let foodLabel = FoodLabelViewModel(glasses: glasses, ...)
    private let soundAlerts: SoundAlertMonitor

    /// The one "Hey Dojo" pipeline. Started once at launch below and never
    /// stopped — listening is app-lifetime, not a tab's.
    private let assistant: VoiceAssistant
    private let scheduling: SchedulingViewModel

    init() {
        #if targetEnvironment(simulator)
        let glasses = MockGlassesSession()
        self.glasses = glasses
        datSession = nil
        #else
        do {
            try Wearables.configure()
        } catch {
            assertionFailure("Wearables SDK failed to configure: \(error)")
        }
        let glasses = DATGlassesSession()
        self.glasses = glasses
        datSession = glasses
        #endif

        soundAlerts = SoundAlertMonitor(glasses: glasses, store: secureStore)
        assistant = VoiceAssistant(
            glasses: glasses,
            calendar: calendarService,
            backendBaseURL: Self.backendBaseURL,
            handlers: [soundAlerts]   // v2: [memory, foodLabel, soundAlerts]
        )
        scheduling = SchedulingViewModel(assistant: assistant)
    }

    private static var backendBaseURL: URL {
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

                SchedulingView(viewModel: scheduling, glasses: glasses)
                    .tabItem { Label("Schedule", systemImage: "calendar") }

                AppointmentCardScanView(glasses: glasses, calendar: calendarService)
                    .tabItem { Label("Scan Card", systemImage: "doc.text.viewfinder") }

                ReadToMeView(glasses: glasses)
                    .tabItem { Label("Read To Me", systemImage: "text.viewfinder") }

                AdScamCheckView(glasses: glasses)
                    .tabItem { Label("Check Ad", systemImage: "exclamationmark.shield") }

                NavigationStack {
                    SetupHomeView(store: secureStore)
                }
                .tabItem { Label("Setup", systemImage: "person.crop.circle.badge.exclamationmark") }
            }
            // Listen for "Hey Dojo" from launch, on every tab, for as long as
            // the app lives. The root TabView never disappears, so this runs
            // once; switching tabs does not stop it.
            .task { assistant.start(); soundAlerts.start() }
            .environmentObject(soundAlerts)
            // Meta AI hands registration / permission results back through the
            // brownmellon:// scheme declared in project.yml.
            .onOpenURL { url in
                Task { await DATGlassesSession.handle(url: url) }
            }
        }
    }
}
