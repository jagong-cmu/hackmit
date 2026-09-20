import Foundation
import Combine
import UIKit
import AVFoundation
import Speech
import MWDATCore
import MWDATCamera

/// Real Ray-Ban Meta implementation of `GlassesSession` (PRD § Foundation —
/// "the highest-risk, most-shared piece"). One object, three transports:
///
///  - **Camera** goes through Meta's DAT SDK: register with the Meta AI app
///    once, then per photo open a `DeviceSession`, attach a `Camera`, wait for
///    the stream to come up, `capturePhoto`, tear it all down. Episodic on
///    purpose (PRD design principles) — a session is only held for the few
///    seconds a capture needs.
///  - **Speaker** and **mic** are *not* DAT APIs. To iOS the glasses are an
///    ordinary Bluetooth HFP headset, so `speak` is `AVSpeechSynthesizer` and
///    `startListening` is `AVAudioEngine` + on-device `SFSpeechRecognizer`,
///    with `AVAudioSession` told to allow Bluetooth so both route to the
///    glasses. (Meta's own CameraAccess sample does phone-side audio the same
///    way.) HFP caveat from the feasibility research: while the mic is open,
///    output drops to 8 kHz mono — fine for spoken confirmations.
///
/// Requires a physical iPhone with the Meta AI app, glasses paired, and
/// Developer Mode on in Meta AI. `BrownmellonApp` uses `MockGlassesSession`
/// on Simulator instead.
@MainActor
final class DATGlassesSession: NSObject, GlassesSession, ObservableObject {
    enum SessionError: LocalizedError {
        case notRegistered
        case cameraPermissionDenied
        case noDevice
        case noEligibleDevice(String)
        case sessionFailed(String)
        case captureTimedOut
        case photoDecodeFailed
        case speechRecognizerUnavailable
        case speechPermissionDenied
        case noAudioInput

        var errorDescription: String? {
            switch self {
            case .notRegistered: return "Connect the glasses in the Glasses tab first."
            case .cameraPermissionDenied: return "Camera access to the glasses was denied in Meta AI."
            case .noDevice: return "No glasses are connected. Open the hinges and check Bluetooth."
            case .noEligibleDevice(let why): return "Glasses aren't ready for a session: \(why)"
            case .sessionFailed(let why): return "Glasses session failed: \(why)"
            case .captureTimedOut: return "The glasses didn't return a photo in time."
            case .photoDecodeFailed: return "The photo from the glasses couldn't be read."
            case .speechRecognizerUnavailable: return "Speech recognition isn't available on this device."
            case .speechPermissionDenied: return "Speech recognition permission was denied."
            case .noAudioInput: return "No microphone input is available."
            }
        }
    }

    // MARK: - Connection state (observed by GlassesView)

    /// Per-glasses status the SDK exposes; this is what decides whether a
    /// session can start (both must be good for AutoDeviceSelector to pick it).
    struct DeviceStatus: Identifiable, Equatable {
        let id: DeviceIdentifier
        let name: String
        let linkState: LinkState
        let compatibility: Compatibility

        var isEligible: Bool { linkState == .connected && compatibility == .compatible }
    }

    @Published private(set) var registrationState: RegistrationState
    @Published private(set) var devices: [DeviceIdentifier]
    @Published private(set) var deviceStatuses: [DeviceStatus] = []
    @Published private(set) var isListening = false
    @Published private(set) var lastTranscript: String?
    @Published private(set) var lastError: String?

    /// Same debug hook as `MockGlassesSession.onSpeak` so `SchedulingView` can
    /// show what was said regardless of which session is wired in.
    var onSpeak: ((String) -> Void)?

    private let wearables: WearablesInterface
    /// Long-lived on purpose: the selector resolves its `activeDevice`
    /// asynchronously from the SDK's device/link streams. Creating one right
    /// before `createSession` (as an earlier version did) raced that and threw
    /// `noEligibleDevice` for glasses that were plainly connected.
    private let deviceSelector: AutoDeviceSelector
    private var registrationTask: Task<Void, Never>?
    private var devicesTask: Task<Void, Never>?
    private var deviceListenerTokens: [DeviceIdentifier: [AnyListenerToken]] = [:]

    // MARK: - Audio

    private let synthesizer = AVSpeechSynthesizer()
    private var speakContinuation: CheckedContinuation<Void, Never>?
    private let audioEngine = AVAudioEngine()
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var onTranscript: ((String) -> Void)?
    private var audioObservers: [NSObjectProtocol] = []

