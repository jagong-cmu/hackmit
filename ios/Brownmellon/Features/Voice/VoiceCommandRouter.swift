import Foundation

/// The app's tabs, so a voice command can bring its feature's screen forward.
enum AppTab: Hashable {
    case glasses, schedule, scanCard, readToMe, checkAd, setup
}

/// One always-on "Hey Dojo" listener for the whole app, dispatching each
/// command to the feature that owns it.
///
/// Before this, only Scheduling listened, and only while its tab was showing;
/// features 3–6 were buttons. Now the router starts the mic when the app
/// launches and keeps it open across tabs, and every feature is reachable
/// two ways — by voice or by its existing button — through the same view
/// model method.
///
/// Dispatch is two-tier. `VoiceCommandClassifier` handles the closed
/// vocabulary on-device first (camera triggers, calls, yes/no) — instant,
/// offline, no model quota. Anything else goes to the backend, which returns
/// a calendar intent or, for paraphrases, one of the same feature intents.
///
/// One command at a time: a scan takes several seconds, and a second command
/// mid-flight would have two features talking over each other. Emergency
/// calls are the exception and always go through.
@MainActor
final class VoiceCommandRouter: ObservableObject {
    /// Whether we've asked the glasses to stream the mic. On hardware,
    /// `DATGlassesSession.isListening` is the ground truth.
    @Published private(set) var isListening = false
    /// Latest raw transcript, for the status bar ("Heard: …").
    @Published private(set) var lastHeard: String?
    /// The last command we acted on, wake word stripped.
    @Published private(set) var lastCommand: String?
    /// The last thing the glasses said, from any feature.
    @Published private(set) var lastResponse: String?
    /// A feature is mid-flight (capturing, calling the backend, speaking).
    @Published private(set) var isBusy = false
    /// The tab whose feature was last triggered by voice. The root view binds
    /// its `TabView` selection to this so the screen follows the command.
    @Published var activeTab: AppTab = .schedule

    private let glasses: GlassesSession
    private let intents: IntentClient
    private let scheduling: SchedulingCoordinator
    private let scanCard: AppointmentCardScanViewModel
    private let readToMe: ReadToMeViewModel
    private let adCheck: AdScamCheckViewModel
    private let emergency: EmergencyContactSetupViewModel
    private let gate: VoiceTranscriptGate
    private let classifier = VoiceCommandClassifier()
    private var settleTask: Task<Void, Never>?

    init(
        glasses: GlassesSession,
        intents: IntentClient,
        scheduling: SchedulingCoordinator,
        scanCard: AppointmentCardScanViewModel,
        readToMe: ReadToMeViewModel,
        adCheck: AdScamCheckViewModel,
        emergency: EmergencyContactSetupViewModel,
        gate: VoiceTranscriptGate = VoiceTranscriptGate()
    ) {
        self.glasses = glasses
        self.intents = intents
        self.scheduling = scheduling
        self.scanCard = scanCard
        self.readToMe = readToMe
        self.adCheck = adCheck
        self.emergency = emergency
        self.gate = gate

        // Every feature speaks through the same session; mirror it here so any
        // screen can show what the glasses just said.
        let showResponse: (String) -> Void = { [weak self] text in self?.lastResponse = text }
        if let mock = glasses as? MockGlassesSession {
            mock.onSpeak = showResponse
        } else if let real = glasses as? DATGlassesSession {
            real.onSpeak = showResponse
        }
    }

    // MARK: - Mic lifecycle

    func startListening() {
        guard !isListening else { return }
        isListening = true
        glasses.startListening { [weak self] transcript in
            // The recognizer callback has no thread guarantees; hop to the main
            // actor before touching the gate.
            Task { @MainActor [weak self] in self?.handleTranscript(transcript) }
        }
    }

    func stopListening() {
        guard isListening else { return }
        isListening = false
        settleTask?.cancel()
        glasses.stopListening()
    }

