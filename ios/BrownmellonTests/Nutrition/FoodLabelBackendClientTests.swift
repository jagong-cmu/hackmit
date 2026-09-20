import XCTest
@testable import Brownmellon

/// The wire contract with `api/food-label.ts`: a POST with `imageBase64` and
/// nothing else — the diet profile never crosses the wire — and the response
/// decodes into `FoodLabelResult` with nulls as nils.
final class FoodLabelBackendClientTests: XCTestCase {
    override func setUp() {
        super.setUp()
        FoodLabelEndpointStub.reset()
    }

    private func client() -> FoodLabelBackendClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FoodLabelEndpointStub.self]
        return FoodLabelBackendClient(
            baseURL: URL(string: "https://food.test")!,
            session: URLSession(configuration: config)
        )
    }

    func testRequestCarriesOnlyTheImage() async throws {
        FoodLabelEndpointStub.responseBody = try Data(contentsOf: XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "soup", withExtension: "json")
                ?? Bundle(for: Self.self).url(forResource: "soup", withExtension: "json", subdirectory: "Fixtures")
        ))

        let result = try await client().extract(FakeGlassesSession.blankPhoto(), maxDimension: 2048)

        XCTAssertEqual(FoodLabelEndpointStub.lastPath, "/api/food-label")
        XCTAssertEqual(FoodLabelEndpointStub.lastMethod, "POST")
        let body = try XCTUnwrap(FoodLabelEndpointStub.lastBodyJSON)
        XCTAssertEqual(Array(body.keys), ["imageBase64"], "the profile is never sent")
        let base64 = try XCTUnwrap(body["imageBase64"] as? String)
        let jpeg = try XCTUnwrap(Data(base64Encoded: base64))
        XCTAssertEqual(Array(jpeg.prefix(2)), [0xFF, 0xD8], "a JPEG")

        XCTAssertEqual(result.productName, "Campbell's Chicken Noodle Soup")
        XCTAssertEqual(result.nutrients.sodiumMg, 890)
        XCTAssertNil(result.nutrients.potassiumMg)
        XCTAssertEqual(result.ingredients.count, 16)
    }

    func testDecodesAMinimalResponse() async throws {
        FoodLabelEndpointStub.responseBody = Data(#"{"found":false,"nutrients":{},"ingredients":[],"claims":[],"fullText":""}"#.utf8)
        let result = try await client().extract(FakeGlassesSession.blankPhoto(), maxDimension: 2048)
        XCTAssertFalse(result.found)
        XCTAssertNil(result.productName)
        XCTAssertEqual(result.nutrients, FoodLabelResult.Nutrients())
    }

    func testNon2xxIsAServerError() async {
        FoodLabelEndpointStub.statusCode = 429
        do {
            _ = try await client().extract(FakeGlassesSession.blankPhoto(), maxDimension: 2048)
            XCTFail("expected an error")
        } catch let error as FoodLabelBackendError {
            XCTAssertEqual(error, .serverError(429))
            XCTAssertTrue(error.isQuotaExceeded)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }
}

/// Stands in for `api/food-label` at the URL-loading layer.
private final class FoodLabelEndpointStub: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _responseBody = Data("{}".utf8)
    nonisolated(unsafe) private static var _statusCode = 200
    nonisolated(unsafe) private static var _lastPath: String?
    nonisolated(unsafe) private static var _lastMethod: String?
    nonisolated(unsafe) private static var _lastBodyJSON: [String: Any]?

    static var responseBody: Data {
        get { lock.lock(); defer { lock.unlock() }; return _responseBody }
        set { lock.lock(); _responseBody = newValue; lock.unlock() }
    }

    static var statusCode: Int {
        get { lock.lock(); defer { lock.unlock() }; return _statusCode }
        set { lock.lock(); _statusCode = newValue; lock.unlock() }
    }

    static var lastPath: String? { lock.lock(); defer { lock.unlock() }; return _lastPath }
    static var lastMethod: String? { lock.lock(); defer { lock.unlock() }; return _lastMethod }
    static var lastBodyJSON: [String: Any]? { lock.lock(); defer { lock.unlock() }; return _lastBodyJSON }

    static func reset() {
        lock.lock()
        _responseBody = Data("{}".utf8)
        _statusCode = 200
        _lastPath = nil
        _lastMethod = nil
        _lastBodyJSON = nil
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let json = Self.bodyJSON(request)
        Self.lock.lock()
        Self._lastPath = request.url?.path
        Self._lastMethod = request.httpMethod
        Self._lastBodyJSON = json
        let body = Self._responseBody
        let status = Self._statusCode
        Self.lock.unlock()

        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// URLSession hands protocols the body as a stream, not `httpBody`.
    private static func bodyJSON(_ request: URLRequest) -> [String: Any]? {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            let bufferSize = 65_536
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: bufferSize)
                guard read > 0 else { break }
                data.append(buffer, count: read)
            }
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
