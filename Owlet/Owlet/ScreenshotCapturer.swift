import Foundation
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Captures a screen region as PNG data.
final class ScreenshotCapturer: @unchecked Sendable {

    /// Capture the given region as PNG data. `region` is in global AppKit screen
    /// coordinates (bottom-left origin, points), as returned by
    /// `RegionSelectorController.selectRegion()`. The capture targets whichever
    /// display contains the region's center, at that display's full pixel
    /// resolution (Retina-aware).
    @MainActor
    func capture(region: CGRect) async -> Data? {
        let center = CGPoint(x: region.midX, y: region.midY)
        let screen = NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.main
        guard let screen else { return nil }

        let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .map { CGDirectDisplayID($0.uint32Value) } ?? CGMainDisplayID()

        guard let full = CGDisplayCreateImage(displayID) else { return nil }

        let crop = Self.pixelCropRect(
            selection: region,
            screenFrame: screen.frame,
            scale: screen.backingScaleFactor
        )
        guard !crop.isEmpty, let cropped = full.cropping(to: crop) else { return nil }

        return Self.encodePNG(cropped)
    }

    /// Convert a selection rect in global AppKit screen coordinates (bottom-left
    /// origin, points) into a pixel crop rect (top-left origin) within the full
    /// image of the screen it belongs to.
    ///
    /// `CGDisplayCreateImage` returns a top-left-origin image at the display's
    /// pixel resolution, so we (1) translate into the screen's local space,
    /// (2) flip Y, and (3) scale points → pixels by `backingScaleFactor`.
    static func pixelCropRect(selection: CGRect, screenFrame: CGRect, scale: CGFloat) -> CGRect {
        let localX = selection.minX - screenFrame.minX
        let localYTop = screenFrame.maxY - selection.maxY
        return CGRect(
            x: (localX * scale).rounded(),
            y: (localYTop * scale).rounded(),
            width: (selection.width * scale).rounded(),
            height: (selection.height * scale).rounded()
        )
    }

    private static func encodePNG(_ image: CGImage) -> Data? {
        guard let data = CFDataCreateMutable(nil, 0),
              let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}
