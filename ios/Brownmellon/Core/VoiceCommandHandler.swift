import Foundation

/// A feature that can act on a "Hey Dojo" command. `command` is already
/// lower-cased and punctuation-stripped by `WakeWordDetector.normalize`.
/// Return true if you handled it (the coordinator then stops); false to let
/// the next handler — and finally the calendar intent parser — try.
///
/// Rule for implementers: return `false` fast for anything you don't own —
/// a couple of string checks, no network. Only claim the phrases listed in
/// your feature's PRD.
@MainActor
protocol VoiceCommandHandler: AnyObject {
    func handle(_ command: String) async -> Bool
}
