import SwiftUI
import VaulttyMobile

@main
struct VaulttyMobileApp: App {
    var body: some Scene {
        WindowGroup {
            VaulttyMobileRootView()
                .preferredColorScheme(.dark)
        }
    }
}

