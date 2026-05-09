//
//  Stryde_IOSApp.swift
//  Stryde IOS
//
//  Created by Darren Solomon on 5/7/26.
//

import SwiftUI
import ClerkKit

@main
struct Stryde_IOSApp: App {
    init() {
        Clerk.configure(publishableKey: "pk_test_cmFyZS1sYW1wcmV5LTM5LmNsZXJrLmFjY291bnRzLmRldiQ")
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
