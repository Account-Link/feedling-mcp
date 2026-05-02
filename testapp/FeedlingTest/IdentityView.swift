import SwiftUI

// MARK: - Identity Tab

struct IdentityView: View {
    @EnvironmentObject var vm: IdentityViewModel

    private let isChinese: Bool =
        Locale.preferredLanguages.first?.hasPrefix("zh") ?? false

    var body: some View {
        ZStack {
            Color.cinBg.ignoresSafeArea()
            if let identity = vm.identity {
                ScrollView {
                    VStack(spacing: 0) {
                        identityHeader(identity)
                        Rectangle().fill(Color.cinFg).frame(height: 1).padding(.horizontal, 24)
                        radarSection(identity)
                        Rectangle().fill(Color.cinFg).frame(height: 1).padding(.horizontal, 24)
                        dimensionsList(identity)
                    }
                }
            } else {
                emptyState
            }
        }
        .onAppear { vm.startPolling() }
        .onDisappear { vm.stopPolling() }
    }

    // MARK: - Header

    private func identityHeader(_ id: IdentityCard) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Top meta row
            HStack(alignment: .lastTextBaseline) {
                Text("Identity")
                    .font(.newsreader(size: 13, italic: true))
                    .foregroundStyle(Color.cinFg)
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Rectangle().fill(Color.cinFg).frame(height: 1).padding(.horizontal, 24)

            // Relation stage — days + label
            HStack(alignment: .lastTextBaseline, spacing: 8) {
                Text("\(id.daysWithUser)")
                    .font(.newsreader(size: 48))
                    .foregroundStyle(Color.cinAccent1)
                VStack(alignment: .leading, spacing: 1) {
                    Text("DAYS")
                        .font(.dmMono(size: 9, weight: .medium))
                        .foregroundStyle(Color.cinAccent1)
                        .kerning(2.5)
                    Text("TOGETHER")
                        .font(.dmMono(size: 9))
                        .foregroundStyle(Color.cinSub)
                        .kerning(2.5)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 16)

            // Agent name
            Text(id.agentName.isEmpty ? "—" : id.agentName)
                .font(.newsreader(size: 40))
                .foregroundStyle(Color.cinAccent1)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .padding(.horizontal, 24)
                .padding(.bottom, 10)

            // Self-introduction (one-line agent tagline)
            if !id.selfIntroduction.isEmpty {
                Text(id.selfIntroduction)
                    .font(.notoSerifSC(size: 13))
                    .italic()
                    .foregroundStyle(Color.cinSub)
                    .lineSpacing(2)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)
            }

            // Signature — agent's attitude toward proactive messaging, in its own voice
            if let sig = id.signature, !sig.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(sig, id: \.self) { line in
                        Text(line)
                            .font(.newsreader(size: 13, italic: true))
                            .foregroundStyle(Color.cinFg.opacity(0.55))
                            .lineSpacing(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
            }

            // Category tag
            if let cat = id.category, !cat.isEmpty {
                Text(cat)
                    .font(.dmMono(size: 9))
                    .foregroundStyle(Color.cinSub)
                    .kerning(2)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 20)
            }
        }
    }

    // MARK: - Hatched Radar

    private func radarSection(_ id: IdentityCard) -> some View {
        VStack(spacing: 0) {
            HatchedRadarView(dimensions: id.dimensions)
                .frame(height: 280)
                .padding(.vertical, 24)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Dimensions list

    private func dimensionsList(_ id: IdentityCard) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .lastTextBaseline, spacing: 10) {
                Text("DIMENSIONS")
                    .font(.dmMono(size: 9.5))
                    .foregroundStyle(Color.cinAccent1)
                    .kerning(3)
                    .fontWeight(.semibold)
            }
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .padding(.bottom, 8)

            ForEach(Array(id.dimensions.enumerated()), id: \.element.id) { idx, dim in
                CinDimensionRow(index: idx + 1, dimension: dim)
            }
        }
        .padding(.bottom, 32)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: "sparkles")
                .font(.system(size: 44, weight: .thin))
                .foregroundStyle(Color.cinLine)
            Text(isChinese ? "还没有身份卡" : "No identity card yet")
                .font(.newsreader(size: 22, italic: true))
                .foregroundStyle(Color.cinSub)
            Text(isChinese
                 ? "让你的 AI 连接并运行 bootstrap。"
                 : "Ask your AI to connect and run bootstrap.")
                .font(.interTight(size: 13))
                .foregroundStyle(Color.cinSub)
                .multilineTextAlignment(.center)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Dimension Row

