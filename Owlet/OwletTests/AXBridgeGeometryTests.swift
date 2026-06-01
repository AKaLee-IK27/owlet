import XCTest
@testable import Owlet

final class AXBridgeGeometryTests: XCTestCase {

    // A caret near the TOP of a 900-tall single display (small AX y) must map to
    // a LARGE Cocoa y — i.e. near the top — not get pinned to the bottom.
    func test_flipMapsTopOfScreenToHighCocoaY() {
        let axRect = CGRect(x: 100, y: 50, width: 0, height: 18)
        let cocoa = AXBridge.cocoaRect(fromAXRect: axRect, primaryScreenMaxY: 900)

        XCTAssertEqual(cocoa.origin.x, 100, accuracy: 0.001)
        // 900 - (50 + 18) = 832
        XCTAssertEqual(cocoa.origin.y, 832, accuracy: 0.001)
        XCTAssertEqual(cocoa.height, 18, accuracy: 0.001)
    }

    // A caret near the BOTTOM of the display (large AX y) maps to a small Cocoa y.
    func test_flipMapsBottomOfScreenToLowCocoaY() {
        let axRect = CGRect(x: 0, y: 882, width: 0, height: 18)
        let cocoa = AXBridge.cocoaRect(fromAXRect: axRect, primaryScreenMaxY: 900)
        // 900 - (882 + 18) = 0
        XCTAssertEqual(cocoa.origin.y, 0, accuracy: 0.001)
    }

    // Regression: external monitor mounted ABOVE the primary display.
    //
    // Reproduces the observed bug where a caret on the PRIMARY screen had its
    // ghost-text overlay placed ~1440px too high (onto the external monitor).
    // Real captured data: primary frame {0,0,1800,1169} (maxY 1169), an external
    // display {-552,1169,2560,1440} stacked above making the all-screens union
    // maxY 2609. The caret's raw AX rect was (1288.65, 269, 0, 16).
    //
    // The flip MUST anchor on the primary's maxY (1169), yielding Cocoa y 884 —
    // on the primary where the caret is — NOT the union's 2609 which yielded the
    // off-screen 2324 the user saw.
    func test_flipAnchorsOnPrimaryNotUnion_externalMonitorAbove() {
        let axRect = CGRect(x: 1288.6533203125, y: 269, width: 0, height: 16)
        let primaryMaxY: CGFloat = 1169

        let cocoa = AXBridge.cocoaRect(fromAXRect: axRect, primaryScreenMaxY: primaryMaxY)

        // 1169 - (269 + 16) = 884  (correct: on the primary display)
        XCTAssertEqual(cocoa.origin.y, 884, accuracy: 0.001)
        // Guard against the regression: the old union anchor (2609) produced 2324.
        XCTAssertNotEqual(cocoa.origin.y, 2324, accuracy: 0.001)
        XCTAssertEqual(cocoa.origin.x, 1288.6533203125, accuracy: 0.001)
        XCTAssertEqual(cocoa.height, 16, accuracy: 0.001)
    }

    // No anchor → cannot validate → accept (preserves behavior for fields with no AXFrame).
    func test_anchorValidation_nilAnchorAccepts() {
        XCTAssertTrue(AXBridge.rectIsNearAnchor(NSRect(x: 0, y: 0, width: 2, height: 16), anchor: nil))
        XCTAssertTrue(AXBridge.rectIsNearAnchor(NSRect(x: 9999, y: 9999, width: 2, height: 16), anchor: .zero))
    }

    // A caret rect whose midpoint sits inside the field (plus halo) is accepted.
    func test_anchorValidation_insideFieldAccepted() {
        let field = NSRect(x: 1000, y: 800, width: 600, height: 200)
        let caret = NSRect(x: 1288, y: 884, width: 0, height: 16)
        XCTAssertTrue(AXBridge.rectIsNearAnchor(caret, anchor: field))
    }

    // A caret rect far from the field (e.g. flipped into the wrong coordinate space)
    // is rejected so the overlay isn't dragged off-screen.
    func test_anchorValidation_farRectRejected() {
        let field = NSRect(x: 1000, y: 800, width: 600, height: 200)
        // The pre-fix bug placed this caret at y=2324 — ~1424pt above the field.
        let stray = NSRect(x: 1288, y: 2324, width: 0, height: 16)
        XCTAssertFalse(AXBridge.rectIsNearAnchor(stray, anchor: field))
    }

    // The 80pt halo absorbs padding/scroll just outside the field bounds.
    func test_anchorValidation_withinHaloAccepted() {
        let field = NSRect(x: 1000, y: 800, width: 600, height: 200)  // y: 800...1000
        let justAbove = NSRect(x: 1100, y: 1060, width: 0, height: 16) // midY 1068 → within 80pt of maxY 1000
        XCTAssertTrue(AXBridge.rectIsNearAnchor(justAbove, anchor: field))
    }
}
