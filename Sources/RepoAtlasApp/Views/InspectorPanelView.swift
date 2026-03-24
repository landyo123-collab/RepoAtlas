import SwiftUI

struct InspectorPanelView: View {
    @EnvironmentObject private var store: RepoStore
    @EnvironmentObject private var configManager: DeepSeekConfigManager

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SummaryView()
                Divider()
                QAView(configuration: configManager.configuration)
                Divider()
                LaunchpadView(configuration: configManager.configuration)
            }
            .padding(18)
        }
    }
}
