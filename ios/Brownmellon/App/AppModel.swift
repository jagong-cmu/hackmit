import Foundation
import MWDATCore

/// Composition root: builds every service and feature view model once and
/// wires them to the voice router. Owned by `BrownmellonApp` as a
/// `@StateObject`; the views receive their view models from here rather than
/// creating their own, so a voice command and a button tap drive the very
/// same object and the screen shows what the voice just did.
@MainActor
final class AppModel: ObservableObject {
    // GlassesSession: real Ray-Ban Meta (DAT + Bluetooth audio) on a physical
    // phone, photo-picker/TTS mock on Simulator where there's no Bluetooth.
    // CalendarService is still a mock — swap for GoogleCalendarService once
    // it has an OAuth client ID (PRD § Deployment).
    let glasses: GlassesSession
    let datSession: DATGlassesSession?
    let calendar: CalendarService = MockCalendarService()
    // Real Keychain store: "Hey Dojo, call my daughter" is only useful if the
    // contact a caregiver entered is still there after a relaunch.
    let secureStore: SecureLocalStore = KeychainSecureLocalStore()

    let scheduling: SchedulingCoordinator
    let scanCard: AppointmentCardScanViewModel
    let readToMe: ReadToMeViewModel
    let adCheck: AdScamCheckViewModel
    let emergency: EmergencyContactSetupViewModel
    let router: VoiceCommandRouter

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

        let intents = IntentClient(endpoint: Self.backendBaseURL.appendingPathComponent("api/parse-intent"))
        scheduling = SchedulingCoordinator(glasses: glasses, calendar: calendar, intents: intents)
        scanCard = AppointmentCardScanViewModel(glasses: glasses, calendar: calendar)
        readToMe = ReadToMeViewModel(glasses: glasses)
        adCheck = AdScamCheckViewModel(glasses: glasses)
        emergency = EmergencyContactSetupViewModel(store: secureStore)
        router = VoiceCommandRouter(
            glasses: glasses,
            intents: intents,
            scheduling: scheduling,
            scanCard: scanCard,
            readToMe: readToMe,
            adCheck: adCheck,
            emergency: emergency
        )
    }

    static var backendBaseURL: URL {
        if let override = Bundle.main.object(forInfoDictionaryKey: "BROWNMELLON_BACKEND_URL") as? String,
           let url = URL(string: override) {
            return url
        }
        return URL(string: "http://localhost:3000")!
    }
}
