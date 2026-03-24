import SwiftUI

@main
struct RepoAtlasApp: App {
    @StateObject private var store = RepoStore()
    @StateObject private var configManager = DeepSeekConfigManager()

    var body: some Scene {
        WindowGroup {
            MainWindowView()
                .environmentObject(store)
                .environmentObject(configManager)
                .frame(minWidth: 1180, minHeight: 760)
        }

        Settings {
            SettingsView()
                .environmentObject(configManager)
                .frame(width: 520, height: 280)
        }
    }
}