    override init() {
        let wearables = Wearables.shared
        self.wearables = wearables
        self.deviceSelector = AutoDeviceSelector(wearables: wearables)
        self.registrationState = wearables.registrationState
        self.devices = wearables.devices
        super.init()
        synthesizer.delegate = self

        registrationTask = Task { [weak self] in
            for await state in wearables.registrationStateStream() {
                self?.registrationState = state
            }
        }
        devicesTask = Task { [weak self] in
            for await devices in wearables.devicesStream() {
                self?.devices = devices
                self?.trackDevices(devices)
            }
        }
        trackDevices(wearables.devices)
        observeAudioInterruptions()
    }

    /// The listener has to outlive whatever iOS does to the audio session: a
    /// phone call (which "Hey Dojo, call my daughter" itself causes) interrupts
    /// it, and the glasses connecting or disconnecting changes the engine's
    /// input format. Either silently stops the engine; without this the wake
    /// word would be dead until the app relaunched.
    private func observeAudioInterruptions() {
        let center = NotificationCenter.default
        audioObservers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            Task { @MainActor [weak self] in
                guard let self, self.isListening else { return }
                switch type {
                case .began:
                    self.tearDownRecognition(deactivateSession: false)
                case .ended:
                    await self.restartRecognition()
                @unknown default:
                    break
                }
            }
        })
        audioObservers.append(center.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: audioEngine, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isListening else { return }
                await self.restartRecognition()
            }
        })
    }

    private func restartRecognition() async {
        tearDownRecognition(deactivateSession: false)
        try? await Task.sleep(nanoseconds: 300_000_000)
        await beginRecognition()
    }

    /// Mirrors each device's link state + compatibility into `deviceStatuses`,
    /// re-reading on every change the SDK announces.
    private func trackDevices(_ identifiers: [DeviceIdentifier]) {
        let current = Set(identifiers)
        deviceListenerTokens = deviceListenerTokens.filter { current.contains($0.key) }

        for id in identifiers where deviceListenerTokens[id] == nil {
            guard let device = wearables.deviceForIdentifier(id) else { continue }
            let refresh: @Sendable () -> Void = { [weak self] in
                Task { @MainActor [weak self] in self?.refreshDeviceStatuses() }
            }
            deviceListenerTokens[id] = [
                device.addLinkStateListener { _ in refresh() },
                device.addCompatibilityListener { _ in refresh() },
            ]
        }
        refreshDeviceStatuses()
    }

    private func refreshDeviceStatuses() {
        deviceStatuses = devices.compactMap { id in
            guard let device = wearables.deviceForIdentifier(id) else { return nil }
            return DeviceStatus(
                id: id,
                name: device.nameOrId(),
                linkState: device.linkState,
                compatibility: device.compatibility()
            )
        }
    }

    /// Human-readable reason AutoDeviceSelector has nothing to pick, so the
    /// wearer/dev gets "open the hinges" or "update firmware" instead of an
    /// opaque `noEligibleDevice`.
    private func eligibilityProblem() -> String {
        refreshDeviceStatuses()
        guard let status = deviceStatuses.first else {
            return "Meta AI hasn't reported any glasses. Are they paired and on?"
        }
        switch (status.linkState, status.compatibility) {
        case (.disconnected, _):
            return "\(status.name) isn't connected over Bluetooth. Open the hinges / take them out of the case, make sure they show as connected in Meta AI, and check Developer Mode is on for these glasses (Meta AI → Settings → your glasses)."
        case (.connecting, _):
            return "\(status.name) is still connecting — try again in a few seconds."
        case (_, .deviceUpdateRequired):
            return "\(status.name) needs a firmware update (Meta AI → your glasses → update)."
        case (_, .sdkUpdateRequired):
            return "This app's DAT SDK is too old for \(status.name) — bump meta-wearables-dat-ios in project.yml."
        case (_, .undefined):
            return "The SDK hasn't determined compatibility for \(status.name) yet — try again in a few seconds."
        case (.connected, .compatible):
            return "\(status.name) looks eligible — this may be a transient SDK state; try again."
        @unknown default:
            return "\(status.name) is in a state this build doesn't recognize (link: \(status.linkState), compat: \(status.compatibility))."
        }
    }

    func openFirmwareUpdate() async {
        do { try await wearables.openFirmwareUpdate() } catch { lastError = error.localizedDescription }
    }

    // MARK: - Registration (one-time handoff to the Meta AI app)

    var isRegistered: Bool { registrationState == .registered }

    func connect() async {
        guard registrationState != .registering else { return }
        do {
            try await wearables.startRegistration()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func disconnect() async {
        do {
            try await wearables.startUnregistration()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Meta AI calls back into the app via `brownmellon://` — route it here
    /// from `.onOpenURL` so the SDK can finish registration/permission flows.
    static func handle(url: URL) async {
        _ = try? await Wearables.shared.handleUrl(url)
    }

    // MARK: - GlassesSession: speak

    func speak(_ text: String) async {
        onSpeak?(text)
        Self.configureAudioSession()

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")

        // Await completion so callers (e.g. SchedulingCoordinator resetting its
        // wake-word cooldown) don't run ahead of the audio actually finishing.
        await withCheckedContinuation { continuation in
            speakContinuation = continuation
            synthesizer.speak(utterance)
        }
    }

    // MARK: - GlassesSession: listen

    func startListening(onTranscript: @escaping (String) -> Void) {
        guard !isListening else { return }
        self.onTranscript = onTranscript
        isListening = true
        Task { await beginRecognition() }
    }

    func stopListening() {
        isListening = false
        onTranscript = nil
        tearDownRecognition(deactivateSession: true)
    }

    private func beginRecognition() async {
        guard isListening else { return }

        // Ask for the mic explicitly (rather than relying on the engine start to
        // prompt) so a denial shows up as a readable error instead of a silent
        // zero-format input.
        guard await AVAudioApplication.requestRecordPermission() else {
            lastError = "Microphone permission was denied — enable it in Settings → Brownmellon."
            isListening = false
            return
        }

        let authorized = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
        guard authorized else {
            lastError = SessionError.speechPermissionDenied.localizedDescription
            isListening = false
            return
        }
        guard let speechRecognizer, speechRecognizer.isAvailable else {
            lastError = SessionError.speechRecognizerUnavailable.localizedDescription
            isListening = false
            return
        }

        Self.configureAudioSession()

        // New recognizer segment: tell the consumer that earlier speech is
        // gone from the transcript (see the GlassesSession protocol doc).
        onTranscript?("")

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // Prefer on-device (privacy, offline) but don't *require* it — on a
        // phone that hasn't downloaded the language assets, requiring it makes
        // every request fail instantly, which looked like "the wake word
        // doesn't work" on first hardware test.
        request.requiresOnDeviceRecognition = false
        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        let format = inputNode.inputFormat(forBus: 0)
        // A zero format (no mic / permission denied) makes installTap throw an
        // uncatchable ObjC exception — same guard Meta's sample uses.
        guard format.sampleRate > 0, format.channelCount > 0 else {
            lastError = SessionError.noAudioInput.localizedDescription
            isListening = false
            return
        }

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }

        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self, self.isListening else { return }
                if let result {
                    let text = result.bestTranscription.formattedString
                    self.lastTranscript = text
                    self.onTranscript?(text)
                }
                // Apple ends a recognition task after ~1 minute of audio (or on
                // error). The wake word has to stay live indefinitely, so roll
                // into a fresh request — with a short pause on error so a
                // persistently failing recognizer doesn't spin at 100% CPU.
                if let error {
                    let nsError = error as NSError
                    // 1110 = "no speech detected" (a normal timeout), 216 = cancelled by us.
                    if nsError.code != 1110 && nsError.code != 216 {
                        self.lastError = "Speech recognition: \(error.localizedDescription)"
                    }
                    self.tearDownRecognition(deactivateSession: false)
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    await self.beginRecognition()
                } else if result?.isFinal == true {
                    self.tearDownRecognition(deactivateSession: false)
                    await self.beginRecognition()
                }
            }
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            lastError = "Couldn't start the microphone: \(error.localizedDescription)"
            isListening = false
        }
    }

    private func tearDownRecognition(deactivateSession: Bool) {
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        if deactivateSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    /// `.playAndRecord` + Bluetooth so both the mic tap and TTS ride the
    /// glasses' HFP link instead of the phone's own mic/speaker.
    private static func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.allowBluetoothHFP, .allowBluetoothA2DP, .duckOthers]
            )
            try session.setActive(true)
        } catch {
            // Falls back to whatever route iOS picks; worst case the phone's own
            // mic/speaker are used, which still demos the software path.
        }
    }

    // MARK: - GlassesSession: capturePhoto (DAT)

    func capturePhoto() async throws -> UIImage {
        do {
            return try await capturePhotoUnrecorded()
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    private func capturePhotoUnrecorded() async throws -> UIImage {
        guard isRegistered else { throw SessionError.notRegistered }
        guard !devices.isEmpty else { throw SessionError.noDevice }

        if try await wearables.checkPermissionStatus(.camera) != .granted {
            // Opens the Meta AI app; resumes when the user comes back.
            guard try await wearables.requestPermission(.camera) == .granted else {
                throw SessionError.cameraPermissionDenied
            }
        }

        // Give the selector a moment to settle on a device if it hasn't yet
        // (e.g. first capture right after registration / hinges just opened).
        if deviceSelector.activeDevice == nil {
            let problem = eligibilityProblem()
            let selector = deviceSelector
            try await Self.withTimeout(seconds: 5, or: SessionError.noEligibleDevice(problem)) {
                for await device in selector.activeDeviceStream() where device != nil { return }
                throw SessionError.noEligibleDevice(problem)
            }
        }

        let session: DeviceSession
        do {
            session = try wearables.createSession(deviceSelector: deviceSelector)
        } catch DeviceSessionError.noEligibleDevice {
            throw SessionError.noEligibleDevice(eligibilityProblem())
        } catch {
            throw SessionError.sessionFailed(String(describing: error))
        }
        defer { session.stop() }

        try session.start()
        try await Self.withTimeout(seconds: 15, or: SessionError.sessionFailed("timed out connecting")) {
            for await state in session.stateStream() {
                if state == .started { return }
                if state == .stopped { throw SessionError.sessionFailed("session stopped before it started") }
            }
            throw SessionError.sessionFailed("session state stream ended")
        }

        // We only need the stream up to take a still; keep the video side as
        // cheap as the SDK allows (lowest resolution, minimum valid frame rate).
        let config = StreamConfiguration(videoCodec: .raw, resolution: .low, frameRate: 2)
        guard let camera = try session.addCamera(config: config) else {
            throw SessionError.sessionFailed("couldn't attach the camera")
        }
        defer { camera.stop() }
        let stream = camera.stream

        let tokens = ListenerTokenBag()
        defer { tokens.clear() }

        // Wait for .streaming before asking for a photo — capturePhoto returns
        // false if the stream isn't live yet. Publisher callbacks arrive on the
        // SDK's own queue, so the resume-once guard has to be thread-safe: a
        // double resume of a CheckedContinuation is a hard crash.
        try await Self.withTimeout(seconds: 15, or: SessionError.sessionFailed("timed out starting the camera")) {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let once = ResumeOnce()
                stream.statePublisher.listen { state in
                    switch state {
                    case .streaming:
                        if once.claim() { continuation.resume() }
                    case .stopped:
                        if once.claim() { continuation.resume(throwing: SessionError.sessionFailed("camera stream stopped")) }
                    default:
                        break
                    }
                }.store(in: tokens)
                stream.start()
            }
        }

        let data: Data = try await Self.withTimeout(seconds: 10, or: SessionError.captureTimedOut) {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                let once = ResumeOnce()
                stream.photoDataPublisher.listen { photo in
                    if once.claim() { continuation.resume(returning: photo.data) }
                }.store(in: tokens)
                stream.errorPublisher.listen { error in
                    if once.claim() { continuation.resume(throwing: SessionError.sessionFailed(String(describing: error))) }
                }.store(in: tokens)

                if !stream.capturePhoto(format: .jpeg), once.claim() {
                    continuation.resume(throwing: SessionError.sessionFailed("capturePhoto was rejected"))
                }
            }
        }

        guard let image = UIImage(data: data) else { throw SessionError.photoDecodeFailed }
        return image
    }

    private static func withTimeout<T: Sendable>(
        seconds: Double,
        or timeoutError: Error,
        _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw timeoutError
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}

/// Thread-safe "first caller wins" flag for resuming a continuation from
/// callbacks that may race on different queues.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !claimed else { return false }
        claimed = true
        return true
    }
}

// MARK: - AVSpeechSynthesizerDelegate

extension DATGlassesSession: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finishSpeaking() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finishSpeaking() }
    }

    private func finishSpeaking() {
        speakContinuation?.resume()
        speakContinuation = nil
    }
}
