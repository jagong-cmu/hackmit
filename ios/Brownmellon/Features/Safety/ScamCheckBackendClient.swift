import Foundation
import UIKit

/// Talks to the backend's `api/scam-check.ts` endpoint (Workstream C).
/// Same one-photo-in, one-JSON-result-out shape as Vision's
/// `VisionBackendClient` — see that type for the pattern this follows.
struct ScamCheckBackendClient {
    struct Result: Codable, Equatable {
        var extractedText: String
        /// OCR-only signal — a text-pattern read, never a pixel-level
        /// determination (PRD § Feature 5 requirements).
        var aiGeneratedTextSignals: Bool
        var scamRisk: Risk
        var cues: [String]
        var safeAction: String
    }

    enum Risk: String, Codable {
        case high, medium, low
    }

    var baseURL: URL = {
        if let override = Bundle.main.object(forInfoDictionaryKey: "BROWNMELLON_BACKEND_URL") as? String,
           let url = URL(string: override) {
            return url
        }
        return URL(string: "http://localhost:3000")!
    }()

    func check(_ image: UIImage) async throws -> Result {
        guard let jpegData = image.jpegData(compressionQuality: 0.85) else {
            throw ScamCheckBackendError.imageEncodingFailed
        }

        var request = URLRequest(url: baseURL.appendingPathComponent("api/scam-check"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["imageBase64": jpegData.base64EncodedString()])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ScamCheckBackendError.serverError((response as? HTTPURLResponse)?.statusCode ?? -1)
        }

        return try JSONDecoder().decode(Result.self, from: data)
    }
}

enum ScamCheckBackendError: Error {
    case imageEncodingFailed
    case serverError(Int)
}
