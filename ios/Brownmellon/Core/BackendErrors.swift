import Foundation

/// Backend failures the wearer should hear a specific sentence for, shared by
/// every feature that calls the Vercel functions.
enum BackendErrors {
    /// Gemini's free tier is 20 requests/day/model; the backend maps that to 429.
    static let quotaMessage = "I've hit my daily limit for reading things. Please try again later."

    static func isQuotaExceeded(_ error: Error) -> Bool {
        switch error {
        case VisionBackendError.serverError(429), ScamCheckBackendError.serverError(429):
            return true
        default:
            return false
        }
    }

    /// What to say for a caught backend error, given the feature's own
    /// generic message for everything else.
    static func spokenMessage(for error: Error, otherwise generic: String) -> String {
        isQuotaExceeded(error) ? quotaMessage : generic
    }
}
