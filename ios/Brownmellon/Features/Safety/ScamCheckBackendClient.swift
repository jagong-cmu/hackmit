import Foundation
import UIKit

/// Stateless client for the multimodal Feature 5 endpoint. The transport is
/// injectable so ViewModel tests never need a live backend or Gemini key.
struct ScamCheckBackendClient {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    struct Result: Codable, Equatable {
        var riskLevel: Risk
        var spokenSummary: String
        var extractedText: String
        var observedSignals: [String]
        var verifiedFindings: [VerifiedFinding]
        var aiAppearance: AIAppearance
        var safeAction: String
        var webVerificationAvailable: Bool
    }

    struct VerifiedFinding: Codable, Equatable, Identifiable {
        var claim: String
        var status: VerificationStatus
        var sourceTitle: String
        var sourceURL: String

        var id: String { "\(claim)|\(sourceURL)" }
    }

    enum Risk: String, Codable {
        case high
        case medium
        case low
        case unknown
    }

    enum VerificationStatus: String, Codable {
        case supports
        case contradicts
        case unresolved
    }

    enum AIAppearance: String, Codable {
        case possible
        case unknown
    }

    var baseURL: URL
    private let transport: Transport

    init(
        baseURL: URL = {
            if let override = Bundle.main.object(forInfoDictionaryKey: "BROWNMELLON_BACKEND_URL") as? String,
               let url = URL(string: override) {
                return url
            }
            return URL(string: "http://localhost:3000")!
        }(),
        transport: @escaping Transport = { request in
            try await URLSession.shared.data(for: request)
        }
    ) {
        self.baseURL = baseURL
        self.transport = transport
    }

    func check(_ image: UIImage) async throws -> Result {
        guard let jpegData = image.jpegData(compressionQuality: 0.85) else {
            throw ScamCheckBackendError.imageEncodingFailed
        }

        var request = URLRequest(url: baseURL.appendingPathComponent("api/scam-check"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["imageBase64": jpegData.base64EncodedString()])

        let (data, response) = try await transport(request)
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