    /// Feed one transcript from the recognizer. Also what a test or the mock
    /// session's `simulateTranscript` ends up calling.
    func handleTranscript(_ transcript: String) {
        if !transcript.isEmpty { lastHeard = transcript }

        if let event = gate.consume(transcript) {
            settleTask?.cancel()
            dispatch(event)
            return
        }

        // A command is settling: (re)start the quiet-period timer. Each new
        // partial cancels the previous timer, so the command is released only
        // once the transcript has stopped changing.
        settleTask?.cancel()
        guard gate.hasPendingCommand else { return }
        let delay = gate.settleDelay + 0.05
        settleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self, let event = self.gate.settle() else { return }
            self.dispatch(event)
        }
    }

    private func dispatch(_ event: VoiceTranscriptGate.Event) {
        Task { [weak self] in
            guard let self else { return }
            switch event {
            case let .command(command):
                await self.handle(command)
            case let .confirmation(answer):
                await self.answerConfirmation(answer)
            }
        }
    }

    // MARK: - Dispatch

    /// Act on the words after "Hey Dojo". Public so a typed command (the
    /// Schedule tab's test field, Simulator) runs the exact path a spoken one does.
    func handle(_ command: String) async {
        let command = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }

        let local = classifier.classify(command)

        // Never queue an emergency behind a photo upload.
        let isCall: Bool
        switch local {
        case .callEmergency, .callContact: isCall = true
        default: isCall = false
        }
        if isBusy && !isCall {
            lastResponse = "Still working on the last request…"
            return
        }

        lastCommand = command
        isBusy = true
        defer {
            isBusy = false
            // Whatever was heard up to now — including our own reply leaking
            // into the mic — is history.
            gate.markStale()
        }

        if let local {
            await performLocal(local)
            return
        }

        do {
            await performIntent(try await intents.parse(command: command))
        } catch {
            await speak("Sorry, something went wrong. Please try again.")
        }
    }

    private func performIntent(_ intent: VoiceIntent) async {
        switch intent {
        case .createEvent, .dailyBriefing, .unknown:
            dropPendingConfirmation()
            activeTab = .schedule
            await scheduling.perform(intent)
        case .scanCard:
            await performLocal(.scanCard)
        case .readText:
            await performLocal(.readText)
        case .checkAd:
            await performLocal(.checkAd)
        case .callEmergency:
            await performLocal(.callEmergency)
        case let .callContact(name):
            await performLocal(.callContact(name))
        }
    }

    private func performLocal(_ command: LocalVoiceCommand) async {
        switch command {
        case .confirmYes:
            if scanCard.isAwaitingConfirmation {
                await answerConfirmation(true)
            } else {
                await speak("There's nothing to confirm right now.")
            }

        case .confirmNo:
            if scanCard.isAwaitingConfirmation {
                await answerConfirmation(false)
            } else {
                await speak("Okay.")
            }

        case .scanCard:
            dropPendingConfirmation()
            activeTab = .scanCard
            await scanCard.scan()
            // The question has been asked (scan() awaits its own speech); now
            // listen for a bare "yes"/"no".
            if scanCard.isAwaitingConfirmation {
                gate.awaitConfirmation()
            }

        case .readText:
            dropPendingConfirmation()
            activeTab = .readToMe
            await readToMe.readThisToMe()

        case .checkAd:
            dropPendingConfirmation()
            activeTab = .checkAd
            await adCheck.checkAd()

        case .callEmergency:
            dropPendingConfirmation()
            activeTab = .setup
            // Dial first, talk second — the confirmation sheet should be on the
            // phone before the sentence finishes.
            if emergency.call911() {
                await speak("Calling 911 now. Please confirm on your phone.")
            } else {
                await speak("I couldn't start the call. Please use your phone to call 911.")
            }

        case let .callContact(name):
            dropPendingConfirmation()
            activeTab = .setup
            guard let contact = emergency.contact(matching: name) else {
                if emergency.contacts.isEmpty {
                    await speak("No emergency contacts are set up yet. Ask your caregiver to add one in Setup. I can always call 911.")
                } else {
                    let known = emergency.contacts.map { "your \($0.relation)" }.joined(separator: ", ")
                    await speak("I don't have a number for \(name). I can call \(known), or 911.")
                }
                return
            }
            if emergency.callNow(contact) {
                await speak("Calling your \(contact.relation) now. Please confirm on your phone.")
            } else {
                await speak("I couldn't start the call to your \(contact.relation). Please use your phone.")
            }
        }
    }

    private func answerConfirmation(_ yes: Bool) async {
        gate.cancelConfirmation()
        guard scanCard.isAwaitingConfirmation else { return }
        activeTab = .scanCard
        if yes {
            await scanCard.confirm()
        } else {
            await scanCard.decline()
        }
        gate.markStale()
    }

    /// A new command while a "should I add it?" is open means the wearer moved
    /// on. Close the question quietly so the next feature's reply isn't
    /// preceded by "okay, I won't add it".
    private func dropPendingConfirmation() {
        gate.cancelConfirmation()
        scanCard.cancel()
    }

    private func speak(_ text: String) async {
        await glasses.speak(text)
    }
}