private struct CinDimensionRow: View {
    let index: Int
    let dimension: IdentityCard.Dimension

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            // Index
            Text(String(format: "%02d", index))
                .font(.dmMono(size: 9))
                .foregroundStyle(Color.cinSub)
                .kerning(1)
                .frame(width: 24)

            // Name
            Text(dimension.name)
                .font(.notoSerifSC(size: 14, weight: .medium))
                .foregroundStyle(Color.cinFg)
                .frame(width: 52, alignment: .leading)

            // Bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Color.cinLine)
                        .frame(height: 1)
                    Rectangle()
                        .fill(Color.cinAccent1)
                        .frame(width: geo.size.width * dimension.normalizedValue, height: 2)
                }
            }
            .frame(height: 2)

            // Score + delta
            HStack(spacing: 4) {
                Text("\(dimension.value)")
                    .font(.dmMono(size: 10, weight: .medium))
                    .foregroundStyle(Color.cinFg)
                if let delta = dimension.delta, !delta.isEmpty {
                    Text(delta)
                        .font(.dmMono(size: 9))
                        .foregroundStyle(delta.hasPrefix("+") ? Color.cinAccent1 : Color.cinSub)
                }
            }
            .frame(width: 56, alignment: .trailing)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.cinLine).frame(height: 0.5).padding(.horizontal, 24)
        }
    }
}

// MARK: - Hatched Radar

struct HatchedRadarView: View {
    let dimensions: [IdentityCard.Dimension]

    var body: some View {
        Canvas { ctx, size in
            guard !dimensions.isEmpty else { return }
            let n = dimensions.count
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let maxR = min(size.width, size.height) / 2 - 36

            // Grid rings
            for level in stride(from: 0.25, through: 1.0, by: 0.25) {
                var ring = Path()
                for i in 0..<n {
                    let pt = vertex(i: i, n: n, r: maxR * level, c: center)
                    i == 0 ? ring.move(to: pt) : ring.addLine(to: pt)
                }
                ring.closeSubpath()
                ctx.stroke(ring, with: .color(Color.cinLine.opacity(0.6)), lineWidth: 0.5)
            }

            // Spokes
            for i in 0..<n {
                var spoke = Path()
                spoke.move(to: center)
                spoke.addLine(to: vertex(i: i, n: n, r: maxR, c: center))
                ctx.stroke(spoke, with: .color(Color.cinLine.opacity(0.6)), lineWidth: 0.5)
            }

            // Value polygon — hatched fill using clipped diagonal lines
            var fillPath = Path()
            for i in 0..<n {
                let r = maxR * dimensions[i].normalizedValue
                let pt = vertex(i: i, n: n, r: r, c: center)
                i == 0 ? fillPath.move(to: pt) : fillPath.addLine(to: pt)
            }
            fillPath.closeSubpath()

            // Draw 45° hatch lines clipped to the fill polygon
            ctx.clip(to: fillPath)
            let bounds = CGRect(origin: .zero, size: size)
            let step: CGFloat = 8
            var x = bounds.minX - bounds.height
            while x < bounds.maxX + bounds.height {
                var hatch = Path()
                hatch.move(to: CGPoint(x: x, y: bounds.minY))
                hatch.addLine(to: CGPoint(x: x + bounds.height, y: bounds.maxY))
                ctx.stroke(hatch, with: .color(Color.cinAccent1.opacity(0.25)), lineWidth: 1)
                x += step
            }

            // Stroke outline
            ctx.stroke(fillPath, with: .color(Color.cinAccent1.opacity(0.8)), lineWidth: 1.5)

            // Dots at vertices
            for i in 0..<n {
                let r = maxR * dimensions[i].normalizedValue
                let pt = vertex(i: i, n: n, r: r, c: center)
                let dot = CGRect(x: pt.x - 3, y: pt.y - 3, width: 6, height: 6)
                ctx.fill(Path(ellipseIn: dot), with: .color(Color.cinAccent1))
            }
        }
        .overlay(
            GeometryReader { geo in
                let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
                let maxR = min(geo.size.width, geo.size.height) / 2 - 36
                ForEach(Array(dimensions.enumerated()), id: \.offset) { i, dim in
                    let pt = vertex(i: i, n: dimensions.count, r: maxR + 22, c: center)
                    Text(dim.name)
                        .font(.dmMono(size: 11))
                        .foregroundStyle(Color.cinSub)
                        .kerning(0.5)
                        .multilineTextAlignment(.center)
                        .position(pt)
                }
            }
        )
    }

    private func vertex(i: Int, n: Int, r: Double, c: CGPoint) -> CGPoint {
        let angle = (2 * Double.pi / Double(n)) * Double(i) - Double.pi / 2
        return CGPoint(x: c.x + r * cos(angle), y: c.y + r * sin(angle))
    }
}
