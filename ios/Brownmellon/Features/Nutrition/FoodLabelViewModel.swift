import Foundation
import UIKit

/// Feature 10 — Food Label Reader with Diet Check (PRD-food-label). One
/// photo, one backend call, two spoken modes ("read this label" / "can I eat
/// this?") and follow-up questions answered from the cached label without a
/// new photo.
///
/// This is a `VoiceCommandHandler`: the product trigger is "Hey Dojo, …"
/// through `VoiceAssistant` → `SchedulingCoordinator` → `handle(_:)`. The
/// buttons on `FoodLabelView` call the same `run(_:)` and exist for Simulator
/// use only. `BrownmellonApp` owns one instance and passes it to both.
///
/// Extraction is remote (Gemini reads the tiny print), judgment is local
/// (`DietaryFitEvaluator`), and the diet profile never leaves the phone.
@MainActor
final class FoodLabelViewModel: ObservableObject, VoiceCommandHandler {
    enum State: Equatable {
        case idle
        case capturing
        case reading
        case done
        case failed(String)
    }

    /// Follow-ups reuse the last label for this long without a new photo.
    static let cacheLifetime: TimeInterval = 5 * 60
    /// Check mode and a fresh "read this label" re-photograph unless the
    /// previous command was on this same label within this window.
    static let sameLabelWindow: TimeInterval = 60
    static let defaultMaxDimension: CGFloat = 2048
    static let retryMaxDimension: CGFloat = 3000
    /// Retry at the larger size when at least this many needed nutrients came
    /// back `nil` from a label the model did find.
    static let unreadableRetryThreshold = 3

    @Published private(set) var state: State = .idle
    /// The last thing this feature said — shown on the phone screen.
    @Published private(set) var lastSpoken: String?
    /// The most recent label with `found == true`, for follow-ups and the
    /// debug dump on `FoodLabelView`.
    @Published private(set) var lastLabel: FoodLabelResult?
    @Published private(set) var lastAssessment: FitAssessment?

    private let glasses: GlassesSession
    private let store: SecureLocalStore
    private let backend: FoodLabelExtracting
    private let now: () -> Date
    private var lastLabelAt: Date?
    private var lastCommandAt: Date?

    init(
        glasses: GlassesSession,
        store: SecureLocalStore,
        backend: FoodLabelExtracting = FoodLabelBackendClient(),
        now: @escaping () -> Date = Date.init
    ) {
        self.glasses = glasses
        self.store = store
        self.backend = backend
        self.now = now
    }

    /// Read fresh on every command so a profile the caregiver just saved in
    /// Setup applies immediately. Never sent anywhere.
    var profile: DietaryProfile {
        let loaded: DietaryProfile? = try? store.load(forKey: DietaryProfile.storageKey)
        return loaded ?? DietaryProfile()
    }

    var isBusy: Bool { state == .capturing || state == .reading }

    // MARK: - VoiceCommandHandler

    /// Claims only the phrases in `FoodLabelCommandParser`; everything else
    /// returns false immediately so Feature 4's "read this to me" and
    /// Feature 5's "check this ad" keep working.
    func handle(_ command: String) async -> Bool {
        guard let parsed = FoodLabelCommandParser.parse(command) else { return false }
        await run(parsed)
        return true
    }

    // MARK: - Simulator buttons

    func readLabel() async { await run(.read(.headline)) }
    func checkFood() async { await run(.check) }

    // MARK: - The pipeline

