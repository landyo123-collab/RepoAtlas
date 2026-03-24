import AppKit
import Foundation

enum RepositoryPicker {
    static func pickFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose a Repository Folder"
        panel.prompt = "Open"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}
