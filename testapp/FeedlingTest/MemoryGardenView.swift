import SwiftUI

// MARK: - Memory Garden Tab

struct MemoryGardenView: View {
    @EnvironmentObject var vm: MemoryViewModel
    @EnvironmentObject var chatVM: ChatViewModel
    @EnvironmentObject var router: AppRouter

    private var monthGroups: [(month: String, moments: [MemoryMoment])] {
        var result: [(month: String, moments: [MemoryMoment])] = []
        for m in vm.moments {
            let key = m.monthGroup
            if result.last?.month == key {
                result[result.count - 1].moments.append(m)
            } else {
                result.append((month: key, moments: [m]))
            }
        }
        return result
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.cinBg.ignoresSafeArea()
                if vm.moments.isEmpty {
                    emptyState
                } else {
                    gardenList
                }
            }
        }
        .onAppear { vm.startPolling() }
        .onDisappear { vm.stopPolling() }
    }

    // MARK: - Garden list

    private var gardenList: some View {
        ScrollView {
            VStack(spacing: 0) {
                gardenHeader
                Rectangle().fill(Color.cinFg).frame(height: 1).padding(.horizontal, 24)
                ForEach(monthGroups, id: \.month) { group in
                    monthSection(group)
                }
            }
        }
        .background(Color.cinBg)
    }

    private var gardenHeader: some View {
        HStack(alignment: .lastTextBaseline) {
            Text("Memory Garden")
                .font(.newsreader(size: 13, italic: true))
                .foregroundStyle(Color.cinFg)
            Spacer()
            Text("\(vm.moments.count) cards\(vm.moments.contains { $0.isFresh } ? " · +\(vm.moments.filter { $0.isFresh }.count) today" : "")")
                .font(.dmMono(size: 9))
                .foregroundStyle(Color.cinSub)
                .kerning(2)
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private func monthSection(_ group: (month: String, moments: [MemoryMoment])) -> some View {
        VStack(spacing: 0) {
            // Month header
            HStack(alignment: .lastTextBaseline, spacing: 10) {
                Text(group.month)
                    .font(.newsreader(size: 22))
                    .foregroundStyle(Color.cinFg)
                Rectangle().fill(Color.cinFg.opacity(0.2)).frame(height: 1)
                Text(String(format: "%02d", group.moments.count))
                    .font(.dmMono(size: 9))
                    .foregroundStyle(Color.cinSub)
                    .kerning(1.5)
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)
            .padding(.bottom, 8)

            ForEach(Array(group.moments.enumerated()), id: \.element.id) { idx, moment in
                NavigationLink {
                    MemoryCardDetailView(moment: moment)
                        .environmentObject(chatVM)
                        .environmentObject(router)
                        .environmentObject(vm)
                } label: {
                    GardenRow(index: idx + 1, moment: moment, isNew: vm.newMomentIds.contains(moment.id))
                }
                .buttonStyle(.plain)
                .feedlingMemoryVisibilityMenu(moment: moment) { toLocalOnly in
                    Task {
                        do {
                            try await FeedlingAPI.shared.flipMemoryVisibility(
                                moment: moment, toLocalOnly: toLocalOnly)
                            await vm.loadMoments()
                        } catch {
                            print("[visibility-flip] \(moment.id): \(error)")
                        }
                    }
                }
            }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 20) {
            Text("—")
                .font(.newsreader(size: 64))
                .foregroundStyle(Color.cinLine)
            Text("The garden is empty")
                .font(.newsreader(size: 22, italic: true))
                .foregroundStyle(Color.cinSub)
            Text("Ask your agent to run bootstrap and plant the first memories.")
                .font(.interTight(size: 13))
                .foregroundStyle(Color.cinSub)
                .multilineTextAlignment(.center)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Garden Row

private struct GardenRow: View {
    let index: Int
    let moment: MemoryMoment
    let isNew: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Index + fresh dot
            VStack(spacing: 6) {
                Text(String(format: "%02d", index))
                    .font(.dmMono(size: 9))
                    .foregroundStyle(Color.cinSub)
                    .kerning(1)
                if isNew || moment.isFresh {
                    Circle()
                        .fill(Color.cinAccent1)
                        .frame(width: 5, height: 5)
                }
                if moment.visibility == "local_only" {
                    Image(systemName: "eye.slash")
                        .font(.system(size: 8))
                        .foregroundStyle(Color.cinSub.opacity(0.6))
                }
            }
            .frame(width: 28)
            .padding(.top, 3)

            // Content
            VStack(alignment: .leading, spacing: 4) {
                Text(moment.type.uppercased())
                    .font(.dmMono(size: 8.5, weight: .medium))
                    .foregroundStyle(Color.cinAccent1)
                    .kerning(2.5)

                Text(moment.title)
                    .font(.notoSerifSC(size: 13.5, weight: .medium))
                    .foregroundStyle(Color.cinFg)
                    .lineSpacing(2)
                    .multilineTextAlignment(.leading)

                if !moment.description.isEmpty {
                    Text(moment.description)
                        .font(.interTight(size: 11))
                        .foregroundStyle(Color.cinSub)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Date
            Text(moment.relativeOccurredAt)
                .font(.newsreader(size: 11, italic: true))
                .foregroundStyle(Color.cinSub)
                .frame(width: 60, alignment: .trailing)
                .padding(.top, 3)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.cinLine).frame(height: 0.5).padding(.leading, 24)
        }
        .background(Color.cinBg)
    }
}

// MARK: - Memory Card Detail

struct MemoryCardDetailView: View {
    let moment: MemoryMoment
    @EnvironmentObject var chatVM: ChatViewModel
    @EnvironmentObject var router: AppRouter
    @EnvironmentObject var memoryVM: MemoryViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showDeleteConfirm = false

    private var occurredDateStr: String {
        guard let date = moment.occurredDate else { return moment.occurredAt }
        let fmt = DateFormatter()
        fmt.dateStyle = .long
        fmt.timeStyle = .short
        return fmt.string(from: date)
    }

    private var createdDate: Date? {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = fmt.date(from: moment.createdAt) { return d }
        fmt.formatOptions = [.withInternetDateTime]
        return fmt.date(from: moment.createdAt)
    }

    private var createdDateStr: String {
        guard let date = createdDate else { return moment.createdAt }
        let fmt = DateFormatter()
        fmt.dateStyle = .long
        fmt.timeStyle = .short
        return fmt.string(from: date)
    }

    private var isSameDay: Bool {
        guard let occurred = moment.occurredDate, let created = createdDate else { return false }
        return Calendar.current.isDate(occurred, inSameDayAs: created)
    }

    private var sourceLabel: String {
        switch moment.source {
        case "bootstrap": return "OLD MEMORY"
        case "chat": return "FROM CHAT"
        default: return moment.source.isEmpty ? "—" : moment.source.uppercased()
        }
    }

    var body: some View {
        ZStack {
            Color.cinBg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    navHeader
                    Rectangle().fill(Color.cinFg).frame(height: 1)
                    typeRow
                    cardTitle
                    cardBody
                    herWordsPull
                    timeBlock
                    actionButtons
                    Spacer(minLength: 40)
                }
            }
        }
        .navigationBarHidden(true)
        .confirmationDialog("删除这条记忆？", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("删除", role: .destructive) { deleteAndDismiss() }
            Button("取消", role: .cancel) { }
        }
    }

    private var navHeader: some View {
        HStack {
            Button(action: { dismiss() }) {
                Text("← garden")
                    .font(.dmMono(size: 9.5))
                    .foregroundStyle(Color.cinFg)
                    .kerning(2)
            }
            .buttonStyle(.plain)
            Spacer()
            Text("CARD \(moment.id.prefix(4).uppercased())")
                .font(.dmMono(size: 9))
                .foregroundStyle(Color.cinSub)
                .kerning(2)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    private var typeRow: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(moment.type.uppercased())
                .font(.dmMono(size: 9, weight: .medium))
                .foregroundStyle(Color.cinBg)
                .kerning(2.5)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.cinAccent1)
            Text(sourceLabel)
                .font(.dmMono(size: 8.5))
                .foregroundStyle(Color.cinSub)
                .kerning(1.5)
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 14)
    }

    private var cardTitle: some View {
        Text(moment.title)
            .font(.newsreader(size: 26))
            .foregroundStyle(Color.cinFg)
            .lineSpacing(4)
            .padding(.horizontal, 24)
            .padding(.bottom, 18)
    }

    @ViewBuilder
    private var cardBody: some View {
        if !moment.description.isEmpty {
            Text(moment.description)
                .font(.notoSerifSC(size: 13.5))
                .foregroundStyle(Color.cinFg)
                .lineSpacing(6)
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
        }
    }

    @ViewBuilder
    private var herWordsPull: some View {
        if let quote = moment.herQuote, !quote.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Text("HER WORDS")
                    .font(.dmMono(size: 8.5, weight: .medium))
                    .foregroundStyle(Color.cinAccent1)
                    .kerning(2.5)
                Text("\u{201C}\(quote)\u{201D}")
                    .font(.notoSerifSC(size: 13))
                    .foregroundStyle(Color.cinFg)
                    .italic()
                    .lineSpacing(4)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color.cinAccent1Soft)
            .overlay(alignment: .leading) {
                Rectangle().fill(Color.cinAccent1).frame(width: 2)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
    }

    private var timeBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(Color.cinLine).frame(height: 1)
            if isSameDay {
                metaRow(label: "WHEN", value: occurredDateStr)
            } else {
                metaRow(label: "HAPPENED", value: occurredDateStr)
                metaRow(label: "RECORDED", value: createdDateStr)
            }
            if !moment.source.isEmpty {
                metaRow(label: "SOURCE", value: sourceLabel)
            }
            if let ctx = moment.context, !ctx.isEmpty {
                metaRow(label: "CONTEXT", value: ctx)
            }
            if let linked = moment.linkedDimension, !linked.isEmpty {
                metaRow(label: "DIMENSION", value: linked)
            }
            Rectangle().fill(Color.cinLine).frame(height: 1)
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 24)
    }

    private func metaRow(label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Text(label)
                .font(.dmMono(size: 8.5))
                .foregroundStyle(Color.cinSub)
                .kerning(2)
                .frame(width: 80, alignment: .leading)
            Text(value)
                .font(.newsreader(size: 13))
                .foregroundStyle(Color.cinFg)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 10)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.cinLine.opacity(0.5)).frame(height: 0.5)
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 10) {
            Button {
                chatVM.quoteInChat(moment: moment)
                router.selectedTab = .chat
            } label: {
                Text("在 CHAT 里聊聊 ↗")
            }
            .buttonStyle(CinPrimaryButtonStyle())
            .frame(maxWidth: .infinity)

            Button {
                showDeleteConfirm = true
            } label: {
                Text("DELETE")
            }
            .buttonStyle(CinSecondaryButtonStyle())
            .frame(width: 88)
        }
        .padding(.horizontal, 24)
        .padding(.top, 4)
    }

    private func deleteAndDismiss() {
        Task {
            do {
                try await FeedlingAPI.shared.deleteMemory(id: moment.id)
                await memoryVM.loadMoments()
                dismiss()
            } catch {
                print("[delete-memory] \(moment.id): \(error)")
                dismiss()
            }
        }
    }
}
