import SwiftUI

@main
struct NavNativeApp: App {
    @StateObject private var model = NavModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .preferredColorScheme(.light)
        }
    }
}
