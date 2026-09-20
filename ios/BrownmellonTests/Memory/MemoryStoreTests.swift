import XCTest
@testable import Brownmellon

/// The store is one Keychain item; these pin the cap, the prune order (old
/// general notes go before any parking note) and the round trip through
/// `SecureLocalStore`.
@MainActor
final class MemoryStoreTests: XCTestCase {
    private var secure: MockSecureLocalStore!
    private var store: MemoryStore!
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() async throws {
        try await super.setUp()
        secure = MockSecureLocalStore()
        store = MemoryStore(store: secure)
    }

    private func note(_ kind: MemoryNote.Kind, _ text: String, at offset: TimeInterval) -> MemoryNote {
        MemoryNote(kind: kind, text: text, createdAt: base.addingTimeInterval(offset))
    }

    // MARK: - Round trip

    func testNotesPersistThroughTheSecureStoreAndComeBackNewestFirst() throws {
        try store.add(note(.general, "first", at: 0))
        try store.add(note(.parking, "i parked in section b", at: 60))
        try store.add(note(.general, "third", at: 120))

        let reloaded = MemoryStore(store: secure)
        XCTAssertEqual(reloaded.notes.map(\.text), ["third", "i parked in section b", "first"])
        XCTAssertEqual(reloaded.newestParking?.text, "i parked in section b")
        XCTAssertEqual(reloaded.newest?.text, "third")
    }

    func testInMemoryBackingIsReportedAsNotPersistent() {
        XCTAssertFalse(store.isPersistent, "Simulator's MockSecureLocalStore resets on relaunch — the tab says so")
    }

    func testInsertKeepsNewestFirstEvenOutOfOrder() throws {
        try store.add(note(.general, "later", at: 100))
        try store.add(note(.general, "earlier", at: 50))
        XCTAssertEqual(store.notes.map(\.text), ["later", "earlier"])
    }

    // MARK: - Cap and prune

    func testCapIsThreeHundred() {
        XCTAssertEqual(MemoryStore.capacity, 300)
    }

    func testInsertPastTheCapDropsTheOldestGeneralNote() throws {
        for i in 0..<MemoryStore.capacity {
            try store.add(note(.general, "note \(i)", at: Double(i)))
        }
        XCTAssertEqual(store.notes.count, MemoryStore.capacity)

        try store.add(note(.general, "one more", at: 1000))

        XCTAssertEqual(store.notes.count, MemoryStore.capacity)
        XCTAssertEqual(store.notes.first?.text, "one more")
        XCTAssertFalse(store.notes.contains { $0.text == "note 0" }, "the oldest went")
        XCTAssertTrue(store.notes.contains { $0.text == "note 1" })
    }

    func testParkingSurvivesPruningEvenWhenItIsTheOldest() throws {
        try store.add(note(.parking, "i parked in section b", at: -1000))   // oldest of all
        for i in 0..<MemoryStore.capacity {
            try store.add(note(.general, "note \(i)", at: Double(i)))
        }

        XCTAssertEqual(store.notes.count, MemoryStore.capacity)
        XCTAssertEqual(store.newestParking?.text, "i parked in section b", "parking is protected from the cap")
        XCTAssertFalse(store.notes.contains { $0.text == "note 0" }, "the oldest *general* note went instead")
    }

    func testAllParkingFallsBackToDroppingTheOldestParking() {
        let notes = (0..<5).map { note(.parking, "p\($0)", at: Double(5 - $0)) }   // newest first
        let pruned = MemoryStore.pruned(notes, capacity: 3)
        XCTAssertEqual(pruned.map(\.text), ["p0", "p1", "p2"])
    }

    func testPrunedIsPureAndOrderPreserving() {
        let notes: [MemoryNote] = [
            note(.general, "g-new", at: 5),
            note(.parking, "p-mid", at: 4),
            note(.general, "g-mid", at: 3),
            note(.parking, "p-old", at: 2),
            note(.general, "g-old", at: 1),
        ]
        XCTAssertEqual(MemoryStore.pruned(notes, capacity: 5).map(\.text), notes.map(\.text), "under the cap nothing changes")
        XCTAssertEqual(MemoryStore.pruned(notes, capacity: 3).map(\.text), ["g-new", "p-mid", "p-old"])
        XCTAssertEqual(MemoryStore.pruned(notes, capacity: 2).map(\.text), ["p-mid", "p-old"], "general notes all go before any parking note")
        XCTAssertEqual(MemoryStore.pruned(notes, capacity: 1).map(\.text), ["p-mid"])
    }

    // MARK: - Remove

    func testRemoveByIdAndRemoveAll() throws {
        let a = note(.general, "a", at: 0)
        let b = note(.parking, "b", at: 1)
        try store.add(a)
        try store.add(b)

        try store.remove(id: a.id)
        XCTAssertEqual(store.notes.map(\.text), ["b"])
        XCTAssertEqual(MemoryStore(store: secure).notes.map(\.text), ["b"], "removal is persisted")

        try store.removeAll()
        XCTAssertTrue(store.notes.isEmpty)
        XCTAssertTrue(MemoryStore(store: secure).notes.isEmpty)
    }

    func testRecentReturnsAtMostTheRequestedCount() throws {
        for i in 0..<5 {
            try store.add(note(.general, "note \(i)", at: Double(i)))
        }
        XCTAssertEqual(store.recent(3).map(\.text), ["note 4", "note 3", "note 2"])
        XCTAssertEqual(store.recent(10).count, 5)
    }

    // MARK: - Failure

    func testFailedWriteLeavesNotesUnchanged() {
        let failing = FailingSecureLocalStore()
        let store = MemoryStore(store: failing)
        XCTAssertThrowsError(try store.add(note(.general, "x", at: 0)))
        XCTAssertTrue(store.notes.isEmpty, "nothing shows on screen that isn't saved")
        XCTAssertNotNil(store.lastError)
    }
}

private final class FailingSecureLocalStore: SecureLocalStore {
    struct Failure: Error {}
    func save<T: Codable>(_ value: T, forKey key: String) throws { throw Failure() }
    func load<T: Codable>(forKey key: String) throws -> T? { nil }
}
