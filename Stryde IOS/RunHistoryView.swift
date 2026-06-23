import SwiftUI

struct RunHistoryView: View {
    private var appState = AppState.shared

    // Lifetime totals across all saved runs, shown in the summary header.
    private var totalMiles: Double { appState.localRuns.reduce(0) { $0 + $1.distance } }
    private var totalSeconds: Int { appState.localRuns.reduce(0) { $0 + $1.duration } }

    var body: some View {
        Group {
            if appState.localRuns.isEmpty {
                VStack(spacing: 12) {
                    Text("No runs yet.")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.white)
                    Text("Your completed runs will show up here.")
                        .font(.system(size: 14))
                        .foregroundColor(Color(hex: "#888888"))
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        summaryHeader
                        LazyVStack(spacing: 8) {
                            // Identify rows by `date`, not `id`. `id` is the backend run id,
                            // which is nil until /runs POST succeeds — so unsynced runs all
                            // share identity nil and ForEach collapses them into a single row.
                            // `date` (ISO-8601) is unique per run and is already the key used
                            // by addLocalRun/deleteRun, so it's the stable identity here.
                            ForEach(appState.localRuns, id: \.date) { run in
                                NavigationLink {
                                    RunSummaryView(run: run, fromHistory: true)
                                } label: {
                                    runRow(run)
                                }
                                // Long press triggers a delete confirmation.
                                .contextMenu {
                                    Button(role: .destructive) {
                                        deleteRun(run)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 24)
                }
            }
        }
        .background(Color(hex: "#27272D").ignoresSafeArea())
        .navigationTitle("Run History")
        .navigationBarTitleDisplayMode(.large)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }

    // Lifetime stats card pinned above the run list.
    private var summaryHeader: some View {
        HStack {
            summaryStat(value: "\(appState.localRuns.count)", label: "Runs")
            Divider().frame(height: 34).background(Color(hex: "#333333"))
            summaryStat(value: String(format: "%.1f", totalMiles), label: "Total mi")
            Divider().frame(height: 34).background(Color(hex: "#333333"))
            summaryStat(value: formatTotalTime(totalSeconds), label: "Total time")
        }
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity)
        .background(Color(hex: "#1A1A1A"))
        .cornerRadius(16)
    }

    private func summaryStat(value: String, label: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(Color(hex: "#C6F135"))
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(Color(hex: "#888888"))
                .textCase(.uppercase)
                .kerning(0.5)
        }
        .frame(maxWidth: .infinity)
    }

    private func formatTotalTime(_ s: Int) -> String {
        let h = s / 3600, m = (s % 3600) / 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }

    private func runRow(_ run: LocalRun) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(run.routeName)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Spacer()
                Text(shortDate(run.date))
                    .font(.system(size: 12))
                    .foregroundColor(Color(hex: "#888888"))
            }
            HStack(spacing: 6) {
                Text(String(format: "%.2f mi", run.distance))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(Color(hex: "#C6F135"))
                Text("•")
                    .foregroundColor(Color(hex: "#555555"))
                Text(formatTime(run.duration))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(Color(hex: "#C6F135"))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(hex: "#1A1A1A"))
        .cornerRadius(16)
    }

    private func deleteRun(_ run: LocalRun) {
        appState.localRuns.removeAll { $0.date == run.date }
        appState.saveLocalRuns(appState.localRuns)
        if let id = run.id {
            Task { try? await APIService.shared.deleteRun(id: id) }
        }
    }

    private func shortDate(_ iso: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: iso) else { return "" }
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy"
        return f.string(from: date)
    }

    private func formatTime(_ s: Int) -> String {
        String(format: "%02d:%02d", s / 60, s % 60)
    }
}

#Preview {
    // Seed the shared state so the canvas shows the totals header + a populated list
    // with no run, no backend, and no network — lets you eyeball the history design
    // in Xcode's preview while offline or away from a device.
    let iso = ISO8601DateFormatter()
    let now = Date()
    AppState.shared.localRuns = [
        LocalRun(id: "1", routeName: "Riverside Morning Loop", distance: 3.12, duration: 1820,
                 pace: 9.71, terrain: ["Parks", "Waterfront"], date: iso.string(from: now)),
        LocalRun(id: "2", routeName: "Bridge & Back", distance: 5.04, duration: 2710,
                 pace: 8.96, terrain: ["Urban"], date: iso.string(from: now.addingTimeInterval(-86_400))),
        LocalRun(id: "3", routeName: "Quick Neighborhood 2-Miler", distance: 2.01, duration: 1140,
                 pace: 9.45, terrain: ["Roads"], date: iso.string(from: now.addingTimeInterval(-3 * 86_400))),
    ]
    return NavigationStack { RunHistoryView() }
}
