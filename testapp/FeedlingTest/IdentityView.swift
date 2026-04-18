import SwiftUI

// MARK: - Identity Tab

struct IdentityView: View {
    @EnvironmentObject var vm: IdentityViewModel

    var body: some View {
        NavigationStack {
            Group {
                if let identity = vm.identity {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            agentHeader(identity)
                            radarSection(identity)
                            dimensionsList(identity)
                        }
                        .padding(20)
                    }
                } else {
                    emptyState
                }
            }
            .navigationTitle("Identity")
            .navigationBarTitleDisplayMode(.large)
        }
        .onAppear { vm.startPolling() }
        .onDisappear { vm.stopPolling() }
    }

    // MARK: Agent header

    private func agentHeader(_ identity: IdentityCard) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(identity.agentName)
                .font(.title.bold())
                .foregroundStyle(.white)
            Text(identity.selfIntroduction)
                .font(.body)
                .foregroundStyle(.white.opacity(0.75))
                .lineSpacing(4)
        }
    }

    // MARK: Radar chart section

    private func radarSection(_ identity: IdentityCard) -> some View {
        VStack(spacing: 0) {
            RadarChartView(dimensions: identity.dimensions)
                .frame(height: 260)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    // MARK: Dimensions list

    private func dimensionsList(_ identity: IdentityCard) -> some View {
        VStack(spacing: 10) {
            ForEach(identity.dimensions) { dim in
                DimensionRow(dimension: dim)
            }
        }
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.crop.circle.dashed")
                .font(.system(size: 56))
                .foregroundStyle(.white.opacity(0.2))
            Text("No identity card yet")
                .font(.title3.bold())
                .foregroundStyle(.white.opacity(0.5))
            Text("Ask your Agent to connect and run bootstrap.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.35))
                .multilineTextAlignment(.center)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Dimension Row

private struct DimensionRow: View {
    let dimension: IdentityCard.Dimension

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(dimension.name)
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
                Spacer()
                Text("\(dimension.value)")
                    .font(.subheadline.bold().monospacedDigit())
                    .foregroundStyle(.cyan)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.white.opacity(0.08))
                        .frame(height: 6)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.cyan.opacity(0.8))
                        .frame(width: geo.size.width * dimension.normalizedValue, height: 6)
                }
            }
            .frame(height: 6)
            if !dimension.description.isEmpty {
                Text(dimension.description)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .padding(14)
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Radar Chart

struct RadarChartView: View {
    let dimensions: [IdentityCard.Dimension]

    var body: some View {
        Canvas { ctx, size in
            guard !dimensions.isEmpty else { return }
            let n = dimensions.count
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let maxRadius = min(size.width, size.height) / 2 - 32

            // Grid rings
            for level in [0.25, 0.5, 0.75, 1.0] {
                var path = Path()
                for i in 0..<n {
                    let pt = vertex(i: i, n: n, r: maxRadius * level, center: center)
                    i == 0 ? path.move(to: pt) : path.addLine(to: pt)
                }
                path.closeSubpath()
                ctx.stroke(path, with: .color(.white.opacity(0.1)), lineWidth: 1)
            }

            // Spokes
            for i in 0..<n {
                var path = Path()
                path.move(to: center)
                path.addLine(to: vertex(i: i, n: n, r: maxRadius, center: center))
                ctx.stroke(path, with: .color(.white.opacity(0.1)), lineWidth: 1)
            }

            // Value polygon fill
            var fillPath = Path()
            for i in 0..<n {
                let r = maxRadius * dimensions[i].normalizedValue
                let pt = vertex(i: i, n: n, r: r, center: center)
                i == 0 ? fillPath.move(to: pt) : fillPath.addLine(to: pt)
            }
            fillPath.closeSubpath()
            ctx.fill(fillPath, with: .color(.cyan.opacity(0.25)))
            ctx.stroke(fillPath, with: .color(.cyan.opacity(0.9)), lineWidth: 1.5)

            // Dots
            for i in 0..<n {
                let r = maxRadius * dimensions[i].normalizedValue
                let pt = vertex(i: i, n: n, r: r, center: center)
                let dotRect = CGRect(x: pt.x - 3.5, y: pt.y - 3.5, width: 7, height: 7)
                ctx.fill(Path(ellipseIn: dotRect), with: .color(.cyan))
            }
        }
        .overlay(
            GeometryReader { geo in
                let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
                let maxRadius = min(geo.size.width, geo.size.height) / 2 - 32
                ForEach(Array(dimensions.enumerated()), id: \.offset) { i, dim in
                    let pt = vertex(i: i, n: dimensions.count, r: maxRadius + 18, center: center)
                    Text(dim.name)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.75))
                        .multilineTextAlignment(.center)
                        .position(pt)
                }
            }
        )
    }

    private func vertex(i: Int, n: Int, r: Double, center: CGPoint) -> CGPoint {
        let angle = (2 * Double.pi / Double(n)) * Double(i) - Double.pi / 2
        return CGPoint(x: center.x + r * cos(angle), y: center.y + r * sin(angle))
    }
}
