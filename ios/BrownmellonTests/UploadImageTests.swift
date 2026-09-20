import XCTest
@testable import Brownmellon

/// Every camera client uploads through `uploadJPEGData()`. A real glasses
/// frame is several MB as JPEG — over Vercel's 4.5 MB body limit once
/// base64-encoded — so the long edge has to come down to 2048 px while the
/// aspect ratio survives, and small images must pass through untouched.
final class UploadImageTests: XCTestCase {
    /// Pixel dimensions of the JPEG that would actually be sent.
    private func uploadedPixelSize(of image: UIImage, maxDimension: CGFloat = 2048) throws -> (width: Int, height: Int) {
        let data = try XCTUnwrap(image.uploadJPEGData(maxDimension: maxDimension))
        let decoded = try XCTUnwrap(UIImage(data: data)?.cgImage)
        return (decoded.width, decoded.height)
    }

    private func solidImage(width: Int, height: Int, scale: CGFloat = 1) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            UIColor.black.setFill()
            context.fill(CGRect(x: width / 4, y: height / 4, width: width / 2, height: height / 2))
        }
    }

    func testLandscapeFrameIsCappedAt2048OnTheLongEdge() throws {
        let size = try uploadedPixelSize(of: solidImage(width: 4000, height: 3000))
        XCTAssertEqual(size.width, 2048)
        XCTAssertEqual(size.height, 1536)
    }

    func testPortraitFrameIsCappedAt2048OnTheLongEdge() throws {
        let size = try uploadedPixelSize(of: solidImage(width: 3000, height: 4000))
        XCTAssertEqual(size.width, 1536)
        XCTAssertEqual(size.height, 2048)
    }

    func testImageAlreadyWithinBoundsIsNotResized() throws {
        let size = try uploadedPixelSize(of: solidImage(width: 800, height: 600))
        XCTAssertEqual(size.width, 800)
        XCTAssertEqual(size.height, 600)
    }

    func testMeasuresInPixelsNotPoints() throws {
        // 1500×1000 points at 3x is a 4500×3000 px image — it must be scaled
        // even though its point size is comfortably under the cap.
        let size = try uploadedPixelSize(of: solidImage(width: 1500, height: 1000, scale: 3))
        XCTAssertEqual(size.width, 2048)
        XCTAssertEqual(size.height, 1365)
    }

    func testCustomMaxDimensionIsHonored() throws {
        let size = try uploadedPixelSize(of: solidImage(width: 4000, height: 3000), maxDimension: 3000)
        XCTAssertEqual(size.width, 3000)
        XCTAssertEqual(size.height, 2250)
    }

    func testOutputIsJPEG() throws {
        let data = try XCTUnwrap(solidImage(width: 4000, height: 3000).uploadJPEGData())
        XCTAssertEqual(Array(data.prefix(2)), [0xFF, 0xD8], "JPEG SOI marker")
    }
}
