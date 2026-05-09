import SwiftUI
import ClerkKit

struct ContentView: View {
    private var appState = AppState.shared

    var body: some View {
        if Clerk.shared.user == nil {
            SignInView()
        } else if !appState.bootDone {
            ZStack {
                Color(hex: "#27272D").ignoresSafeArea()
                VStack(spacing: 16) {
                    ProgressView()
                        .tint(Color(hex: "#C6F135"))
                    Text("Loading...")
                        .font(.system(size: 14))
                        .foregroundColor(Color(hex: "#888888"))
                }
            }
            .task {
                await appState.boot()
            }
        } else if !appState.hasProfile {
            OnboardingView()
        } else {
            // NavigationStack is the SwiftUI equivalent of React Navigation's stack.
            // Every screen pushed from HomeView lives inside this same stack.
            NavigationStack {
                HomeView()
            }
        }
    }
}

#Preview {
    ContentView()
}
