import SwiftUI

@main
struct NavNativeApp: App {
    @StateObject private var model = NavModel()
    @StateObject private var settings = SettingsStore.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .preferredColorScheme(settings.themeMode.colorScheme)
                .accentColor(Theme.primary)
        }
    }
}
