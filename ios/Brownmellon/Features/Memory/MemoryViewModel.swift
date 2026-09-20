import Foundation
import Combine

/// Screen state for the Memory tab (PRD-memory § 9d) — a debugging and demo
/// surface over the same `MemoryCommandHandler` instance the voice path
/// uses, so what the list shows is exactly what the glasses know.
///
/// Typed commands go through the app-wide `VoiceAssistant`, i.e. the full
/// handler chain: "remember I parked in section B" lands here, "remind me to
/// take my pills at 8" still reaches the calendar — same as saying it.
@MainActor
final class MemoryViewModel: ObservableObject {
    @Published var draftCommand: String = ""
    @Published private(set) var lastResponse: String?
    @Published private(set) var notes: [MemoryNote] = []
    @Published private(set) var storeError: String?

    /// False when backed by the in-memory `MockSecureLocalStore` (tests):
    /// notes reset on relaunch, and the empty state says so.
    var notesPersist: Bool { handler.store.isPersistent }

    private let handler: MemoryCommandHandler
    private let assistant: VoiceAssistant
    private let directions: DirectionsOpener

    init(handler: MemoryCommandHandler, assistant: VoiceAssistant, directions: DirectionsOpener? = nil) {
        self.handler = handler
        self.assistant = assistant
        self.directions = directions ?? MapsDirectionsOpener()
        handler.store.$notes.assign(to: &$notes)
        handler.store.$lastError.assign(to: &$storeError)
        assistant.$lastResponse.assign(to: &$lastResponse)
    }

    /// Same path a real "Hey Dojo" utterance takes, minus the mic.
    func tryCommand() async {
        let command = draftCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }
        draftCommand = ""
        await assistant.handle(command)
    }

    func delete(_ note: MemoryNote) {
        try? handler.store.remove(id: note.id)
    }

    func delete(at offsets: IndexSet) {
        for note in offsets.compactMap({ notes.indices.contains($0) ? notes[$0] : nil }) {
            delete(note)
        }
    }

    func openDirections(to note: MemoryNote) {
        guard let coordinate = note.coordinate else { return }
        directions.openWalkingDirections(to: coordinate)
    }

    // MARK: - Display helpers

    static func title(for note: MemoryNote) -> String {
        let text = note.text.trimmingCharacters(in: .whitespaces)
        if !text.isEmpty { return MemorySpeech.spokenNoteText(text) }
        if let sign = note.signText, note.hasSignText { return "Parking spot — \(sign)" }
        return "Parking spot"
    }

    static func subtitle(for note: MemoryNote, now: Date = Date()) -> String {
        let when = ParkingSpeech.spokenElapsed(from: note.createdAt, to: now)
        return note.kind == .parking ? "Parking · \(when)" : when
    }
}
