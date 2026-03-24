import SwiftUI

struct FileTreeView: View {
    let nodes: [FileNode]
    @Binding var selection: String?

    var body: some View {
        List(selection: $selection) {
            OutlineGroup(nodes, children: \.children) { node in
                if node.isDirectory {
                    Label(node.name, systemImage: "folder")
                        .font(.body)
                } else {
                    Label(node.name, systemImage: "doc.plaintext")
                        .tag(node.relativePath as String?)
                        .help(node.relativePath)
                }
            }
        }
        .listStyle(.sidebar)
    }
}
