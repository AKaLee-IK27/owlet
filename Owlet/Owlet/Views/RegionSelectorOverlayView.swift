import SwiftUI

/// SwiftUI view that draws the region selection overlay.
struct RegionSelectorOverlayView: View {
    @Binding var selection: CGRect
    @Binding var isDragging: Bool
    let onAnchorSet: (CGPoint) -> Void

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.opacity(0.4)

                if isDragging && selection.width > 2 && selection.height > 2 {
                    Rectangle()
                        .fill(Color.white.opacity(0.1))
                        .overlay(
                            Rectangle()
                                .stroke(Color.white, lineWidth: 2)
                        )
                        .frame(width: selection.width, height: selection.height)
                        .position(x: selection.midX, y: selection.midY)
                }

                Text("Drag to select a region")
                    .foregroundColor(.white)
                    .font(.system(size: 14, weight: .medium))
                    .padding(8)
                    .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                    .position(x: geo.size.width / 2, y: 30)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !isDragging {
                            isDragging = true
                            onAnchorSet(value.startLocation)
                        }
                        let start = value.startLocation
                        let current = value.location
                        selection = CGRect(
                            x: min(start.x, current.x),
                            y: min(start.y, current.y),
                            width: abs(current.x - start.x),
                            height: abs(current.y - start.y)
                        )
                    }
            )
        }
    }
}
