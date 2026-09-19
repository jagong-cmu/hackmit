import Foundation
import UIKit

/// Stand-in for the real DAT wrapper so every workstream can build before the
/// hardware integration lands. Swap for the real `GlassesSession` via rebase.
final class MockGlassesSession: GlassesSession {
    private(set) var spokenLines: [String] = []
    private(set) var isListening = false
    private var onTranscript: ((String) -> Void)?

    func speak(_ text: String) async {
        spokenLines.append(text)
        print("[glasses] \(text)")
    }

    func startListening(onTranscript: @escaping (String) -> Void) {
        self.onTranscript = onTranscript
        isListening = true
    }

    func stopListening() {
        isListening = false
        onTranscript = nil
    }

    func capturePhoto() async throws -> UIImage {
        UIImage(systemName: "photo") ?? UIImage()
    }

    /// Test hook — pretend the wearer said something out loud.
    func simulateTranscript(_ text: String) {
        onTranscript?(text)
    }
}
