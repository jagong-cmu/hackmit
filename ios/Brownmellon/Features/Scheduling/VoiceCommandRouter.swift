import Foundation

/// Feature 5's intent keyword matcher. It deliberately checks tokens rather
/// than substrings so words such as "scamper" do not start a photo capture.
struct ScamIntentMatcher {
    static func matches(_ command: String) -> Bool {
        WakeWordDetector
            .normalize(command)
            .split(separator: " ")
            .contains { $0 == "scam" || $0 == "scams" }
    }
}

/// Owns the single GlassesSession listening callback shared by scheduling and
/// Feature 5. Individual features register handlers; none calls
/// `startListening` directly, so a tab transition cannot replace another
/// feature's callback.
@MainActor
final class VoiceCommandRouter {
    private let glasses: GlassesSession
    private let listener: WakeWordListener
    private var schedulingHandler: ((String) async -> Void)?
    private var scamHandler: (() async -> Void)?
    private(set) var isListening = false
    private var scamScanInFlight = false

    init(glasses: GlassesSession, listener: WakeWordListener = WakeWordListener()) {
        self.glasses = glasses
        self.listener = listener
    }

    func setSchedulingHandler(_ handler: @escaping (String) async -> Void) {
        schedulingHandler = handler
    }

    func setScamHandler(_ handler: @escaping () async -> Void) {
        scamHandler = handler
    }

    func start() {
        guard !isListening else { return }
        isListening = true
        glasses.startListening { [weak self] transcript in
            Task { @MainActor [weak self] in
                guard let self, let command = self.listener.consume(transcript) else { return }
                await self.route(command)
            }
        }
    }

    func stop() {
        guard isListening else { return }
        glasses.stopListening()
        isListening = false
        listener.reset()
    }

    /// Exposed for unit tests and Simulator/demo controls. Production speech
    /// reaches the same method through the shared listener callback.
    func route(_ command: String) async {
        if ScamIntentMatcher.matches(command) {
            guard !scamScanInFlight else { return }
            scamScanInFlight = true
            await scamHandler?()
            scamScanInFlight = false
        } else {
            await schedulingHandler?(command)
        }
    }
}
