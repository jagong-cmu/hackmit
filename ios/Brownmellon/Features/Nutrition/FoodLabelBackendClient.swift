import Foundation
import UIKit

/// The one thing the view model needs from the network: a photo in, a
/// `FoodLabelResult` out. Behind a protocol so tests inject a stub that
/// returns a fixture and counts calls — the voice-path tests depend on it.
protocol FoodLabelExtracting {
    /// `maxDimension` is the upload's long-edge cap in pixels — 2048 by
    /// default, 3000 on the one legibility retry (PRD § Image quality).
    func extract(_ image: UIImage, maxDimension: CGFloat) async throws -> FoodLabelResult
}

/// Talks to the backend's `api/food-label.ts` endpoint. Same one-photo-in,
/// one-JSON-result-out shape as `ScamCheckBackendClient`, which it copies.
/// The diet profile is never part of the request — the backend only ever
/// sees the photo.
struct FoodLabelBackendClient: FoodLabelExtracting {
    var baseURL: URL = {
        if let override = Bundle.main.object(forInfoDictionaryKey: "BROWNMELLON_BACKEND_URL") as? String,
           let url = URL(string: override) {
            return url
        }
        return URL(string: "http://localhost:3000")!
    }()

    var session: URLSession = .shared

    func extract(_ image: UIImage, maxDimension: CGFloat = 2048) async throws -> FoodLabelResult {
        guard let jpegData = image.uploadJPEGData(maxDimension: maxDimension) else {
            throw FoodLabelBackendError.imageEncodingFailed
        }

        var request = URLRequest(url: baseURL.appendingPathComponent("api/food-label"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["imageBase64": jpegData.base64EncodedString()])

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw FoodLabelBackendError.serverError((response as? HTTPURLResponse)?.statusCode ?? -1)
        }

        return try JSONDecoder().decode(FoodLabelResult.self, from: data)
    }
}

enum FoodLabelBackendError: Error, Equatable {
    case imageEncodingFailed
    case serverError(Int)

    /// Gemini's free tier maps to a 429 on the backend — the wearer hears
    /// `BackendErrors.quotaMessage` for it, same as the other camera features.
    var isQuotaExceeded: Bool { self == .serverError(429) }
}
