import SwiftUI

struct MemoryGardenView: View {
    @EnvironmentObject var vm: MemoryViewModel

    var body: some View {
        NavigationStack {
            Group {
                if vm.moments.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(vm.moments) { moment in
                                MomentCard(
                                    moment: moment,
                                    isNew: vm.newMomentIds.contains(moment.id)
                                )
                            }
                        }
                        .padding(16)
                    }
                }
            }
            .navigationTitle("Memory Garden")
            .navigationBarTitleDisplayMode(.large)
        }
        .onAppear { vm.startPolling() }
        .onDisappear { vm.stopPolling() }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "leaf.circle")
                .font(.system(size: 56))
                .foregroundStyle(.white.opacity(0.2))
            Text("The garden is empty")
                .font(.title3.bold())
                .foregroundStyle(.white.opacity(0.5))
            Text("Ask your Agent to run bootstrap and plant the first memories.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.35))
                .multilineTextAlignment(.center)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Moment Card

private struct MomentCard: View {
    let moment: MemoryMoment
    let isNew: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(moment.title)
                        .font(.subheadline.bold())
                        .foregroundStyle(.white)
                    Text(moment.relativeOccurredAt)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.4))
                }
                Spacer()
                if !moment.type.isEmpty {
                    Text(moment.type)
                        .font(.caption2)
                        .foregroundStyle(.cyan.opacity(0.8))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.cyan.opacity(0.12))
                        .clipShape(Capsule())
                }
            }

            if !moment.description.isEmpty {
                Text(moment.description)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.7))
                    .lineSpacing(4)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isNew
                ? Color.cyan.opacity(0.12)
                : Color(UIColor.secondarySystemGroupedBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(isNew ? Color.cyan.opacity(0.4) : Color.clear, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .animation(.easeOut(duration: 0.6), value: isNew)
    }
}
