import SwiftUI

/// The owl mark — a SwiftUI port of `src/OwletMark.jsx` from the design handoff.
///
/// Original SVG viewBox is 160×180 (taller than wide). The React component
/// renders into a square `size × size` box and lets SVG's default
/// `preserveAspectRatio="xMidYMid meet"` letterbox it. We mirror that here:
/// the Canvas frame is `size × size` and the owl is uniformly scaled to fit,
/// horizontally centered.
struct OwletMark: View {

    let size: CGFloat
    var mono: Bool = false

    /// Color override. When non-nil and `mono == true`, the whole mark uses
    /// this color. Otherwise the brand palette (sage body + coral beak) wins.
    var monoColor: Color = OwletDesign.Sage.s500

    var body: some View {
        Canvas { context, canvasSize in
            let scale = min(canvasSize.width / 160.0, canvasSize.height / 180.0)
            let xOff = (canvasSize.width - 160 * scale) / 2
            let yOff = (canvasSize.height - 180 * scale) / 2

            // Translate so all path coords are in native 160×180 space.
            context.translateBy(x: xOff, y: yOff)
            context.scaleBy(x: scale, y: scale)

            // Body silhouette: tufted-eared owl, rounded chest.
            let body = bodyPath()
            if mono {
                context.fill(body, with: .color(monoColor))
            } else {
                context.fill(body, with: .color(OwletDesign.Paper.p0))
                context.stroke(body, with: .color(OwletDesign.Sage.s500),
                               style: StrokeStyle(lineWidth: 5, lineJoin: .round))
            }

            // Eyes: outer disc, inner ring, pupil. Two of each, mirrored.
            for cx in [CGFloat(58), CGFloat(102)] {
                let cy: CGFloat = 78
                if mono {
                    // White sclera so eyes read against the colored body.
                    context.fill(Path(ellipseIn: CGRect(x: cx - 14, y: cy - 14, width: 28, height: 28)),
                                 with: .color(OwletDesign.Paper.p0))
                    context.fill(Path(ellipseIn: CGRect(x: cx - 6, y: cy - 6, width: 12, height: 12)),
                                 with: .color(monoColor))
                } else {
                    // Outer disc
                    let outer = Path(ellipseIn: CGRect(x: cx - 20, y: cy - 20, width: 40, height: 40))
                    context.fill(outer, with: .color(.white))
                    context.stroke(outer, with: .color(Color(red: 0xC8/255.0, green: 0xC5/255.0, blue: 0xBB/255.0)),
                                   style: StrokeStyle(lineWidth: 4))
                    // Inner ring
                    let inner = Path(ellipseIn: CGRect(x: cx - 12, y: cy - 12, width: 24, height: 24))
                    context.stroke(inner, with: .color(OwletDesign.Sage.s500),
                                   style: StrokeStyle(lineWidth: 2.5))
                    // Pupil
                    let pupil = Path(ellipseIn: CGRect(x: cx - 6, y: cy - 6, width: 12, height: 12))
                    context.fill(pupil, with: .color(OwletDesign.Sage.s500))
                }
            }

            // Beak: a coral diamond pointing down.
            var beak = Path()
            beak.move(to: CGPoint(x: 80, y: 108))
            beak.addLine(to: CGPoint(x: 72, y: 117))
            beak.addLine(to: CGPoint(x: 80, y: 126))
            beak.addLine(to: CGPoint(x: 88, y: 117))
            beak.closeSubpath()
            context.fill(beak, with: .color(mono ? monoColor : OwletDesign.Coral.c500))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    /// The owl body silhouette: tufted ears at top, rounded torso below.
    /// Path coordinates lifted directly from the React component (160×180
    /// viewBox), so changes to the design should re-derive from the SVG.
    private func bodyPath() -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 24, y: 75))
        // left ear tuft
        p.addQuadCurve(to: CGPoint(x: 55, y: 38), control: CGPoint(x: 24, y: 40))
        p.addLine(to: CGPoint(x: 38, y: 8))
        p.addLine(to: CGPoint(x: 67, y: 36))
        // crown between ears
        p.addQuadCurve(to: CGPoint(x: 93, y: 36), control: CGPoint(x: 80, y: 33))
        // right ear tuft
        p.addLine(to: CGPoint(x: 122, y: 8))
        p.addLine(to: CGPoint(x: 105, y: 38))
        p.addQuadCurve(to: CGPoint(x: 136, y: 75), control: CGPoint(x: 136, y: 40))
        // right flank, base, left flank
        p.addLine(to: CGPoint(x: 136, y: 145))
        p.addQuadCurve(to: CGPoint(x: 112, y: 168), control: CGPoint(x: 136, y: 168))
        p.addLine(to: CGPoint(x: 48, y: 168))
        p.addQuadCurve(to: CGPoint(x: 24, y: 145), control: CGPoint(x: 24, y: 168))
        p.closeSubpath()
        return p
    }
}

#Preview {
    HStack(spacing: 24) {
        OwletMark(size: 15)
        OwletMark(size: 32)
        OwletMark(size: 64)
        OwletMark(size: 64, mono: true, monoColor: OwletDesign.Sage.s500)
    }
    .padding()
    .background(OwletDesign.bg)
}
