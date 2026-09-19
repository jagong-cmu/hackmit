import Foundation
import UIKit

/// Talks to the backend's `api/ocr.ts` endpoint (Workstream B's own
/// backend file — see PRD.md § Parallel workstreams). One endpoint,
/// two modes, since appointment-card scanning and "read this to me"
/// share the same photo -> vision-LLM pipeline and differ only in
/// what's asked of the model.
struct VisionBackendClient {
    enum Mode: String, Codable {
        case appointment
        case read
    }

    struct AppointmentResult: Codable {
        /// Populated only when the model found a plausible date/time —
        /// nil means "ask the wearer again," not a guess. The client
        /// (ViewModel) must never write an event without this being set
        /// and having gotten spoken confirmation (see PRD design principles).
        var title: String?
        var startISO8601: String?
        var endISO8601: String?
        var location: String?
    }

    struct ReadResult: Codable {
        var text: String
    }

    /// Defaults to the local `vercel dev` server. Override via the
    /// `BROWNMELLON_BACKEND_URL` Info.plist key once a real deployment
    /// exists (see backend/README or PRD § Deployment).
    var baseURL: URL = {
        if let override = Bundle.main.object(forInfoDictionaryKey: "BROWNMELLON_BACKEND_URL") as? String,
           let url = URL(string: override) {
            return url
        }
        return URL(string: "http://localhost:3000")!
    }()

    func scanAppointmentCard(_ image: UIImage) async throws -> AppointmentResult {
        try await post(image: image, mode: .appointment)
    }

    func readAloud(_ image: UIImage) async throws -> ReadResult {
        try await post(image: image, mode: .read)
    }

    private func post<T: Decodable>(image: UIImage, mode: Mode) async throws -> T {
        guard let jpegData = image.jpegData(compressionQuality: 0.85) else {
            throw VisionBackendError.imageEncodingFailed
        }

        var request = URLRequest(url: baseURL.appendingPathComponent("api/ocr"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = [
            "mode": mode.rawValue,
            "imageBase64": jpegData.base64EncodedString(),
        ]
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw VisionBackendError.serverError((response as? HTTPURLResponse)?.statusCode ?? -1)
        }

        return try JSONDecoder().decode(T.self, from: data)
    }
}

enum VisionBackendError: Error {
    case imageEncodingFailed
    case serverError(Int)
}
