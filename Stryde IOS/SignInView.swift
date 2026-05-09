import SwiftUI
import ClerkKit

struct SignInView: View {
    // @State is SwiftUI's useState — local to this view, triggers re-render on change
    @State private var mode: Mode = .signIn
    @State private var step: Step = .form

    @State private var email = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var code = ""

    @State private var loading = false
    @State private var errorMessage = ""

    // The in-progress sign-up object — we hold onto it between steps
    // so we can call verifyEmailCode() on the same instance
    @State private var pendingSignUp: SignUp? = nil

    enum Mode { case signIn, signUp }
    enum Step { case form, verify }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Logo
                Text("STRYDE")
                    .font(.system(size: 40, weight: .bold))
                    .foregroundColor(Color(hex: "#C6F135"))
                    .kerning(6)
                    .padding(.bottom, 8)

                Text("Run your city.")
                    .font(.system(size: 14))
                    .foregroundColor(Color(hex: "#888888"))
                    .padding(.bottom, 48)

                if step == .form {
                    // Sign In / Create Account toggle
                    HStack(spacing: 0) {
                        toggleButton("Sign in", isActive: mode == .signIn) {
                            switchMode(.signIn)
                        }
                        toggleButton("Create account", isActive: mode == .signUp) {
                            switchMode(.signUp)
                        }
                    }
                    .background(Color(hex: "#1A1A1A"))
                    .cornerRadius(10)
                    .padding(.bottom, 24)
                }

                if step == .verify {
                    verifyStep
                } else {
                    formStep
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 48)
        }
        .background(Color(hex: "#27272D").ignoresSafeArea())
    }

    // MARK: - Form step (email + password)

    private var formStep: some View {
        VStack(spacing: 0) {
            inputField("Email", text: $email, keyboard: .emailAddress)
                .autocapitalization(.none)
                .padding(.bottom, 16)

            SecureField("Password", text: $password)
                .strydeInput()
                .padding(.bottom, 16)

            if mode == .signUp {
                SecureField("Confirm password", text: $confirmPassword)
                    .strydeInput()
                    .padding(.bottom, 16)
            }

            if !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.system(size: 13))
                    .foregroundColor(Color(hex: "#FF6B6B"))
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 8)
            }

            actionButton(mode == .signIn ? "Sign in" : "Create account") {
                mode == .signIn ? handleSignIn() : handleSignUp()
            }
        }
    }

    // MARK: - Verify step (6-digit code)

    private var verifyStep: some View {
        VStack(spacing: 0) {
            Text("Check your email")
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(.white)
                .padding(.bottom, 8)

            Text("We sent a 6-digit code to \(email). Enter it below.")
                .font(.system(size: 14))
                .foregroundColor(Color(hex: "#888888"))
                .multilineTextAlignment(.center)
                .padding(.bottom, 24)

            inputField("000000", text: $code, keyboard: .numberPad)
                .padding(.bottom, 16)

            if !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.system(size: 13))
                    .foregroundColor(Color(hex: "#FF6B6B"))
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 8)
            }

            actionButton("Verify email") { handleVerify() }

            Button("Back") { switchMode(.signUp) }
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(Color(hex: "#C6F135"))
                .padding(.top, 24)
        }
    }

    // MARK: - Clerk calls

    private func handleSignIn() {
        loading = true
        errorMessage = ""
        // Task {} is how you call async code from a button — same as async function in JS
        Task {
            defer { loading = false }
            do {
                let signIn = try await Clerk.shared.auth.signInWithPassword(
                    identifier: email,
                    password: password
                )
                if signIn.status == .complete, let sessionId = signIn.createdSessionId {
                    // Activates the session — Clerk.shared.user becomes non-nil
                    // ContentView sees the change and switches to Home automatically
                    try await Clerk.shared.auth.setActive(sessionId: sessionId)
                } else {
                    errorMessage = "Sign-in incomplete. Check your credentials and try again."
                }
            } catch {
                errorMessage = clerkMessage(error)
            }
        }
    }

    private func handleSignUp() {
        guard password == confirmPassword else {
            errorMessage = "Passwords do not match."
            return
        }
        loading = true
        errorMessage = ""
        Task {
            defer { loading = false }
            do {
                // Create the account — Clerk queues a verification email
                let signUp = try await Clerk.shared.auth.signUp(
                    emailAddress: email,
                    password: password
                )
                // Send the 6-digit code to the email
                let prepared = try await signUp.sendEmailCode()
                pendingSignUp = prepared
                step = .verify
            } catch {
                errorMessage = clerkMessage(error)
            }
        }
    }

    private func handleVerify() {
        guard let signUp = pendingSignUp else { return }
        loading = true
        errorMessage = ""
        Task {
            defer { loading = false }
            do {
                let result = try await signUp.verifyEmailCode(code)
                if result.status == .complete, let sessionId = result.createdSessionId {
                    try await Clerk.shared.auth.setActive(sessionId: sessionId)
                } else {
                    errorMessage = "Verification incomplete. Try again."
                }
            } catch {
                errorMessage = clerkMessage(error)
            }
        }
    }

    // MARK: - Helpers

    private func switchMode(_ newMode: Mode) {
        mode = newMode
        step = .form
        errorMessage = ""
        email = ""
        password = ""
        confirmPassword = ""
        code = ""
        pendingSignUp = nil
    }

    private func clerkMessage(_ error: Error) -> String {
        // Clerk errors have a localizedDescription — use it, fall back to generic
        let msg = error.localizedDescription
        return msg.isEmpty ? "Something went wrong." : msg
    }

    // MARK: - Sub-views

    private func toggleButton(_ label: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(isActive ? Color(hex: "#27272D") : Color(hex: "#888888"))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(isActive ? Color(hex: "#C6F135") : Color.clear)
                .cornerRadius(8)
        }
        .padding(4)
    }

    private func inputField(_ placeholder: String, text: Binding<String>, keyboard: UIKeyboardType) -> some View {
        TextField(placeholder, text: text)
            .keyboardType(keyboard)
            .strydeInput()
    }

    private func actionButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if loading {
                ProgressView()
                    .tint(Color(hex: "#27272D"))
            } else {
                Text(label)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(Color(hex: "#27272D"))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(Color(hex: "#C6F135").opacity(loading ? 0.6 : 1))
        .cornerRadius(10)
        .disabled(loading)
    }
}

// MARK: - Shared modifiers and helpers

// ViewModifier is SwiftUI's way of packaging a reusable set of style rules —
// like a StyleSheet entry you can attach to any view with .modifier() or a custom method
struct StrydeInputStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(Color(hex: "#1A1A1A"))
            .cornerRadius(10)
            .foregroundColor(.white)
            .font(.system(size: 15))
    }
}

extension View {
    func strydeInput() -> some View {
        modifier(StrydeInputStyle())
    }
}

// Lets us write Color(hex: "#C6F135") — Swift doesn't have this built in
extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r = Double((int >> 16) & 0xFF) / 255
        let g = Double((int >> 8) & 0xFF) / 255
        let b = Double(int & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}

#Preview {
    SignInView()
}
