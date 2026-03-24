import Foundation

struct FileNode: Identifiable, Hashable {
    let id: String
    let name: String
    let relativePath: String
    let isDirectory: Bool
    var children: [FileNode]?

    static func buildTree(from files: [RepoFile]) -> [FileNode] {
        let paths = files.map(\.relativePath).sorted()
        let trie = FileNodeTrieNode(name: "", path: "", isDirectory: true)

        for path in paths {
            let parts = path.split(separator: "/").map(String.init)
            trie.insert(parts: parts)
        }

        return trie.children.values
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { $0.toNode() }
    }
}

private final class FileNodeTrieNode {
    let name: String
    let path: String
    var isDirectory: Bool
    var children: [String: FileNodeTrieNode] = [:]

    init(name: String, path: String, isDirectory: Bool) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
    }

    func insert(parts: [String], currentIndex: Int = 0) {
        guard currentIndex < parts.count else { return }
        let part = parts[currentIndex]
        let isLast = currentIndex == parts.count - 1
        let nextPath = path.isEmpty ? part : "\(path)/\(part)"

        let child = children[part] ?? FileNodeTrieNode(name: part, path: nextPath, isDirectory: !isLast)
        if isLast { child.isDirectory = false }
        children[part] = child
        child.insert(parts: parts, currentIndex: currentIndex + 1)
    }

    func toNode() -> FileNode {
        let childNodes = children.values
            .sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory {
                    return lhs.isDirectory && !rhs.isDirectory
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            .map { $0.toNode() }

        return FileNode(
            id: path,
            name: name,
            relativePath: path,
            isDirectory: isDirectory,
            children: childNodes.isEmpty ? nil : childNodes
        )
    }
}
