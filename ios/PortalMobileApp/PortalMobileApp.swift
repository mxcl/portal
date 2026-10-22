import SwiftUI
import PortalMobile

@main
struct PortalMobileApp: App {
    var body: some Scene {
        WindowGroup {
            PortalMobileRootView()
                .preferredColorScheme(.dark)
        }
    }
}

