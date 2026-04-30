import SwiftUI

// MARK: - Custom Cinnabar tab bar
//
// Replaces SwiftUI's native TabView bar. Hard 1px top border,
// paper background, hand-drawn path icons matching mockups-1.jsx tabIcon().

struct CinnabarTabBar: View {
    @Binding var selectedTab: AppTab
    let bottomInset: CGFloat  // safeAreaInsets.bottom from parent

    private let tabs: [(AppTab, String)] = [
        (.chat,     "Chat"),
        (.identity, "Identity"),
        (.garden,   "Garden"),
        (.settings, "Settings"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color.cinFg).frame(height: 1)
            HStack(spacing: 0) {
                ForEach(tabs, id: \.0) { tab, label in
                    Button {
                        selectedTab = tab
                    } label: {
                        CinTabItem(icon: tab, label: label, active: selectedTab == tab)
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 52)
            .background(Color.cinBg)
            Color.cinBg.frame(height: bottomInset)
        }
        .background(Color.cinBg)
    }
}

// MARK: - Single tab item

private struct CinTabItem: View {
    let icon: AppTab
    let label: String
    let active: Bool

    var body: some View {
        VStack(spacing: 4) {
            CinTabIcon(tab: icon, active: active)
                .frame(width: 22, height: 22)
            Text(label.uppercased())
                .font(.dmMono(size: 7))
                .kerning(1.5)
                .foregroundStyle(active ? Color.cinAccent1 : Color.cinSub)
        }
        .padding(.top, 8)
    }
}

// MARK: - Icon shapes (translated from mockups-1.jsx tabIcon())
// SVG viewBox 0 0 18 18, drawn into a 22×22 frame (scale = 22/18)

private struct CinTabIcon: View {
    let tab: AppTab
    let active: Bool

    private var color: Color { active ? Color.cinAccent1 : Color.cinSub }

    var body: some View {
        Canvas { ctx, size in
            let s = size.width / 18
            ctx.scaleBy(x: s, y: s)
            switch tab {
            case .chat:     drawChat(ctx)
            case .identity: drawIdentity(ctx)
            case .garden:   drawGarden(ctx)
            case .settings: drawSettings(ctx)
            }
        }
        .foregroundStyle(color)
    }

    // Chat: speech bubble with tail
    private func drawChat(_ ctx: GraphicsContext) {
        var p = Path()
        p.move(to: CGPoint(x: 3, y: 5.5))
        p.addCurve(to: CGPoint(x: 5, y: 3.5),
                   control1: CGPoint(x: 3, y: 4.4),
                   control2: CGPoint(x: 3.9, y: 3.5))
        p.addLine(to: CGPoint(x: 13, y: 3.5))
        p.addCurve(to: CGPoint(x: 15, y: 5.5),
                   control1: CGPoint(x: 14.1, y: 3.5),
                   control2: CGPoint(x: 15, y: 4.4))
        p.addLine(to: CGPoint(x: 15, y: 10.5))
        p.addCurve(to: CGPoint(x: 13, y: 12.5),
                   control1: CGPoint(x: 15, y: 11.6),
                   control2: CGPoint(x: 14.1, y: 12.5))
        p.addLine(to: CGPoint(x: 8, y: 12.5))
        p.addLine(to: CGPoint(x: 5, y: 15))
        p.addLine(to: CGPoint(x: 5, y: 12.5))
        p.addLine(to: CGPoint(x: 5, y: 12.5))
        p.addCurve(to: CGPoint(x: 3, y: 10.5),
                   control1: CGPoint(x: 3.9, y: 12.5),
                   control2: CGPoint(x: 3, y: 11.6))
        p.closeSubpath()
        ctx.stroke(p, with: .foreground, style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
    }

    // Identity: outer ring + inner dot
    private func drawIdentity(_ ctx: GraphicsContext) {
        let outer = Path(ellipseIn: CGRect(x: 2.5, y: 2.5, width: 13, height: 13))
        let inner = Path(ellipseIn: CGRect(x: 7, y: 7, width: 4, height: 4))
        ctx.stroke(outer, with: .foreground, style: StrokeStyle(lineWidth: 1.2))
        ctx.fill(inner, with: .foreground)
    }

    // Garden: leaf petal + stem
    private func drawGarden(_ ctx: GraphicsContext) {
        var petal = Path()
        petal.move(to: CGPoint(x: 9, y: 2))
        petal.addCurve(to: CGPoint(x: 6, y: 8),
                       control1: CGPoint(x: 8, y: 4),
                       control2: CGPoint(x: 6, y: 5.5))
        petal.addCurve(to: CGPoint(x: 9, y: 12),
                       control1: CGPoint(x: 6, y: 10.5),
                       control2: CGPoint(x: 7, y: 12))
        petal.addCurve(to: CGPoint(x: 12, y: 8),
                       control1: CGPoint(x: 11, y: 12),
                       control2: CGPoint(x: 12, y: 10.5))
        petal.addCurve(to: CGPoint(x: 9, y: 2),
                       control1: CGPoint(x: 12, y: 5.5),
                       control2: CGPoint(x: 10, y: 4))
        ctx.stroke(petal, with: .foreground, style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
        var stem = Path()
        stem.move(to: CGPoint(x: 9, y: 12))
        stem.addLine(to: CGPoint(x: 9, y: 16))
        ctx.stroke(stem, with: .foreground, style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
    }

    // Settings: three slider lines with offset knobs
    private func drawSettings(_ ctx: GraphicsContext) {
        let lines: [(CGFloat, CGFloat, CGFloat)] = [
            (5,  3, 15),
            (9,  3, 15),
            (13, 3, 15),
        ]
        let knobs: [(CGFloat, CGFloat)] = [(11, 5), (6, 9), (13, 13)]
        for (y, x1, x2) in lines {
            var lp = Path()
            lp.move(to: CGPoint(x: x1, y: y))
            lp.addLine(to: CGPoint(x: x2, y: y))
            ctx.stroke(lp, with: .foreground, style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
        }
        for (kx, ky) in knobs {
            let kr: CGFloat = 1.6
            ctx.fill(Path(ellipseIn: CGRect(x: kx - kr, y: ky - kr, width: kr * 2, height: kr * 2)),
                     with: .foreground)
        }
    }
}
