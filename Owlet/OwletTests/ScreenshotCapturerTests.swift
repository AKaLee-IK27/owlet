import XCTest
import CoreGraphics
@testable import Owlet

/// Tests for `ScreenshotCapturer.pixelCropRect` — the global-AppKit-coords →
/// display-pixel-crop conversion. This is where a wrong Retina crop (half-size
/// or offset region) would silently hide, since the rest of capture needs a
/// real display.
final class ScreenshotCapturerTests: XCTestCase {

    func test_primaryScreen_nonRetina_translatesAndFlipsY() {
        // 1440-tall primary screen at 1x. A 100x50 selection whose top is 200pt
        // below the screen top (maxY = 1240) sits 200pt from the top.
        let screen = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        let selection = CGRect(x: 300, y: 1190, width: 100, height: 50) // maxY = 1240
        let crop = ScreenshotCapturer.pixelCropRect(selection: selection, screenFrame: screen, scale: 1)
        XCTAssertEqual(crop, CGRect(x: 300, y: 200, width: 100, height: 50))
    }

    func test_retina2x_scalesAllFourComponents() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let selection = CGRect(x: 100, y: 800, width: 200, height: 50) // maxY = 850, 50pt from top
        let crop = ScreenshotCapturer.pixelCropRect(selection: selection, screenFrame: screen, scale: 2)
        // localX=100→200, localYTop=900-850=50→100, w=200→400, h=50→100
        XCTAssertEqual(crop, CGRect(x: 200, y: 100, width: 400, height: 100))
    }

    func test_secondaryScreen_subtractsScreenOrigin() {
        // A screen positioned to the right of and above the primary.
        let screen = CGRect(x: 2560, y: 300, width: 1920, height: 1080)
        let selection = CGRect(x: 2660, y: 1300, width: 120, height: 80) // maxY = 1380
        let crop = ScreenshotCapturer.pixelCropRect(selection: selection, screenFrame: screen, scale: 1)
        // localX = 2660-2560 = 100; localYTop = (300+1080) - 1380 = 0
        XCTAssertEqual(crop, CGRect(x: 100, y: 0, width: 120, height: 80))
    }

    func test_selectionAtScreenTopLeft_mapsToOrigin() {
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let selection = CGRect(x: 0, y: 900, width: 100, height: 100) // top-left corner, maxY = 1000
        let crop = ScreenshotCapturer.pixelCropRect(selection: selection, screenFrame: screen, scale: 1)
        XCTAssertEqual(crop, CGRect(x: 0, y: 0, width: 100, height: 100))
    }
}
