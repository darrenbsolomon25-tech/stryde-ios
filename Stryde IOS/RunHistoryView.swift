import SwiftUI

struct RunHistoryView: View {
    private var appState = AppState.shared

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
                    LazyVStack(spacing: 8) {
                        ForEach(appState.localRuns) { run in
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
    NavigationStack { RunHistoryView() }
}
