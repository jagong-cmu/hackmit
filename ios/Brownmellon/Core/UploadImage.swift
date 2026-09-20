import UIKit

extension UIImage {
    /// JPEG sized for a single-inference upload. Long edge capped at
    /// `maxDimension` px — enough for label-sized text, safely under
    /// Vercel's 4.5 MB body limit after base64.
    ///
    /// A real glasses frame is several MB as JPEG (and ~35% more as
    /// base64), so every camera client must go through this rather than
    /// `jpegData(compressionQuality:)` on the raw capture. Returns the
    /// original's JPEG when it's already within bounds.
    func uploadJPEGData(maxDimension: CGFloat = 2048, quality: CGFloat = 0.8) -> Data? {
        // Work in pixels: `size` is in points and camera images carry a scale.
        let pixelWidth = size.width * scale
        let pixelHeight = size.height * scale
        let longEdge = max(pixelWidth, pixelHeight)

        guard longEdge > maxDimension else {
            return jpegData(compressionQuality: quality)
        }

        let ratio = maxDimension / longEdge
        let targetPixels = CGSize(
            width: (pixelWidth * ratio).rounded(),
            height: (pixelHeight * ratio).rounded()
        )

        // `preparingThumbnail(of:)` takes its size in the receiver's points and
        // multiplies by the receiver's scale. Camera frames are scale 1, so
        // points are pixels; for anything else rebase to scale 1 first so the
        // cap is a pixel cap. Fall back to the full-size encode rather than
        // failing the upload if the thumbnail can't be made.
        let base = scale == 1
            ? self
            : cgImage.map { UIImage(cgImage: $0, scale: 1, orientation: imageOrientation) } ?? self
        let targetPoints = CGSize(
            width: targetPixels.width / base.scale,
            height: targetPixels.height / base.scale
        )
        let scaled = base.preparingThumbnail(of: targetPoints) ?? self
        return scaled.jpegData(compressionQuality: quality)
    }
}
