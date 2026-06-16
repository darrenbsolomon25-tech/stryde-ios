import SwiftUI
import ClerkKit

struct ContentView: View {
    private var appState = AppState.shared

    var body: some View {
        #if DEBUG
        // DEBUG-only: when the "-StrydeAuthBypass" scheme arg is set, AppState.init
        // has already seeded a fake session, so go straight to the app shell and
        // skip both the Clerk gate and boot(). This whole branch is compiled out in
        // Release (see AppState.authBypassEnabled), so it can never ship.
        if AppState.authBypassEnabled {
            appShell
        } else {
            mainFlow
        }
        #else
        mainFlow
        #endif
    }

    // The real launch flow: Clerk gate → boot → Onboarding/Home.
    @ViewBuilder
    private var mainFlow: some View {
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
            appShell
        }
    }

    // NavigationStack is the SwiftUI equivalent of React Navigation's stack.
    // Every screen pushed from HomeView lives inside this same stack.
    private var appShell: some View {
        NavigationStack {
            HomeView()
        }
    }
}

#Preview {
    ContentView()
}
