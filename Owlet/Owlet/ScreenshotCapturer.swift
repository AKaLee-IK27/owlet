import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Captures a screen region as PNG data.
final class ScreenshotCapturer: @unchecked Sendable {

    /// Capture the given screen rect as PNG data.
    /// The rect is in screen coordinates (origin at bottom-left).
    func capture(region: CGRect) async -> Data? {
        guard let screenshot = CGDisplayCreateImage(CGMainDisplayID()) else {
            return nil
        }

        // CGDisplayCreateImage returns top-left origin; convert region.
        let screenHeight = CGFloat(CGDisplayPixelsHigh(CGMainDisplayID()))
        let cgRect = CGRect(
            x: region.origin.x,
            y: screenHeight - region.origin.y - region.height,
            width: region.width,
            height: region.height
        )

        guard let cropped = screenshot.cropping(to: cgRect) else {
            return nil
        }

        // Convert CGImage to PNG via CGImageDestination.
        guard let data = CFDataCreateMutable(nil, 0),
              let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, cropped, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}
