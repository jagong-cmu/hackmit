import SwiftUI
import MWDATCore

@main
struct BrownmellonApp: App {
    // GlassesSession: real Ray-Ban Meta (DAT + Bluetooth audio) on a physical
    // phone, photo-picker/TTS mock on Simulator where there's no Bluetooth.
    // CalendarService remains mocked until Google Calendar OAuth is set up.
    // SecureLocalStore is the real Keychain store so caregiver settings and
    // memory notes survive relaunch (tests use MockSecureLocalStore).
    // Plain properties, not @StateObject: these are session/service
    // objects, not view state — the ViewModels are the ObservableObjects.
    private let glasses: GlassesSession
    private let datSession: DATGlassesSession?
    private let calendarService = MockCalendarService()
    private let secureStore: SecureLocalStore = KeychainSecureLocalStore()

    // v2 features. A feature view model that is also a VoiceCommandHandler is
    // owned here and passed to *both* its view and the assistant's
    // `handlers:`, so the voice path and the on-screen path act on the same
    // instance.
    private let memory: MemoryCommandHandler
    private let memoryView: MemoryViewModel
    private let foodLabel: FoodLabelViewModel
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

        memory = MemoryCommandHandler(
            glasses: glasses,
            store: MemoryStore(store: secureStore),
            vision: VisionBackendClient(),
            recall: RecallClient(endpoint: Self.backendBaseURL.appendingPathComponent("api/recall"))
        )
        foodLabel = FoodLabelViewModel(glasses: glasses, store: secureStore)
        soundAlerts = SoundAlertMonitor(glasses: glasses, store: secureStore)
        assistant = VoiceAssistant(
            glasses: glasses,
            calendar: calendarService,
            backendBaseURL: Self.backendBaseURL,
            handlers: [memory, foodLabel, soundAlerts]
        )
        memoryView = MemoryViewModel(handler: memory, assistant: assistant)
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

                FoodLabelView(viewModel: foodLabel)
                    .tabItem { Label("Check Food", systemImage: "carrot") }

                MemoryView(viewModel: memoryView)
                    .tabItem { Label("Memory", systemImage: "brain.head.profile") }

                NavigationStack {
                    SetupHomeView(store: secureStore)
                }
                .tabItem { Label("Setup", systemImage: "gearshape") }
            }
            // Listen for "Hey Dojo" — and, if enabled, for household sounds —
            // from launch, on every tab, for as long as the app lives. The root
            // TabView never disappears, so this runs once.
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
