import Foundation
import Combine

/// All of the wearer's notes, as one array under a single `SecureLocalStore`
/// key — the same shape as emergency contacts, so the Keychain-backed store
/// is a straight swap for the in-memory mock.
///
/// Kept newest-first. Capped at `capacity`: when an insert goes past it, the
/// oldest *non-parking* note is dropped first, so "where did I park?" keeps
/// working no matter how many small facts pile up.
@MainActor
final class MemoryStore: ObservableObject {
    static let storageKey = "memoryNotes"
    static let capacity = 300

    /// Newest first.
    @Published private(set) var notes: [MemoryNote] = []
    @Published private(set) var lastError: String?

    /// False when backed by `MockSecureLocalStore` (tests): notes then
    /// live only until relaunch, and the tab's empty state says so.
    let isPersistent: Bool

    private let store: SecureLocalStore

    init(store: SecureLocalStore) {
        self.store = store
        isPersistent = !(store is MockSecureLocalStore)
        load()
    }

    func load() {
        do {
            let loaded: [MemoryNote]? = try store.load(forKey: Self.storageKey)
            notes = Self.newestFirst(loaded ?? [])
        } catch {
            lastError = "Couldn't load saved notes."
        }
    }

    var newestParking: MemoryNote? {
        notes.first { $0.kind == .parking }
    }

    /// Newest general note that talks about the car ("the car is in lot B") —
    /// the fallback answer to "where's my car" when nothing was saved as parking.
    var newestGeneralMentioningCar: MemoryNote? {
        notes.first { note in
            note.kind == .general && note.text.split(separator: " ").contains { word in
                word == "car" || word.hasPrefix("park")
            }
        }
    }

    var newest: MemoryNote? { notes.first }

    /// The most recent `count` notes, newest first — what general recall
    /// sends to the backend.
    func recent(_ count: Int) -> [MemoryNote] {
        Array(notes.prefix(count))
    }

    /// Inserts, prunes past the cap, and persists. Nothing changes in memory
    /// unless the write succeeded, so a Keychain failure can't leave the
    /// screen showing a note that won't come back.
    func add(_ note: MemoryNote) throws {
        var updated = notes
        let insertAt = updated.firstIndex { $0.createdAt <= note.createdAt } ?? updated.endIndex
        updated.insert(note, at: insertAt)
        try commit(Self.pruned(updated, capacity: Self.capacity))
    }

    func remove(id: UUID) throws {
        try commit(notes.filter { $0.id != id })
    }

    func removeAll() throws {
        try commit([])
    }

    private func commit(_ updated: [MemoryNote]) throws {
        do {
            try store.save(updated, forKey: Self.storageKey)
        } catch {
            lastError = "Couldn't save your notes."
            throw error
        }
        notes = updated
        lastError = nil
    }

    // MARK: - Pure helpers (tested)

    static func newestFirst(_ notes: [MemoryNote]) -> [MemoryNote] {
        notes.sorted { $0.createdAt > $1.createdAt }
    }

    /// `notes` must be newest-first. Drops from the old end until at most
    /// `capacity` remain, preferring non-parking notes; parking notes go only
    /// when nothing else is left to drop.
    static func pruned(_ notes: [MemoryNote], capacity: Int) -> [MemoryNote] {
        var result = notes
        while result.count > capacity {
            if let index = result.lastIndex(where: { $0.kind != .parking }) {
                result.remove(at: index)
            } else {
                result.removeLast()
            }
        }
        return result
    }
}
