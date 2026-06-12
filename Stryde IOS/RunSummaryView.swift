import SwiftUI

struct RunSummaryView: View {
    let run: LocalRun
    let fromHistory: Bool  // true when opened from RunHistoryView — don't re-save

    @Environment(\.dismiss) private var dismiss
    @State private var didSave = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("RUN COMPLETE")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(Color(hex: "#C6F135"))
                    .kerning(3)
                Text(run.routeName)
                    .font(.system(size: 32, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(2)
                Text(formattedDate(run.date))
                    .font(.system(size: 14))
                    .foregroundColor(Color(hex: "#888888"))
            }
            .padding(.horizontal, 24)
            .padding(.top, 48)
            .padding(.bottom, 32)

            // 2×2 stats grid
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                statCard(value: String(format: "%.2f", run.distance), label: "Miles")
                statCard(value: formatTime(run.duration), label: "Time")
                statCard(value: formatPace(run.pace), label: "Pace /mi")
                statCard(value: run.terrain.isEmpty ? "—" : run.terrain.joined(separator: ", "), label: "Terrain")
            }
            .padding(.horizontal, 24)

            Spacer()

            // After a finished run this collapses the entire stack to HomeView in
            // one tap (AppState.popToHome flips the root push flag, which removes
            // every screen above Home). When this screen is opened read-only from
            // Run History, the stack is Home → History → Summary instead, so we
            // just dismiss one level back to the history list — the expected
            // behavior when browsing past runs.
            Button {
                if fromHistory {
                    dismiss()
                } else {
                    AppState.shared.popToHome()
                }
            } label: {
                Text("Back to Home")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(Color(hex: "#27272D"))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color(hex: "#C6F135"))
                    .cornerRadius(16)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Color(hex: "#27272D").ignoresSafeArea())
        .navigationBarHidden(true)
        // .task runs once on first appearance — same as useEffect([], []) in React.
        // The didSave guard mirrors the useRef(false) pattern in RunSummaryScreen.js.
        .task {
            guard !fromHistory, !didSave else { return }
            didSave = true
            AppState.shared.addLocalRun(run)
        }
    }

    private func statCard(value: String, label: String) -> some View {
        VStack(spacing: 6) {
            Text(value)
                .font(.system(size: 28, weight: .bold))
                .foregroundColor(Color(hex: "#C6F135"))
                .minimumScaleFactor(0.6)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(Color(hex: "#888888"))
                .textCase(.uppercase)
                .kerning(0.5)
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .background(Color(hex: "#1A1A1A"))
        .cornerRadius(16)
    }

    private func formattedDate(_ iso: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: iso) else { return iso }
        let f = DateFormatter()
        f.dateStyle = .full
        f.timeStyle = .none
        return f.string(from: date)
    }

    private func formatTime(_ s: Int) -> String {
        String(format: "%02d:%02d", s / 60, s % 60)
    }

    private func formatPace(_ p: Double) -> String {
        guard p > 0, p.isFinite, p < 30 else { return "--:--" }
        let m = Int(p)
        let s = Int((p - Double(m)) * 60)
        return String(format: "%d:%02d", m, s)
    }
}

#Preview {
    NavigationStack {
        RunSummaryView(
            run: LocalRun(id: nil, routeName: "Park Loop", distance: 3.12,
                          duration: 1820, pace: 9.71, terrain: ["Parks", "Waterfront"],
                          date: ISO8601DateFormatter().string(from: Date())),
            fromHistory: false
        )
    }
}
