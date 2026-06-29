import SwiftUI
import ClerkKit

// Side drawer — slides in from the left over HomeView's ZStack.
// Uses Buttons (not NavigationLinks) so it can close itself before triggering
// navigation, which prevents the drawer overlay from persisting over the pushed screen.
struct DrawerView: View {
    private var appState = AppState.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("STRYDE")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(Color(hex: "#C6F135"))
                    .kerning(4)
                Text(Clerk.shared.user?.primaryEmailAddress?.emailAddress ?? "")
                    .font(.system(size: 13))
                    .foregroundColor(Color(hex: "#888888"))
                    .lineLimit(1)
            }
            .padding(.horizontal, 24)
            .padding(.top, 64)
            .padding(.bottom, 32)

            Divider()
                .background(Color(hex: "#333333"))
                .padding(.horizontal, 24)

            // Close drawer first, then flip the flag that HomeView watches.
            // HomeView uses .navigationDestination(isPresented:) to push the screen.
            drawerItem("History") {
                withAnimation(.easeInOut(duration: 0.2)) { appState.drawerOpen = false }
                // Small delay lets the drawer close animation finish before pushing.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    appState.showRunHistory = true
                }
            }
            drawerItem("Settings") {
                withAnimation(.easeInOut(duration: 0.2)) { appState.drawerOpen = false }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    appState.showSettings = true
                }
            }

            Spacer()

            Button {
                withAnimation(.easeInOut(duration: 0.2)) { appState.drawerOpen = false }
                Task { await appState.signOut() }
            } label: {
                Text("Sign out")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(Color(hex: "#888888"))
                    .padding(.horizontal, 24)
                    .padding(.bottom, 48)
            }
        }
        .frame(width: 280)
        .frame(maxHeight: .infinity)
        .background(Color(hex: "#111111").ignoresSafeArea())
    }

    private func drawerItem(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 17, weight: .medium))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
        }
    }
}