    func run(_ command: FoodLabelCommand) async {
        if isBusy {
            await speak("One moment — I'm still reading the last label.")
            return
        }

        // "what else" only ever refers to the last check; no photo.
        if case .question(.whatElse) = command {
            await speak(FoodLabelSpeech.whatElseScript(lastAssessment))
            return
        }

        let fromCache: Bool
        let label: FoodLabelResult
        if let cached = cachedLabel(for: command) {
            label = cached
            fromCache = true
        } else {
            guard let fresh = await captureAndExtract() else { return }
            label = fresh
            fromCache = false
        }

        guard label.found else {
            // Not stamped as a command "on this label": a check that follows
            // a failed capture must re-photograph, not replay the older label.
            lastAssessment = FitAssessment(verdict: .notALabel, findings: [], servingsPerContainer: nil)
            await speak(FoodLabelSpeech.notALabelScript)
            return
        }
        lastCommandAt = now()

        let profile = self.profile
        var text: String
        switch command {
        case .read(.headline):
            text = FoodLabelSpeech.readHeadline(label)
        case .read(.ingredients):
            text = FoodLabelSpeech.ingredientsScript(label)
        case .read(.nutrition):
            text = FoodLabelSpeech.nutrientsSentence(label)
        case .read(.everything):
            text = FoodLabelSpeech.everythingScript(label)
        case .check:
            let assessment = DietaryFitEvaluator.evaluate(profile, label)
            lastAssessment = assessment
            text = FoodLabelSpeech.checkScript(assessment, label: label, profile: profile)
        case .question(let kind):
            text = FoodLabelSpeech.questionScript(kind, label: label, profile: profile)
        }

        if fromCache {
            text = FoodLabelSpeech.cachePrefix + text
        }
        await speak(text)
    }

    /// The cached label, when this command may answer from it (PRD § 10b):
    /// questions and read follow-ups within 5 minutes; check mode and a fresh
    /// "read this label" only within 60 s of the last command on this label.
    private func cachedLabel(for command: FoodLabelCommand) -> FoodLabelResult? {
        guard let lastLabel, let lastLabelAt else { return nil }
        let current = now()
        guard current.timeIntervalSince(lastLabelAt) < Self.cacheLifetime else { return nil }

        switch command {
        case .check, .read(.headline):
            guard let lastCommandAt,
                  current.timeIntervalSince(lastCommandAt) < Self.sameLabelWindow else { return nil }
            return lastLabel
        case .read, .question:
            return lastLabel
        }
    }

    /// Photo → downscaled upload → `FoodLabelResult`, with one retry at a
    /// larger size when the label was found but the numbers this profile needs
    /// weren't legible. Speaks the failure and returns nil on error.
    private func captureAndExtract() async -> FoodLabelResult? {
        state = .capturing
        do {
            let photo = try await glasses.capturePhoto()
            state = .reading
            var result = try await backend.extract(photo, maxDimension: Self.defaultMaxDimension)

            if result.found, Self.unreadableNeededCount(result, profile) >= Self.unreadableRetryThreshold,
               let retried = try? await backend.extract(photo, maxDimension: Self.retryMaxDimension),
               retried.found,
               Self.unreadableNeededCount(retried, profile) < Self.unreadableNeededCount(result, profile) {
                result = retried
            }

            state = .done
            if result.found {
                lastLabel = result
                lastLabelAt = now()
            }
            return result
        } catch {
            state = .failed(String(describing: error))
            await speak(Self.spokenError(error))
            return nil
        }
    }

    /// How many of the nutrients this profile's rules read came back `nil`.
    /// With no nutrient rules active, the read-mode headline fields stand in.
    static func unreadableNeededCount(_ label: FoodLabelResult, _ profile: DietaryProfile) -> Int {
        let n = label.nutrients
        var needed: [Double?] = []
        for restriction in profile.activeNutrientRestrictions {
            switch restriction {
            case .sodium: needed.append(n.sodiumMg)
            case .carbs: needed += [n.totalCarbohydrateG, n.addedSugarsG]
            case .saturatedFat: needed += [n.saturatedFatG, n.transFatG]
            case .potassium: needed.append(n.potassiumMg)
            case .gluten, .allergy, .avoid: break
            }
        }
        if needed.isEmpty {
            needed = [n.calories, n.sodiumMg, n.totalCarbohydrateG, n.totalFatG, n.proteinG]
        }
        return needed.filter { $0 == nil }.count
    }

    static func spokenError(_ error: Error) -> String {
        if let backendError = error as? FoodLabelBackendError {
            return backendError.isQuotaExceeded
                ? BackendErrors.quotaMessage
                : "Something went wrong reading that label. Let's try again."
        }
        if error is MockGlassesSessionError {
            return "I couldn't take a photo. Let's try again."
        }
        return "Something went wrong reading that label. Let's try again."
    }

    private func speak(_ text: String) async {
        lastSpoken = text
        await glasses.speak(text)
    }
}
