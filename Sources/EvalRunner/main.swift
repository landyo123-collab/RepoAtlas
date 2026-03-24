import Foundation
import SQLite3

// MARK: - PADA+ Eval Runner
// Standalone CLI that creates a synthetic indexed repo, runs the full
// deterministic pipeline (classifier → candidates → anchors → eval),
// and prints the evaluation report.

func runEval() {
    print("=== PADA+ Eval Runner ===")
    print("Builder version: \(DossierCache.builderVersion)")
    print("")

    // Step 1: Create a temporary repo with synthetic indexed data
    let tmpDir = NSTemporaryDirectory() + "pada_eval_\(ProcessInfo.processInfo.processIdentifier)"
    let repoRoot = tmpDir + "/test_repo"
    try! FileManager.default.createDirectory(atPath: repoRoot, withIntermediateDirectories: true)

    print("Creating synthetic repo at \(repoRoot)")

    guard let store = try? RepoMemoryStore(repoRoot: repoRoot) else {
        print("FATAL: Cannot create RepoMemoryStore")
        return
    }

    // Insert repo metadata
    let meta = RepoMeta(
        rootPath: repoRoot,
        displayName: "EvalTestRepo",
        repoHash: "eval_hash_001",
        fileCount: 12,
        indexedFileCount: 12,
        languageMix: ["swift": 10, "markdown": 1],
        manifestList: ["Package.swift"],
        topLevelDirs: ["Sources", "Tests"],
        runtimeShape: "swiftpm",
        passport: "A Swift macOS application for managing tasks. Entry point is AppMain.swift, services in Services/, models in Models/.",
        indexedAt: Date(),
        scanDurationMs: 100,
        indexVersion: 1
    )
    try? store.upsertRepoMeta(meta)

    // Insert synthetic files
    let files: [(path: String, type: String, tier: String, lang: String, lines: Int, tags: [String], summary: String)] = [
        ("Sources/App/AppMain.swift", "entrypoint", "firstParty", "swift", 45, ["entrypoint"], "Main app entry point, creates window and root view"),
        ("Sources/App/TaskStore.swift", "source", "firstParty", "swift", 180, ["model"], "Observable store managing task CRUD operations"),
        ("Sources/App/TaskService.swift", "source", "firstParty", "swift", 120, ["service"], "Network service for syncing tasks with backend API"),
        ("Sources/App/Models/Task.swift", "source", "firstParty", "swift", 35, ["model"], "Task model with title, status, priority fields"),
        ("Sources/App/Models/TaskFilter.swift", "source", "firstParty", "swift", 28, ["model"], "Filter and sort options for task list"),
        ("Sources/App/Views/TaskListView.swift", "source", "firstParty", "swift", 95, ["view"], "SwiftUI list view showing filtered tasks"),
        ("Sources/App/Views/TaskDetailView.swift", "source", "firstParty", "swift", 75, ["view"], "Detail view for editing a single task"),
        ("Sources/App/Config/AppConfig.swift", "config", "firstParty", "swift", 20, ["config"], "App configuration: API base URL, sync interval"),
        ("README.md", "docs", "firstParty", "markdown", 60, ["docs"], "Project overview, setup instructions, architecture guide"),
        ("Package.swift", "config", "firstParty", "swift", 25, ["manifest"], "SwiftPM manifest defining targets and dependencies"),
        ("Tests/TaskStoreTests.swift", "test", "firstParty", "swift", 85, ["test"], "Unit tests for TaskStore CRUD operations"),
        ("Tests/TaskServiceTests.swift", "test", "firstParty", "swift", 65, ["test"], "Integration tests for TaskService API calls"),
    ]

    var fileIds: [String: Int64] = [:]
    for f in files {
        let fid = try! store.insertFile(
            relativePath: f.path, name: (f.path as NSString).lastPathComponent,
            ext: (f.path as NSString).pathExtension, fileType: f.type,
            roleTags: f.tags, language: f.lang, sizeBytes: f.lines * 40,
            lineCount: f.lines, modifiedAt: Date().timeIntervalSince1970,
            contentHash: f.path.sha256Hex, importanceScore: Double(f.lines) / 180.0,
            depth: f.path.components(separatedBy: "/").count - 1,
            isIndexed: true, summary: f.summary, corpusTier: f.tier, projectRoot: ""
        )
        fileIds[f.path] = fid
    }

    // Insert symbols
    let symbols: [(file: String, name: String, kind: String, line: Int, sig: String)] = [
        ("Sources/App/AppMain.swift", "AppMain", "struct", 5, "struct AppMain: App"),
        ("Sources/App/TaskStore.swift", "TaskStore", "class", 8, "class TaskStore: ObservableObject"),
        ("Sources/App/TaskStore.swift", "addTask", "function", 25, "func addTask(_ task: Task)"),
        ("Sources/App/TaskStore.swift", "deleteTask", "function", 45, "func deleteTask(id: UUID)"),
        ("Sources/App/TaskStore.swift", "filteredTasks", "function", 65, "func filteredTasks(filter: TaskFilter) -> [Task]"),
        ("Sources/App/TaskService.swift", "TaskService", "class", 5, "class TaskService"),
        ("Sources/App/TaskService.swift", "syncTasks", "function", 20, "func syncTasks() async throws"),
        ("Sources/App/TaskService.swift", "fetchRemoteTasks", "function", 55, "func fetchRemoteTasks() async throws -> [Task]"),
        ("Sources/App/Models/Task.swift", "Task", "struct", 3, "struct Task: Identifiable, Codable"),
        ("Sources/App/Models/TaskFilter.swift", "TaskFilter", "struct", 3, "struct TaskFilter"),
        ("Sources/App/Views/TaskListView.swift", "TaskListView", "struct", 5, "struct TaskListView: View"),
        ("Sources/App/Views/TaskDetailView.swift", "TaskDetailView", "struct", 5, "struct TaskDetailView: View"),
    ]

    for sym in symbols {
        guard let fid = fileIds[sym.file] else { continue }
        try? store.insertSymbol(
            fileId: fid, name: sym.name, kind: sym.kind,
            lineNumber: sym.line, signature: sym.sig, container: "", filePath: sym.file
        )
    }

    // Insert segments with realistic content
    let segmentData: [(file: String, segments: [(idx: Int, start: Int, end: Int, type: String, label: String, content: String)])] = [
        ("Sources/App/AppMain.swift", [
            (0, 1, 3, "import_block", "imports", "import SwiftUI\nimport Combine"),
            (1, 5, 25, "struct", "AppMain", "@main\nstruct AppMain: App {\n    @StateObject private var store = TaskStore()\n    @StateObject private var service = TaskService()\n\n    var body: some Scene {\n        WindowGroup {\n            TaskListView()\n                .environmentObject(store)\n                .environmentObject(service)\n        }\n    }\n}"),
        ]),
        ("Sources/App/TaskStore.swift", [
            (0, 1, 3, "import_block", "imports", "import Foundation\nimport Combine"),
            (1, 8, 23, "class", "TaskStore", "class TaskStore: ObservableObject {\n    @Published var tasks: [Task] = []\n    @Published var isLoading = false\n    private var cancellables = Set<AnyCancellable>()\n\n    init() {\n        loadFromDisk()\n    }"),
            (2, 25, 43, "function", "addTask", "    func addTask(_ task: Task) {\n        tasks.append(task)\n        saveToDisk()\n        NotificationCenter.default.post(name: .taskAdded, object: task)\n    }"),
            (3, 45, 63, "function", "deleteTask", "    func deleteTask(id: UUID) {\n        tasks.removeAll { $0.id == id }\n        saveToDisk()\n        NotificationCenter.default.post(name: .taskDeleted, object: id)\n    }"),
            (4, 65, 90, "function", "filteredTasks", "    func filteredTasks(filter: TaskFilter) -> [Task] {\n        var result = tasks\n        if let status = filter.status {\n            result = result.filter { $0.status == status }\n        }\n        if let priority = filter.priority {\n            result = result.filter { $0.priority == priority }\n        }\n        return result.sorted(by: filter.sortOrder)\n    }"),
        ]),
        ("Sources/App/TaskService.swift", [
            (0, 1, 4, "import_block", "imports", "import Foundation"),
            (1, 5, 18, "class", "TaskService", "class TaskService {\n    private let baseURL: URL\n    private let session: URLSession\n\n    init(config: AppConfig = .shared) {\n        self.baseURL = config.apiBaseURL\n        self.session = URLSession.shared\n    }"),
            (2, 20, 53, "function", "syncTasks", "    func syncTasks() async throws {\n        let remote = try await fetchRemoteTasks()\n        // Merge logic: remote wins for conflicts\n        for task in remote {\n            // upsert into local store\n        }\n    }"),
            (3, 55, 80, "function", "fetchRemoteTasks", "    func fetchRemoteTasks() async throws -> [Task] {\n        let url = baseURL.appendingPathComponent(\"tasks\")\n        let (data, _) = try await session.data(from: url)\n        return try JSONDecoder().decode([Task].self, from: data)\n    }"),
        ]),
        ("Sources/App/Models/Task.swift", [
            (0, 1, 35, "struct", "Task", "import Foundation\n\nstruct Task: Identifiable, Codable {\n    let id: UUID\n    var title: String\n    var status: TaskStatus\n    var priority: TaskPriority\n    var dueDate: Date?\n    var notes: String\n\n    enum TaskStatus: String, Codable {\n        case todo, inProgress, done\n    }\n\n    enum TaskPriority: Int, Codable {\n        case low = 0, medium = 1, high = 2\n    }\n}"),
        ]),
        ("Sources/App/Models/TaskFilter.swift", [
            (0, 1, 28, "struct", "TaskFilter", "import Foundation\n\nstruct TaskFilter {\n    var status: Task.TaskStatus?\n    var priority: Task.TaskPriority?\n    var sortOrder: (Task, Task) -> Bool = { $0.title < $1.title }\n}"),
        ]),
        ("Sources/App/Views/TaskListView.swift", [
            (0, 1, 2, "import_block", "imports", "import SwiftUI"),
            (1, 5, 50, "struct", "TaskListView", "struct TaskListView: View {\n    @EnvironmentObject var store: TaskStore\n    @State private var filter = TaskFilter()\n\n    var body: some View {\n        List(store.filteredTasks(filter: filter)) { task in\n            NavigationLink(destination: TaskDetailView(task: task)) {\n                TaskRow(task: task)\n            }\n        }\n    }\n}"),
        ]),
        ("Sources/App/Views/TaskDetailView.swift", [
            (0, 1, 2, "import_block", "imports", "import SwiftUI"),
            (1, 5, 40, "struct", "TaskDetailView", "struct TaskDetailView: View {\n    @EnvironmentObject var store: TaskStore\n    let task: Task\n\n    var body: some View {\n        Form {\n            TextField(\"Title\", text: .constant(task.title))\n            Picker(\"Status\", selection: .constant(task.status)) {\n                // status options\n            }\n        }\n    }\n}"),
        ]),
        ("Sources/App/Config/AppConfig.swift", [
            (0, 1, 20, "struct", "AppConfig", "import Foundation\n\nstruct AppConfig {\n    static let shared = AppConfig()\n    let apiBaseURL = URL(string: \"https://api.example.com\")!\n    let syncInterval: TimeInterval = 300\n}"),
        ]),
        ("README.md", [
            (0, 1, 30, "section", "Overview", "# EvalTestRepo\n\nA task management app built with SwiftUI.\n\n## Architecture\n\nThe app uses MVVM pattern:\n- **Models**: Task.swift, TaskFilter.swift\n- **Views**: TaskListView.swift, TaskDetailView.swift\n- **Store**: TaskStore.swift manages state\n- **Service**: TaskService.swift handles API sync\n\nEntry point: AppMain.swift"),
            (1, 31, 60, "section", "Setup", "## Getting Started\n\n1. Clone the repo\n2. Open in Xcode\n3. Build and run\n\n## API Configuration\n\nSee AppConfig.swift for API settings."),
        ]),
        ("Tests/TaskStoreTests.swift", [
            (0, 1, 3, "import_block", "imports", "import XCTest\n@testable import App"),
            (1, 5, 40, "class", "TaskStoreTests", "class TaskStoreTests: XCTestCase {\n    var store: TaskStore!\n\n    override func setUp() {\n        store = TaskStore()\n    }\n\n    func testAddTask() {\n        let task = Task(id: UUID(), title: \"Test\", status: .todo, priority: .medium, dueDate: nil, notes: \"\")\n        store.addTask(task)\n        XCTAssertEqual(store.tasks.count, 1)\n    }\n\n    func testDeleteTask() {\n        let task = Task(id: UUID(), title: \"Test\", status: .todo, priority: .medium, dueDate: nil, notes: \"\")\n        store.addTask(task)\n        store.deleteTask(id: task.id)\n        XCTAssertEqual(store.tasks.count, 0)\n    }\n}"),
        ]),
        ("Tests/TaskServiceTests.swift", [
            (0, 1, 3, "import_block", "imports", "import XCTest\n@testable import App"),
            (1, 5, 35, "class", "TaskServiceTests", "class TaskServiceTests: XCTestCase {\n    func testFetchRemoteTasks() async throws {\n        let service = TaskService()\n        // Would need mock server\n        // let tasks = try await service.fetchRemoteTasks()\n    }\n\n    func testSyncTasks() async throws {\n        let service = TaskService()\n        // Sync test with mock data\n    }\n}"),
        ]),
    ]

    for fileEntry in segmentData {
        guard let fid = fileIds[fileEntry.file] else { continue }
        for seg in fileEntry.segments {
            try? store.insertSegment(
                fileId: fid, segmentIndex: seg.idx,
                startLine: seg.start, endLine: seg.end,
                tokenEstimate: seg.content.estimatedTokenCount,
                segmentType: seg.type, label: seg.label,
                content: seg.content, filePath: fileEntry.file
            )
        }
    }

    // Insert references (import graph)
    let refs: [(source: String, target: String, symbol: String, kind: String, line: Int)] = [
        ("Sources/App/AppMain.swift", "Sources/App/TaskStore.swift", "TaskStore", "reference", 7),
        ("Sources/App/AppMain.swift", "Sources/App/TaskService.swift", "TaskService", "reference", 8),
        ("Sources/App/AppMain.swift", "Sources/App/Views/TaskListView.swift", "TaskListView", "reference", 12),
        ("Sources/App/TaskStore.swift", "Sources/App/Models/Task.swift", "Task", "import", 2),
        ("Sources/App/TaskStore.swift", "Sources/App/Models/TaskFilter.swift", "TaskFilter", "import", 2),
        ("Sources/App/TaskService.swift", "Sources/App/Models/Task.swift", "Task", "import", 1),
        ("Sources/App/TaskService.swift", "Sources/App/Config/AppConfig.swift", "AppConfig", "reference", 9),
        ("Sources/App/Views/TaskListView.swift", "Sources/App/TaskStore.swift", "TaskStore", "reference", 6),
        ("Sources/App/Views/TaskListView.swift", "Sources/App/Models/TaskFilter.swift", "TaskFilter", "reference", 8),
        ("Sources/App/Views/TaskListView.swift", "Sources/App/Views/TaskDetailView.swift", "TaskDetailView", "reference", 11),
        ("Sources/App/Views/TaskDetailView.swift", "Sources/App/TaskStore.swift", "TaskStore", "reference", 6),
        ("Sources/App/Views/TaskDetailView.swift", "Sources/App/Models/Task.swift", "Task", "reference", 7),
        ("Tests/TaskStoreTests.swift", "Sources/App/TaskStore.swift", "TaskStore", "reference", 6),
        ("Tests/TaskStoreTests.swift", "Sources/App/Models/Task.swift", "Task", "reference", 12),
        ("Tests/TaskServiceTests.swift", "Sources/App/TaskService.swift", "TaskService", "reference", 6),
    ]

    for ref in refs {
        guard let srcId = fileIds[ref.source] else { continue }
        try? store.insertReference(
            sourceFileId: srcId, targetPath: ref.target,
            targetSymbol: ref.symbol, kind: ref.kind, lineNumber: ref.line
        )
    }

    // Import edges are derived from refs table — no separate insert needed

    // Insert subtree summaries
    try? store.upsertSubtreeSummary(root: "Sources/App", summary: "Main application code: entry point, store, service, models, views", fileCount: 8, firstPartyCount: 8, languageMix: ["swift": 8], manifestPaths: [])
    try? store.upsertSubtreeSummary(root: "Sources/App/Models", summary: "Data model types: Task and TaskFilter", fileCount: 2, firstPartyCount: 2, languageMix: ["swift": 2], manifestPaths: [])
    try? store.upsertSubtreeSummary(root: "Sources/App/Views", summary: "SwiftUI views: TaskListView, TaskDetailView", fileCount: 2, firstPartyCount: 2, languageMix: ["swift": 2], manifestPaths: [])
    try? store.upsertSubtreeSummary(root: "Tests", summary: "Unit and integration tests for TaskStore and TaskService", fileCount: 2, firstPartyCount: 2, languageMix: ["swift": 2], manifestPaths: [])

    print("Synthetic repo created: \(files.count) files, \(symbols.count) symbols, \(refs.count) references")
    print("")

    // Step 2: Run eval cases
    let classifier = QueryPolicyClassifier()
    let anchorSelector = DeterministicAnchorSelector()
    let docLinker = DocCodeLinker()
    let governingDetector = GoverningFileDetector()
    let harness = EvidenceEvalHarness()

    let evalCases: [EvidenceEvalHarness.EvalCase] = [
        // Generic cases
        EvidenceEvalHarness.EvalCase(
            name: "repo_overview",
            query: "Give me a tour of this repository. What are the main components?",
            expectedFiles: ["README.md"],
            expectedZones: ["Sources/App"],
            expectedQueryType: .wholeSystem,
            minCoverage: 0.3
        ),
        EvidenceEvalHarness.EvalCase(
            name: "architecture",
            query: "How is this codebase structured? What are the major modules?",
            expectedFiles: ["README.md", "Package.swift"],
            expectedZones: ["Sources/App", "Tests"],
            expectedQueryType: .architecture,
            minCoverage: 0.3
        ),
        // Symbol-targeted implementation query
        EvidenceEvalHarness.EvalCase(
            name: "impl_TaskStore",
            query: "How does TaskStore work? Where is addTask implemented?",
            expectedFiles: ["Sources/App/TaskStore.swift"],
            expectedZones: ["Sources/App"],
            expectedQueryType: .implementation,
            minCoverage: 0.5
        ),
        // Cross-cutting implementation query
        EvidenceEvalHarness.EvalCase(
            name: "impl_sync_flow",
            query: "How does task syncing work? What does syncTasks call?",
            expectedFiles: ["Sources/App/TaskService.swift"],
            expectedZones: ["Sources/App"],
            expectedQueryType: .implementation,
            minCoverage: 0.5
        ),
        // Debugging query
        EvidenceEvalHarness.EvalCase(
            name: "debug_tests",
            query: "Why might the TaskStore tests fail? What do they test?",
            expectedFiles: ["Tests/TaskStoreTests.swift", "Sources/App/TaskStore.swift"],
            expectedZones: ["Tests"],
            expectedQueryType: .debugging,
            minCoverage: 0.4
        ),
        // Mixed/entry point query
        EvidenceEvalHarness.EvalCase(
            name: "entry_point",
            query: "Where is the main entry point? How does execution start?",
            expectedFiles: ["Sources/App/AppMain.swift"],
            expectedZones: ["Sources/App"],
            expectedQueryType: .implementation,
            minCoverage: 0.5
        ),
        // Vague query cases (planner should activate for these)
        EvidenceEvalHarness.EvalCase(
            name: "vague_status",
            query: "How is this project looking?",
            expectedFiles: ["README.md"],
            expectedZones: ["Sources/App"],
            expectedQueryType: .wholeSystem,
            minCoverage: 0.3
        ),
        EvidenceEvalHarness.EvalCase(
            name: "vague_tour",
            query: "Give me a tour of this repo",
            expectedFiles: ["README.md"],
            expectedZones: ["Sources/App"],
            expectedQueryType: .wholeSystem,
            minCoverage: 0.3
        ),
        EvidenceEvalHarness.EvalCase(
            name: "vague_read_first",
            query: "What should I read first?",
            expectedFiles: ["README.md"],
            expectedZones: [],
            expectedQueryType: .wholeSystem,
            minCoverage: 0.3
        ),
    ]

    var results: [EvidenceEvalHarness.EvalResult] = []
    let totalFirstParty = store.firstPartyFiles(limit: 10000).count

    for evalCase in evalCases {
        print("Running case: \(evalCase.name)...")

        // Stage 1: Classify
        let (queryIntent, queryPolicy) = classifier.classify(query: evalCase.query, repoFileCount: totalFirstParty)

        // Stage 2: Deterministic candidate discovery
        var candidates: [String: PADACandidate] = [:]

        // FTS path matches
        for term in queryIntent.extractedTerms {
            let fileMatches = store.searchFiles(query: term, limit: 30)
            for match in fileMatches {
                guard let file = store.file(byId: match.rowid) else { continue }
                if file.corpusTier == "binaryOrIgnored" || file.corpusTier == "externalDependency" { continue }
                let prov = EvidenceProvenance(source: .ftsPath, trigger: term, hopDistance: 0, score: 3.0)
                addOrUpdate(&candidates, file: file, score: 3.0, provenance: prov)
            }
        }

        // FTS segment content matches
        for term in queryIntent.extractedTerms {
            let segMatches = store.searchSegments(query: term, limit: 40)
            for match in segMatches {
                guard let seg = store.segment(byId: match.rowid) else { continue }
                guard let file = store.file(byId: seg.fileId) else { continue }
                if file.corpusTier == "binaryOrIgnored" || file.corpusTier == "externalDependency" { continue }
                let prov = EvidenceProvenance(source: .ftsContent, trigger: term, hopDistance: 0, score: 2.5)
                addOrUpdate(&candidates, file: file, score: 2.5, provenance: prov)
            }
        }

        // FTS symbol matches
        let symbolSearchTerms = queryIntent.symbolHints + queryIntent.extractedTerms
        for term in Set(symbolSearchTerms) {
            let symMatches = store.searchSymbols(query: term, limit: 20)
            for match in symMatches {
                guard let fileId = store.fileIdForSymbol(symbolId: match.rowid) else { continue }
                guard let file = store.file(byId: fileId) else { continue }
                if file.corpusTier == "binaryOrIgnored" || file.corpusTier == "externalDependency" { continue }
                let symbolScore: Double = queryIntent.symbolHints.contains(term) ? 5.0 : 3.5
                let prov = EvidenceProvenance(source: .ftsSymbol, trigger: term, hopDistance: 0, score: symbolScore)
                addOrUpdate(&candidates, file: file, score: symbolScore, provenance: prov)
            }
        }

        // Structural roles
        if queryPolicy.preferredFileTypes.contains("entrypoint") {
            for file in store.filesByType("entrypoint").prefix(5) {
                let prov = EvidenceProvenance(source: .structuralRole, trigger: "entrypoint", hopDistance: 0, score: 2.0)
                addOrUpdate(&candidates, file: file, score: 2.0, provenance: prov)
            }
        }
        if queryPolicy.includeDocs {
            for file in store.filesByType("docs").prefix(10) {
                let prov = EvidenceProvenance(source: .structuralRole, trigger: "docs", hopDistance: 0, score: 1.5)
                addOrUpdate(&candidates, file: file, score: 1.5, provenance: prov)
            }
        }
        if queryPolicy.includeTests {
            for file in store.filesByType("test").prefix(10) {
                let prov = EvidenceProvenance(source: .structuralRole, trigger: "test", hopDistance: 0, score: 1.0)
                addOrUpdate(&candidates, file: file, score: 1.0, provenance: prov)
            }
        }
        if queryPolicy.preferredFileTypes.contains("config") {
            for file in store.filesByType("config").prefix(8) {
                let prov = EvidenceProvenance(source: .structuralRole, trigger: "config", hopDistance: 0, score: 1.0)
                addOrUpdate(&candidates, file: file, score: 1.0, provenance: prov)
            }
        }

        // Stage 4b: Doc-code linking
        let links = docLinker.findLinks(candidates: candidates, store: store)
        docLinker.applyLinkBoosts(candidates: &candidates, links: links)

        // Stage 4c: Governing file detection
        let governingFiles = governingDetector.detect(
            candidates: candidates,
            store: store,
            queryType: queryIntent.primary
        )

        // Ensure governing files are in candidates with boosted scores
        for gf in governingFiles {
            if let file = store.file(byId: gf.fileId) {
                let prov = EvidenceProvenance(source: .governing, trigger: gf.reason, hopDistance: 0, score: gf.priority)
                addOrUpdate(&candidates, file: file, score: gf.priority, provenance: prov)
            }
        }

        // Stage 5: Deterministic anchor selection
        let anchorResult = anchorSelector.selectAnchors(
            candidates: candidates,
            queryIntent: queryIntent,
            queryPolicy: queryPolicy,
            store: store,
            passport: "A task management app built with SwiftUI.",
            governingFiles: governingFiles
        )

        // Build coverage report
        let evidencePaths = Set(anchorResult.exactEvidence.map(\.path))
        var gaps: [CoverageGap] = []
        var termsWithHits = 0
        for term in queryIntent.extractedTerms {
            let hasHit = candidates.values.contains { c in c.provenance.contains { $0.trigger == term } }
            if hasHit { termsWithHits += 1 }
            else { gaps.append(CoverageGap(area: term, gapType: .noFTSHit, description: "No match for '\(term)'")) }
        }
        let queryTermCoverage = queryIntent.extractedTerms.isEmpty ? 1.0 : Double(termsWithHits) / Double(queryIntent.extractedTerms.count)

        var symbolsResolved = 0
        for sym in queryIntent.symbolHints {
            let resolved = candidates.values.contains { c in c.provenance.contains { $0.source == .ftsSymbol && $0.trigger == sym } }
            if resolved { symbolsResolved += 1 }
        }
        let symbolCoverage = queryIntent.symbolHints.isEmpty ? 1.0 : Double(symbolsResolved) / Double(queryIntent.symbolHints.count)

        let coverageReport = CoverageReport(
            queryTermCoverage: queryTermCoverage,
            symbolDefinitionCoverage: symbolCoverage,
            importGraphCoverage: 0.8,
            gaps: gaps,
            totalFirstPartyFiles: totalFirstParty,
            filesExamined: candidates.count,
            filesIncluded: evidencePaths.count
        )

        // Assemble dossier
        let rankedCandidates = candidates.values.sorted { $0.score > $1.score }
        let mustRead = rankedCandidates.prefix(min(30, queryPolicy.maxFiles)).map { c in
            MustReadFile(path: c.path, role: c.fileType, priority: c.score,
                         why: c.provenance.prefix(2).map { "\($0.source.rawValue):\($0.trigger)" }.joined(separator: ", "),
                         provenance: c.provenance)
        }

        let diagnostics = BuilderDiagnostics(
            totalCandidatesConsidered: candidates.count,
            totalSegmentsExamined: 0, passesRun: 5,
            totalBuilderTokensUsed: 0,
            dossierTokenEstimate: anchorResult.anchorStats.totalTokens,
            elapsedMs: 0, stages: [],
            usedModel: "none (deterministic)",
            fallbackUsed: false, queryPolicy: queryPolicy
        )

        let confidence = ConfidenceReport(
            overall: (queryTermCoverage + symbolCoverage) / 2.0,
            implementationCoverage: symbolCoverage,
            docCoverage: queryPolicy.includeDocs ? 0.7 : 0.5,
            executionPathConfidence: 0.6
        )

        let subtrees = store.allSubtreeSummaries()
        let relevantSubtrees = subtrees.prefix(5).map { entry in
            RelevantSubtree(path: entry.root, whyRelevant: entry.summary, priority: 0.5)
        }
        let repoFrame = RepoFrame(
            oneSentenceIdentity: "A task management app built with SwiftUI.",
            relevantSubtrees: relevantSubtrees
        )

        // Build governing file infos for dossier
        let anchoredPaths = Set(anchorResult.exactEvidence.map(\.path))
        let governingFileInfos = governingFiles.map { gf -> GoverningFileInfo in
            let anchoredCount = anchorResult.exactEvidence.filter { $0.path == gf.path }.count
            return GoverningFileInfo(
                path: gf.path,
                governingType: gf.governingType.rawValue,
                priority: gf.priority,
                reason: gf.reason,
                anchored: anchoredCount > 0,
                anchoredSegments: anchoredCount
            )
        }

        // Compute specificity for planner metrics
        let specificityAnalyzer = QuerySpecificityAnalyzer()
        let specificity = specificityAnalyzer.analyze(queryIntent: queryIntent, queryLength: evalCase.query.count)

        let plannerMeta = PlannerMetadata(
            plannerRan: false,
            plannerSkipReason: "eval mode (no DeepSeek API)",
            specificityScore: specificity.score,
            rewrittenQuery: nil,
            validatedFileCount: 0, validatedDirCount: 0,
            validatedSymbolCount: 0, governingFileRequestCount: 0,
            invalidSuggestionCount: 0, dossierSubquestions: [],
            plannerCacheHit: false, plannerError: nil, plannerReason: nil
        )

        // Build file manifest for eval
        let evidencePathSet = Set(anchorResult.exactEvidence.map(\.path))
        let evalManifest = store.firstPartyFiles(limit: 500).map { file in
            RepoFileManifest(
                path: file.relativePath,
                fileType: file.fileType,
                lineCount: file.lineCount,
                summary: String(file.summary.prefix(120)),
                hasEvidence: evidencePathSet.contains(file.relativePath)
            )
        }

        let dossier = EvidenceDossier(
            queryIntent: queryIntent, queryPolicy: queryPolicy,
            repoFrame: repoFrame,
            implementationPath: anchorResult.implementationPath,
            mustReadFiles: mustRead,
            exactEvidence: anchorResult.exactEvidence,
            supportingContext: anchorResult.supportingContext,
            missingEvidence: [],
            coverageReport: coverageReport,
            droppedCandidates: [],
            confidenceReport: confidence,
            builderDiagnostics: diagnostics,
            governingFiles: governingFileInfos,
            plannerMetadata: plannerMeta,
            repoFileManifest: evalManifest
        )

        // Evaluate
        let evalResult = harness.evaluate(dossier: dossier, evalCase: evalCase)
        results.append(evalResult)

        // Print per-case anchor stats
        let stats = anchorResult.anchorStats
        let plannerWouldRun = specificity.shouldRunPlanner ? "YES" : "no"
        print("  Type: \(queryIntent.primary.rawValue) | Anchors: gov=\(stats.governingAnchors) sym=\(stats.symbolAnchors) content=\(stats.contentAnchors) ref=\(stats.referenceAnchors) doc=\(stats.docAnchors) test=\(stats.testAnchors) | Evidence: \(anchorResult.exactEvidence.count) | Links: \(links.count) | Governing: \(governingFiles.count) | Specificity: \(String(format: "%.2f", specificity.score)) planner=\(plannerWouldRun)")
    }

    // Print full report
    print("")
    let summary = harness.summarize(results: results)
    let report = harness.formatReport(summary: summary)
    print(report)

    // Cleanup
    try? FileManager.default.removeItem(atPath: tmpDir)
}

// MARK: - Helper (mirrors orchestrator's addOrUpdate)

func addOrUpdate(_ candidates: inout [String: PADACandidate], file: StoredFile, score: Double, provenance: EvidenceProvenance) {
    if var existing = candidates[file.relativePath] {
        existing.score += score
        existing.provenance.append(provenance)
        candidates[file.relativePath] = existing
    } else {
        candidates[file.relativePath] = PADACandidate(
            fileId: file.id,
            path: file.relativePath,
            score: score,
            provenance: [provenance],
            language: file.language,
            lineCount: file.lineCount,
            importance: file.importanceScore,
            tier: file.corpusTier,
            fileType: file.fileType,
            summary: file.summary,
            roleTags: file.roleTags
        )
    }
}

// Run
runEval()
