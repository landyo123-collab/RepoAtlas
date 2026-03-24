import Foundation
import SQLite3

// MARK: - Error types

enum MemoryStoreError: Error, LocalizedError {
    case cannotOpen(String)
    case queryFailed(String)
    case prepareFailed(String)

    var errorDescription: String? {
        switch self {
        case .cannotOpen(let path): return "Cannot open database at \(path)"
        case .queryFailed(let msg): return "Query failed: \(msg)"
        case .prepareFailed(let msg): return "Prepare failed: \(msg)"
        }
    }
}

// MARK: - Stored types

struct StoredFile {
    let id: Int64
    let relativePath: String
    let name: String
    let ext: String
    let fileType: String
    let roleTags: [String]
    let language: String
    let sizeBytes: Int
    let lineCount: Int
    let modifiedAt: Double
    let contentHash: String
    let importanceScore: Double
    let depth: Int
    let isIndexed: Bool
    let summary: String
    let corpusTier: String
    let projectRoot: String
}

struct StoredSegment {
    let id: Int64
    let fileId: Int64
    let segmentIndex: Int
    let startLine: Int
    let endLine: Int
    let tokenEstimate: Int
    let segmentType: String
    let label: String
    let content: String
    let filePath: String
}

struct StoredSymbol {
    let id: Int64
    let fileId: Int64
    let name: String
    let kind: String
    let lineNumber: Int
    let signature: String
    let container: String
    let filePath: String
}

struct StoredReference {
    let id: Int64
    let sourceFileId: Int64
    let targetPath: String
    let targetSymbol: String
    let kind: String
    let lineNumber: Int
    let sourceFilePath: String
}

struct RepoMeta {
    let rootPath: String
    let displayName: String
    let repoHash: String
    let fileCount: Int
    let indexedFileCount: Int
    let languageMix: [String: Int]
    let manifestList: [String]
    let topLevelDirs: [String]
    let runtimeShape: String
    let passport: String
    let indexedAt: Date
    let scanDurationMs: Int
    let indexVersion: Int
}

struct StoredSessionState {
    var recentQueries: [String]
    var recentFiles: [String]
    var activeTopic: String
    var activeSubsystem: String
    var updatedAt: Date
}

// MARK: - FTS match result

struct FTSMatch {
    let rowid: Int64
    let rank: Double
}

// MARK: - RepoMemoryStore

final class RepoMemoryStore {
    private var db: OpaquePointer?
    let dbPath: String

    static var memoryBaseDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("RepoAtlas").appendingPathComponent("Memory")
    }

    static func databaseDirectory(forRepoRoot root: String) -> URL {
        let hash = String(root.sha256Hex.prefix(16))
        return memoryBaseDirectory.appendingPathComponent(hash)
    }

    init(repoRoot: String) throws {
        let dir = Self.databaseDirectory(forRepoRoot: repoRoot)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.dbPath = dir.appendingPathComponent("repo_memory.sqlite3").path

        var dbHandle: OpaquePointer?
        guard sqlite3_open(dbPath, &dbHandle) == SQLITE_OK else {
            let msg = dbHandle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw MemoryStoreError.cannotOpen("\(dbPath): \(msg)")
        }
        self.db = dbHandle

        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA foreign_keys=ON")
        try execute("PRAGMA synchronous=NORMAL")
        migrateSchema()   // Must run before createSchema so new columns exist before new indexes
        try createSchema()
    }

    deinit {
        if let db = db {
            sqlite3_close(db)
        }
    }

    // MARK: - Schema

    private func createSchema() throws {
        let schema = """
        CREATE TABLE IF NOT EXISTS repo_meta (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            root_path TEXT NOT NULL,
            display_name TEXT NOT NULL,
            repo_hash TEXT NOT NULL,
            file_count INTEGER DEFAULT 0,
            indexed_file_count INTEGER DEFAULT 0,
            language_mix TEXT DEFAULT '{}',
            manifest_list TEXT DEFAULT '[]',
            top_level_dirs TEXT DEFAULT '[]',
            runtime_shape TEXT DEFAULT '',
            passport TEXT DEFAULT '',
            indexed_at REAL NOT NULL,
            scan_duration_ms INTEGER DEFAULT 0,
            index_version INTEGER DEFAULT 1
        );

        CREATE TABLE IF NOT EXISTS files (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            relative_path TEXT NOT NULL UNIQUE,
            name TEXT NOT NULL,
            extension TEXT DEFAULT '',
            file_type TEXT NOT NULL DEFAULT 'source',
            role_tags TEXT DEFAULT '[]',
            language TEXT DEFAULT '',
            size_bytes INTEGER DEFAULT 0,
            line_count INTEGER DEFAULT 0,
            modified_at REAL DEFAULT 0,
            content_hash TEXT DEFAULT '',
            importance_score REAL DEFAULT 0,
            depth INTEGER DEFAULT 0,
            is_indexed INTEGER DEFAULT 0,
            summary TEXT DEFAULT '',
            corpus_tier TEXT DEFAULT 'firstParty',
            project_root TEXT DEFAULT ''
        );

        CREATE TABLE IF NOT EXISTS segments (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
            segment_index INTEGER NOT NULL,
            start_line INTEGER NOT NULL,
            end_line INTEGER NOT NULL,
            token_estimate INTEGER DEFAULT 0,
            segment_type TEXT DEFAULT 'chunk',
            label TEXT DEFAULT '',
            content TEXT NOT NULL,
            UNIQUE(file_id, segment_index)
        );

        CREATE TABLE IF NOT EXISTS symbols (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
            name TEXT NOT NULL,
            kind TEXT NOT NULL,
            line_number INTEGER DEFAULT 0,
            signature TEXT DEFAULT '',
            container TEXT DEFAULT ''
        );

        CREATE TABLE IF NOT EXISTS refs (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            source_file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
            target_path TEXT DEFAULT '',
            target_symbol TEXT NOT NULL,
            kind TEXT NOT NULL,
            line_number INTEGER DEFAULT 0
        );

        CREATE TABLE IF NOT EXISTS dir_summaries (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            directory_path TEXT NOT NULL UNIQUE,
            summary_text TEXT NOT NULL,
            file_count INTEGER DEFAULT 0,
            dominant_language TEXT DEFAULT ''
        );

        CREATE TABLE IF NOT EXISTS session_state (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            recent_queries TEXT DEFAULT '[]',
            recent_files TEXT DEFAULT '[]',
            active_topic TEXT DEFAULT '',
            active_subsystem TEXT DEFAULT '',
            updated_at REAL NOT NULL
        );

        CREATE TABLE IF NOT EXISTS retrieval_log (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            query TEXT NOT NULL,
            retrieved_files TEXT NOT NULL,
            seed_signals TEXT DEFAULT '',
            total_tokens INTEGER DEFAULT 0,
            timestamp REAL NOT NULL
        );

        CREATE VIRTUAL TABLE IF NOT EXISTS files_fts USING fts5(
            relative_path, name, role_tags, summary
        );

        CREATE VIRTUAL TABLE IF NOT EXISTS segments_fts USING fts5(
            content, label, file_path
        );

        CREATE VIRTUAL TABLE IF NOT EXISTS symbols_fts USING fts5(
            name, signature, file_path
        );

        CREATE INDEX IF NOT EXISTS idx_files_type ON files(file_type);
        CREATE INDEX IF NOT EXISTS idx_files_language ON files(language);
        CREATE INDEX IF NOT EXISTS idx_files_importance ON files(importance_score DESC);
        CREATE INDEX IF NOT EXISTS idx_files_tier ON files(corpus_tier);
        CREATE INDEX IF NOT EXISTS idx_files_project_root ON files(project_root);
        CREATE INDEX IF NOT EXISTS idx_segments_file ON segments(file_id);
        CREATE INDEX IF NOT EXISTS idx_symbols_file ON symbols(file_id);
        CREATE INDEX IF NOT EXISTS idx_symbols_name ON symbols(name);
        CREATE TABLE IF NOT EXISTS embeddings (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            target_type TEXT NOT NULL,
            target_id INTEGER NOT NULL,
            content_hash TEXT NOT NULL,
            model TEXT NOT NULL,
            dimension INTEGER NOT NULL,
            vector BLOB NOT NULL,
            created_at REAL NOT NULL,
            UNIQUE(target_type, target_id)
        );

        CREATE TABLE IF NOT EXISTS subtree_summaries (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            subtree_root TEXT NOT NULL UNIQUE,
            summary_text TEXT NOT NULL,
            file_count INTEGER DEFAULT 0,
            first_party_count INTEGER DEFAULT 0,
            language_mix TEXT DEFAULT '{}',
            manifest_paths TEXT DEFAULT '[]'
        );

        CREATE INDEX IF NOT EXISTS idx_refs_source ON refs(source_file_id);
        CREATE INDEX IF NOT EXISTS idx_refs_target ON refs(target_path);
        CREATE INDEX IF NOT EXISTS idx_refs_symbol ON refs(target_symbol);
        CREATE INDEX IF NOT EXISTS idx_embeddings_target ON embeddings(target_type, target_id);
        """
        try execute(schema)
    }

    /// Add columns/tables that may not exist in older databases.
    private func migrateSchema() {
        _ = try? execute("ALTER TABLE files ADD COLUMN corpus_tier TEXT DEFAULT 'firstParty'")
        _ = try? execute("ALTER TABLE files ADD COLUMN project_root TEXT DEFAULT ''")
        // Embeddings and subtree tables are created via CREATE TABLE IF NOT EXISTS in createSchema
    }

    // MARK: - Execute helpers

    @discardableResult
    func execute(_ sql: String) throws -> Int {
        var errMsg: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &errMsg) == SQLITE_OK else {
            let msg = errMsg.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errMsg)
            throw MemoryStoreError.queryFailed(msg)
        }
        return Int(sqlite3_changes(db))
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw MemoryStoreError.prepareFailed("\(msg) | SQL: \(sql.prefix(200))")
        }
        return s
    }

    private func lastInsertId() -> Int64 {
        sqlite3_last_insert_rowid(db)
    }

    // MARK: - Transaction helpers

    func inTransaction(_ work: () throws -> Void) throws {
        try execute("BEGIN TRANSACTION")
        do {
            try work()
            try execute("COMMIT")
        } catch {
            _ = try? execute("ROLLBACK")
            throw error
        }
    }

    // MARK: - Clear all data

    func clearAll() throws {
        try execute("DELETE FROM retrieval_log")
        try execute("DELETE FROM session_state")
        try execute("DELETE FROM dir_summaries")
        try execute("DELETE FROM subtree_summaries")
        try execute("DELETE FROM embeddings")
        try execute("DELETE FROM refs")
        try execute("DELETE FROM symbols")
        try execute("DELETE FROM segments")
        try execute("DELETE FROM files")
        try execute("DELETE FROM repo_meta")
        try execute("DELETE FROM files_fts")
        try execute("DELETE FROM segments_fts")
        try execute("DELETE FROM symbols_fts")
    }

    // MARK: - Repo Meta

    func upsertRepoMeta(_ meta: RepoMeta) throws {
        let sql = """
        INSERT OR REPLACE INTO repo_meta (id, root_path, display_name, repo_hash, file_count,
            indexed_file_count, language_mix, manifest_list, top_level_dirs, runtime_shape,
            passport, indexed_at, scan_duration_ms, index_version)
        VALUES (1, ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (meta.rootPath as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (meta.displayName as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 3, (meta.repoHash as NSString).utf8String, -1, nil)
        sqlite3_bind_int(stmt, 4, Int32(meta.fileCount))
        sqlite3_bind_int(stmt, 5, Int32(meta.indexedFileCount))
        let langJSON = (try? JSONSerialization.data(withJSONObject: meta.languageMix)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        sqlite3_bind_text(stmt, 6, (langJSON as NSString).utf8String, -1, nil)
        let manifestJSON = (try? JSONSerialization.data(withJSONObject: meta.manifestList)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        sqlite3_bind_text(stmt, 7, (manifestJSON as NSString).utf8String, -1, nil)
        let dirsJSON = (try? JSONSerialization.data(withJSONObject: meta.topLevelDirs)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        sqlite3_bind_text(stmt, 8, (dirsJSON as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 9, (meta.runtimeShape as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 10, (meta.passport as NSString).utf8String, -1, nil)
        sqlite3_bind_double(stmt, 11, meta.indexedAt.timeIntervalSince1970)
        sqlite3_bind_int(stmt, 12, Int32(meta.scanDurationMs))
        sqlite3_bind_int(stmt, 13, Int32(meta.indexVersion))
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw MemoryStoreError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    func repoMeta() -> RepoMeta? {
        guard let stmt = try? prepare("SELECT root_path, display_name, repo_hash, file_count, indexed_file_count, language_mix, manifest_list, top_level_dirs, runtime_shape, passport, indexed_at, scan_duration_ms, index_version FROM repo_meta WHERE id=1") else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }

        let langStr = String(cString: sqlite3_column_text(stmt, 5))
        let langMix = (try? JSONSerialization.jsonObject(with: Data(langStr.utf8))) as? [String: Int] ?? [:]
        let manifestStr = String(cString: sqlite3_column_text(stmt, 6))
        let manifests = (try? JSONSerialization.jsonObject(with: Data(manifestStr.utf8))) as? [String] ?? []
        let dirsStr = String(cString: sqlite3_column_text(stmt, 7))
        let dirs = (try? JSONSerialization.jsonObject(with: Data(dirsStr.utf8))) as? [String] ?? []

        return RepoMeta(
            rootPath: String(cString: sqlite3_column_text(stmt, 0)),
            displayName: String(cString: sqlite3_column_text(stmt, 1)),
            repoHash: String(cString: sqlite3_column_text(stmt, 2)),
            fileCount: Int(sqlite3_column_int(stmt, 3)),
            indexedFileCount: Int(sqlite3_column_int(stmt, 4)),
            languageMix: langMix,
            manifestList: manifests,
            topLevelDirs: dirs,
            runtimeShape: String(cString: sqlite3_column_text(stmt, 8)),
            passport: String(cString: sqlite3_column_text(stmt, 9)),
            indexedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 10)),
            scanDurationMs: Int(sqlite3_column_int(stmt, 11)),
            indexVersion: Int(sqlite3_column_int(stmt, 12))
        )
    }

    // MARK: - Files

    @discardableResult
    func insertFile(relativePath: String, name: String, ext: String, fileType: String,
                    roleTags: [String], language: String, sizeBytes: Int, lineCount: Int,
                    modifiedAt: Double, contentHash: String, importanceScore: Double,
                    depth: Int, isIndexed: Bool, summary: String,
                    corpusTier: String = "firstParty", projectRoot: String = "") throws -> Int64 {
        let sql = """
        INSERT INTO files (relative_path, name, extension, file_type, role_tags, language,
            size_bytes, line_count, modified_at, content_hash, importance_score, depth, is_indexed, summary,
            corpus_tier, project_root)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16)
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (relativePath as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (name as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 3, (ext as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 4, (fileType as NSString).utf8String, -1, nil)
        let tagsJSON = (try? JSONSerialization.data(withJSONObject: roleTags)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        sqlite3_bind_text(stmt, 5, (tagsJSON as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 6, (language as NSString).utf8String, -1, nil)
        sqlite3_bind_int(stmt, 7, Int32(sizeBytes))
        sqlite3_bind_int(stmt, 8, Int32(lineCount))
        sqlite3_bind_double(stmt, 9, modifiedAt)
        sqlite3_bind_text(stmt, 10, (contentHash as NSString).utf8String, -1, nil)
        sqlite3_bind_double(stmt, 11, importanceScore)
        sqlite3_bind_int(stmt, 12, Int32(depth))
        sqlite3_bind_int(stmt, 13, isIndexed ? 1 : 0)
        sqlite3_bind_text(stmt, 14, (summary as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 15, (corpusTier as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 16, (projectRoot as NSString).utf8String, -1, nil)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw MemoryStoreError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        let fileId = lastInsertId()

        // Insert into FTS
        let fts = try prepare("INSERT INTO files_fts (rowid, relative_path, name, role_tags, summary) VALUES (?1, ?2, ?3, ?4, ?5)")
        defer { sqlite3_finalize(fts) }
        sqlite3_bind_int64(fts, 1, fileId)
        sqlite3_bind_text(fts, 2, (relativePath as NSString).utf8String, -1, nil)
        sqlite3_bind_text(fts, 3, (name as NSString).utf8String, -1, nil)
        sqlite3_bind_text(fts, 4, (tagsJSON as NSString).utf8String, -1, nil)
        sqlite3_bind_text(fts, 5, (summary as NSString).utf8String, -1, nil)
        sqlite3_step(fts)

        return fileId
    }

    func fileId(forPath relativePath: String) -> Int64? {
        guard let stmt = try? prepare("SELECT id FROM files WHERE relative_path = ?1") else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (relativePath as NSString).utf8String, -1, nil)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(stmt, 0)
    }

    func file(byId id: Int64) -> StoredFile? {
        guard let stmt = try? prepare("SELECT id, relative_path, name, extension, file_type, role_tags, language, size_bytes, line_count, modified_at, content_hash, importance_score, depth, is_indexed, summary, corpus_tier, project_root FROM files WHERE id = ?1") else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, id)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return readFileRow(stmt)
    }

    func file(byPath relativePath: String) -> StoredFile? {
        guard let stmt = try? prepare("SELECT id, relative_path, name, extension, file_type, role_tags, language, size_bytes, line_count, modified_at, content_hash, importance_score, depth, is_indexed, summary, corpus_tier, project_root FROM files WHERE relative_path = ?1") else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (relativePath as NSString).utf8String, -1, nil)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return readFileRow(stmt)
    }

    func allFiles() -> [StoredFile] {
        guard let stmt = try? prepare("SELECT id, relative_path, name, extension, file_type, role_tags, language, size_bytes, line_count, modified_at, content_hash, importance_score, depth, is_indexed, summary, corpus_tier, project_root FROM files ORDER BY importance_score DESC") else { return [] }
        defer { sqlite3_finalize(stmt) }
        var results: [StoredFile] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append(readFileRow(stmt))
        }
        return results
    }

    func filesByType(_ fileType: String) -> [StoredFile] {
        guard let stmt = try? prepare("SELECT id, relative_path, name, extension, file_type, role_tags, language, size_bytes, line_count, modified_at, content_hash, importance_score, depth, is_indexed, summary, corpus_tier, project_root FROM files WHERE file_type = ?1 ORDER BY importance_score DESC") else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (fileType as NSString).utf8String, -1, nil)
        var results: [StoredFile] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append(readFileRow(stmt))
        }
        return results
    }

    func topFiles(limit: Int) -> [StoredFile] {
        guard let stmt = try? prepare("SELECT id, relative_path, name, extension, file_type, role_tags, language, size_bytes, line_count, modified_at, content_hash, importance_score, depth, is_indexed, summary, corpus_tier, project_root FROM files ORDER BY importance_score DESC LIMIT ?1") else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(limit))
        var results: [StoredFile] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append(readFileRow(stmt))
        }
        return results
    }

    private func readFileRow(_ stmt: OpaquePointer) -> StoredFile {
        let tagsStr = String(cString: sqlite3_column_text(stmt, 5))
        let tags = (try? JSONSerialization.jsonObject(with: Data(tagsStr.utf8))) as? [String] ?? []
        let tierPtr = sqlite3_column_text(stmt, 15)
        let projPtr = sqlite3_column_text(stmt, 16)
        return StoredFile(
            id: sqlite3_column_int64(stmt, 0),
            relativePath: String(cString: sqlite3_column_text(stmt, 1)),
            name: String(cString: sqlite3_column_text(stmt, 2)),
            ext: String(cString: sqlite3_column_text(stmt, 3)),
            fileType: String(cString: sqlite3_column_text(stmt, 4)),
            roleTags: tags,
            language: String(cString: sqlite3_column_text(stmt, 6)),
            sizeBytes: Int(sqlite3_column_int(stmt, 7)),
            lineCount: Int(sqlite3_column_int(stmt, 8)),
            modifiedAt: sqlite3_column_double(stmt, 9),
            contentHash: String(cString: sqlite3_column_text(stmt, 10)),
            importanceScore: sqlite3_column_double(stmt, 11),
            depth: Int(sqlite3_column_int(stmt, 12)),
            isIndexed: sqlite3_column_int(stmt, 13) != 0,
            summary: String(cString: sqlite3_column_text(stmt, 14)),
            corpusTier: tierPtr.map { String(cString: $0) } ?? "firstParty",
            projectRoot: projPtr.map { String(cString: $0) } ?? ""
        )
    }

    // MARK: - Segments

    @discardableResult
    func insertSegment(fileId: Int64, segmentIndex: Int, startLine: Int, endLine: Int,
                       tokenEstimate: Int, segmentType: String, label: String,
                       content: String, filePath: String) throws -> Int64 {
        let sql = """
        INSERT INTO segments (file_id, segment_index, start_line, end_line, token_estimate,
            segment_type, label, content)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, fileId)
        sqlite3_bind_int(stmt, 2, Int32(segmentIndex))
        sqlite3_bind_int(stmt, 3, Int32(startLine))
        sqlite3_bind_int(stmt, 4, Int32(endLine))
        sqlite3_bind_int(stmt, 5, Int32(tokenEstimate))
        sqlite3_bind_text(stmt, 6, (segmentType as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 7, (label as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 8, (content as NSString).utf8String, -1, nil)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw MemoryStoreError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        let segId = lastInsertId()

        let fts = try prepare("INSERT INTO segments_fts (rowid, content, label, file_path) VALUES (?1, ?2, ?3, ?4)")
        defer { sqlite3_finalize(fts) }
        sqlite3_bind_int64(fts, 1, segId)
        sqlite3_bind_text(fts, 2, (content as NSString).utf8String, -1, nil)
        sqlite3_bind_text(fts, 3, (label as NSString).utf8String, -1, nil)
        sqlite3_bind_text(fts, 4, (filePath as NSString).utf8String, -1, nil)
        sqlite3_step(fts)

        return segId
    }

    func segments(forFileId fileId: Int64) -> [StoredSegment] {
        guard let stmt = try? prepare("""
            SELECT s.id, s.file_id, s.segment_index, s.start_line, s.end_line, s.token_estimate,
                   s.segment_type, s.label, s.content, f.relative_path
            FROM segments s JOIN files f ON s.file_id = f.id
            WHERE s.file_id = ?1 ORDER BY s.segment_index
        """) else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, fileId)
        var results: [StoredSegment] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append(readSegmentRow(stmt))
        }
        return results
    }

    func segment(byId id: Int64) -> StoredSegment? {
        guard let stmt = try? prepare("""
            SELECT s.id, s.file_id, s.segment_index, s.start_line, s.end_line, s.token_estimate,
                   s.segment_type, s.label, s.content, f.relative_path
            FROM segments s JOIN files f ON s.file_id = f.id WHERE s.id = ?1
        """) else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, id)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return readSegmentRow(stmt)
    }

    private func readSegmentRow(_ stmt: OpaquePointer) -> StoredSegment {
        StoredSegment(
            id: sqlite3_column_int64(stmt, 0),
            fileId: sqlite3_column_int64(stmt, 1),
            segmentIndex: Int(sqlite3_column_int(stmt, 2)),
            startLine: Int(sqlite3_column_int(stmt, 3)),
            endLine: Int(sqlite3_column_int(stmt, 4)),
            tokenEstimate: Int(sqlite3_column_int(stmt, 5)),
            segmentType: String(cString: sqlite3_column_text(stmt, 6)),
            label: String(cString: sqlite3_column_text(stmt, 7)),
            content: String(cString: sqlite3_column_text(stmt, 8)),
            filePath: String(cString: sqlite3_column_text(stmt, 9))
        )
    }

    // MARK: - Symbols

    @discardableResult
    func insertSymbol(fileId: Int64, name: String, kind: String, lineNumber: Int,
                      signature: String, container: String, filePath: String) throws -> Int64 {
        let sql = "INSERT INTO symbols (file_id, name, kind, line_number, signature, container) VALUES (?1, ?2, ?3, ?4, ?5, ?6)"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, fileId)
        sqlite3_bind_text(stmt, 2, (name as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 3, (kind as NSString).utf8String, -1, nil)
        sqlite3_bind_int(stmt, 4, Int32(lineNumber))
        sqlite3_bind_text(stmt, 5, (signature as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 6, (container as NSString).utf8String, -1, nil)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw MemoryStoreError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        let symId = lastInsertId()

        let fts = try prepare("INSERT INTO symbols_fts (rowid, name, signature, file_path) VALUES (?1, ?2, ?3, ?4)")
        defer { sqlite3_finalize(fts) }
        sqlite3_bind_int64(fts, 1, symId)
        sqlite3_bind_text(fts, 2, (name as NSString).utf8String, -1, nil)
        sqlite3_bind_text(fts, 3, (signature as NSString).utf8String, -1, nil)
        sqlite3_bind_text(fts, 4, (filePath as NSString).utf8String, -1, nil)
        sqlite3_step(fts)

        return symId
    }

    func symbols(forFileId fileId: Int64) -> [StoredSymbol] {
        guard let stmt = try? prepare("""
            SELECT sy.id, sy.file_id, sy.name, sy.kind, sy.line_number, sy.signature, sy.container, f.relative_path
            FROM symbols sy JOIN files f ON sy.file_id = f.id WHERE sy.file_id = ?1 ORDER BY sy.line_number
        """) else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, fileId)
        var results: [StoredSymbol] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append(readSymbolRow(stmt))
        }
        return results
    }

    private func readSymbolRow(_ stmt: OpaquePointer) -> StoredSymbol {
        StoredSymbol(
            id: sqlite3_column_int64(stmt, 0),
            fileId: sqlite3_column_int64(stmt, 1),
            name: String(cString: sqlite3_column_text(stmt, 2)),
            kind: String(cString: sqlite3_column_text(stmt, 3)),
            lineNumber: Int(sqlite3_column_int(stmt, 4)),
            signature: String(cString: sqlite3_column_text(stmt, 5)),
            container: String(cString: sqlite3_column_text(stmt, 6)),
            filePath: String(cString: sqlite3_column_text(stmt, 7))
        )
    }

    // MARK: - References

    @discardableResult
    func insertReference(sourceFileId: Int64, targetPath: String, targetSymbol: String,
                         kind: String, lineNumber: Int) throws -> Int64 {
        let sql = "INSERT INTO refs (source_file_id, target_path, target_symbol, kind, line_number) VALUES (?1, ?2, ?3, ?4, ?5)"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, sourceFileId)
        sqlite3_bind_text(stmt, 2, (targetPath as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 3, (targetSymbol as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 4, (kind as NSString).utf8String, -1, nil)
        sqlite3_bind_int(stmt, 5, Int32(lineNumber))
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw MemoryStoreError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        return lastInsertId()
    }

    func referencesFrom(fileId: Int64) -> [StoredReference] {
        guard let stmt = try? prepare("""
            SELECT r.id, r.source_file_id, r.target_path, r.target_symbol, r.kind, r.line_number, f.relative_path
            FROM refs r JOIN files f ON r.source_file_id = f.id WHERE r.source_file_id = ?1
        """) else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, fileId)
        var results: [StoredReference] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append(readRefRow(stmt))
        }
        return results
    }

    func referencesTo(path: String) -> [StoredReference] {
        guard let stmt = try? prepare("""
            SELECT r.id, r.source_file_id, r.target_path, r.target_symbol, r.kind, r.line_number, f.relative_path
            FROM refs r JOIN files f ON r.source_file_id = f.id WHERE r.target_path = ?1
        """) else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (path as NSString).utf8String, -1, nil)
        var results: [StoredReference] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append(readRefRow(stmt))
        }
        return results
    }

    func referencesToSymbol(name: String) -> [StoredReference] {
        guard let stmt = try? prepare("""
            SELECT r.id, r.source_file_id, r.target_path, r.target_symbol, r.kind, r.line_number, f.relative_path
            FROM refs r JOIN files f ON r.source_file_id = f.id WHERE r.target_symbol = ?1
        """) else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (name as NSString).utf8String, -1, nil)
        var results: [StoredReference] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append(readRefRow(stmt))
        }
        return results
    }

    private func readRefRow(_ stmt: OpaquePointer) -> StoredReference {
        StoredReference(
            id: sqlite3_column_int64(stmt, 0),
            sourceFileId: sqlite3_column_int64(stmt, 1),
            targetPath: String(cString: sqlite3_column_text(stmt, 2)),
            targetSymbol: String(cString: sqlite3_column_text(stmt, 3)),
            kind: String(cString: sqlite3_column_text(stmt, 4)),
            lineNumber: Int(sqlite3_column_int(stmt, 5)),
            sourceFilePath: String(cString: sqlite3_column_text(stmt, 6))
        )
    }

    // MARK: - Directory summaries

    func upsertDirSummary(path: String, summary: String, fileCount: Int, dominantLanguage: String) throws {
        let sql = "INSERT OR REPLACE INTO dir_summaries (directory_path, summary_text, file_count, dominant_language) VALUES (?1, ?2, ?3, ?4)"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (path as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (summary as NSString).utf8String, -1, nil)
        sqlite3_bind_int(stmt, 3, Int32(fileCount))
        sqlite3_bind_text(stmt, 4, (dominantLanguage as NSString).utf8String, -1, nil)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw MemoryStoreError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    func dirSummary(forPath path: String) -> String? {
        guard let stmt = try? prepare("SELECT summary_text FROM dir_summaries WHERE directory_path = ?1") else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (path as NSString).utf8String, -1, nil)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return String(cString: sqlite3_column_text(stmt, 0))
    }

    func allDirSummaries() -> [(path: String, summary: String)] {
        guard let stmt = try? prepare("SELECT directory_path, summary_text FROM dir_summaries ORDER BY directory_path") else { return [] }
        defer { sqlite3_finalize(stmt) }
        var results: [(String, String)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append((String(cString: sqlite3_column_text(stmt, 0)), String(cString: sqlite3_column_text(stmt, 1))))
        }
        return results
    }

    // MARK: - Session State

    func loadSession() -> StoredSessionState {
        guard let stmt = try? prepare("SELECT recent_queries, recent_files, active_topic, active_subsystem, updated_at FROM session_state WHERE id = 1") else {
            return StoredSessionState(recentQueries: [], recentFiles: [], activeTopic: "", activeSubsystem: "", updatedAt: Date())
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            return StoredSessionState(recentQueries: [], recentFiles: [], activeTopic: "", activeSubsystem: "", updatedAt: Date())
        }
        let qStr = String(cString: sqlite3_column_text(stmt, 0))
        let fStr = String(cString: sqlite3_column_text(stmt, 1))
        let queries = (try? JSONSerialization.jsonObject(with: Data(qStr.utf8))) as? [String] ?? []
        let files = (try? JSONSerialization.jsonObject(with: Data(fStr.utf8))) as? [String] ?? []
        return StoredSessionState(
            recentQueries: queries,
            recentFiles: files,
            activeTopic: String(cString: sqlite3_column_text(stmt, 2)),
            activeSubsystem: String(cString: sqlite3_column_text(stmt, 3)),
            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4))
        )
    }

    func saveSession(_ session: StoredSessionState) throws {
        let qJSON = (try? JSONSerialization.data(withJSONObject: session.recentQueries)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let fJSON = (try? JSONSerialization.data(withJSONObject: session.recentFiles)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let sql = "INSERT OR REPLACE INTO session_state (id, recent_queries, recent_files, active_topic, active_subsystem, updated_at) VALUES (1, ?1, ?2, ?3, ?4, ?5)"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (qJSON as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (fJSON as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 3, (session.activeTopic as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 4, (session.activeSubsystem as NSString).utf8String, -1, nil)
        sqlite3_bind_double(stmt, 5, session.updatedAt.timeIntervalSince1970)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw MemoryStoreError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    // MARK: - Retrieval log

    func logRetrieval(query: String, retrievedFiles: [String], seedSignals: String, totalTokens: Int) throws {
        let filesJSON = (try? JSONSerialization.data(withJSONObject: retrievedFiles)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let sql = "INSERT INTO retrieval_log (query, retrieved_files, seed_signals, total_tokens, timestamp) VALUES (?1, ?2, ?3, ?4, ?5)"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (query as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (filesJSON as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 3, (seedSignals as NSString).utf8String, -1, nil)
        sqlite3_bind_int(stmt, 4, Int32(totalTokens))
        sqlite3_bind_double(stmt, 5, Date().timeIntervalSince1970)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw MemoryStoreError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    // MARK: - FTS Queries

    func searchFiles(query: String, limit: Int = 30) -> [FTSMatch] {
        let escaped = ftsEscape(query)
        guard !escaped.isEmpty else { return [] }
        guard let stmt = try? prepare("SELECT rowid, rank FROM files_fts WHERE files_fts MATCH ?1 ORDER BY rank LIMIT ?2") else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (escaped as NSString).utf8String, -1, nil)
        sqlite3_bind_int(stmt, 2, Int32(limit))
        var results: [FTSMatch] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append(FTSMatch(rowid: sqlite3_column_int64(stmt, 0), rank: sqlite3_column_double(stmt, 1)))
        }
        return results
    }

    func searchSegments(query: String, limit: Int = 50) -> [FTSMatch] {
        let escaped = ftsEscape(query)
        guard !escaped.isEmpty else { return [] }
        guard let stmt = try? prepare("SELECT rowid, rank FROM segments_fts WHERE segments_fts MATCH ?1 ORDER BY rank LIMIT ?2") else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (escaped as NSString).utf8String, -1, nil)
        sqlite3_bind_int(stmt, 2, Int32(limit))
        var results: [FTSMatch] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append(FTSMatch(rowid: sqlite3_column_int64(stmt, 0), rank: sqlite3_column_double(stmt, 1)))
        }
        return results
    }

    func searchSymbols(query: String, limit: Int = 30) -> [FTSMatch] {
        let escaped = ftsEscape(query)
        guard !escaped.isEmpty else { return [] }
        guard let stmt = try? prepare("SELECT rowid, rank FROM symbols_fts WHERE symbols_fts MATCH ?1 ORDER BY rank LIMIT ?2") else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (escaped as NSString).utf8String, -1, nil)
        sqlite3_bind_int(stmt, 2, Int32(limit))
        var results: [FTSMatch] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append(FTSMatch(rowid: sqlite3_column_int64(stmt, 0), rank: sqlite3_column_double(stmt, 1)))
        }
        return results
    }

    /// FTS5 query escaping: wrap each term in quotes to treat as literal
    private func ftsEscape(_ raw: String) -> String {
        let terms = raw.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" && $0 != "." })
            .map(String.init)
            .filter { $0.count > 1 }
        guard !terms.isEmpty else { return "" }
        return terms.map { "\"\($0)\"" }.joined(separator: " OR ")
    }

    // MARK: - Neighbor queries for graph expansion

    func filesImporting(fileId: Int64) -> [Int64] {
        guard let stmt = try? prepare("""
            SELECT DISTINCT r.source_file_id FROM refs r
            WHERE r.target_path = (SELECT relative_path FROM files WHERE id = ?1)
            AND r.source_file_id != ?1
        """) else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, fileId)
        var ids: [Int64] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            ids.append(sqlite3_column_int64(stmt, 0))
        }
        return ids
    }

    func filesImportedBy(fileId: Int64) -> [Int64] {
        guard let stmt = try? prepare("""
            SELECT DISTINCT f.id FROM files f
            JOIN refs r ON r.target_path = f.relative_path
            WHERE r.source_file_id = ?1 AND f.id != ?1
        """) else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, fileId)
        var ids: [Int64] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            ids.append(sqlite3_column_int64(stmt, 0))
        }
        return ids
    }

    func filesInSameDirectory(fileId: Int64, limit: Int = 10) -> [Int64] {
        guard let file = file(byId: fileId) else { return [] }
        let dir = (file.relativePath as NSString).deletingLastPathComponent
        let pattern = dir.isEmpty ? "%" : dir + "/%"
        guard let stmt = try? prepare("""
            SELECT id FROM files WHERE relative_path LIKE ?1
            AND id != ?2 AND relative_path NOT LIKE ?3
            ORDER BY importance_score DESC LIMIT ?4
        """) else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (pattern as NSString).utf8String, -1, nil)
        sqlite3_bind_int64(stmt, 2, fileId)
        let deepPattern = dir.isEmpty ? "%/%" : dir + "/%/%"
        sqlite3_bind_text(stmt, 3, (deepPattern as NSString).utf8String, -1, nil)
        sqlite3_bind_int(stmt, 4, Int32(limit))
        var ids: [Int64] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            ids.append(sqlite3_column_int64(stmt, 0))
        }
        return ids
    }

    // MARK: - Symbol file lookup (for FTS rowid -> file_id)

    func fileIdForSymbol(symbolId: Int64) -> Int64? {
        guard let stmt = try? prepare("SELECT file_id FROM symbols WHERE id = ?1") else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, symbolId)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(stmt, 0)
    }

    // MARK: - Tier-aware queries

    func filesByTier(_ tier: String) -> [StoredFile] {
        guard let stmt = try? prepare("SELECT id, relative_path, name, extension, file_type, role_tags, language, size_bytes, line_count, modified_at, content_hash, importance_score, depth, is_indexed, summary, corpus_tier, project_root FROM files WHERE corpus_tier = ?1 ORDER BY importance_score DESC") else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (tier as NSString).utf8String, -1, nil)
        var results: [StoredFile] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append(readFileRow(stmt))
        }
        return results
    }

    func firstPartyFiles(limit: Int = 100) -> [StoredFile] {
        guard let stmt = try? prepare("SELECT id, relative_path, name, extension, file_type, role_tags, language, size_bytes, line_count, modified_at, content_hash, importance_score, depth, is_indexed, summary, corpus_tier, project_root FROM files WHERE corpus_tier IN ('firstParty', 'projectSupport') ORDER BY importance_score DESC LIMIT ?1") else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(limit))
        var results: [StoredFile] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append(readFileRow(stmt))
        }
        return results
    }

    func tierForFile(fileId: Int64) -> String {
        guard let stmt = try? prepare("SELECT corpus_tier FROM files WHERE id = ?1") else { return "firstParty" }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, fileId)
        guard sqlite3_step(stmt) == SQLITE_ROW,
              let ptr = sqlite3_column_text(stmt, 0) else { return "firstParty" }
        return String(cString: ptr)
    }

    func projectRootForFile(fileId: Int64) -> String {
        guard let stmt = try? prepare("SELECT project_root FROM files WHERE id = ?1") else { return "" }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, fileId)
        guard sqlite3_step(stmt) == SQLITE_ROW,
              let ptr = sqlite3_column_text(stmt, 0) else { return "" }
        return String(cString: ptr)
    }

    func tierCounts() -> [String: Int] {
        guard let stmt = try? prepare("SELECT corpus_tier, COUNT(*) FROM files GROUP BY corpus_tier") else { return [:] }
        defer { sqlite3_finalize(stmt) }
        var counts: [String: Int] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let tier = String(cString: sqlite3_column_text(stmt, 0))
            counts[tier] = Int(sqlite3_column_int(stmt, 1))
        }
        return counts
    }

    // MARK: - File count

    func totalFileCount() -> Int {
        guard let stmt = try? prepare("SELECT COUNT(*) FROM files") else { return 0 }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }

    func indexedFileCount() -> Int {
        guard let stmt = try? prepare("SELECT COUNT(*) FROM files WHERE is_indexed = 1") else { return 0 }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }

    // MARK: - Embeddings

    /// Store an embedding vector for a target (file summary, segment, etc.)
    func upsertEmbedding(targetType: String, targetId: Int64, contentHash: String,
                          model: String, vector: [Float]) throws {
        let sql = """
        INSERT OR REPLACE INTO embeddings (target_type, target_id, content_hash, model, dimension, vector, created_at)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (targetType as NSString).utf8String, -1, nil)
        sqlite3_bind_int64(stmt, 2, targetId)
        sqlite3_bind_text(stmt, 3, (contentHash as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 4, (model as NSString).utf8String, -1, nil)
        sqlite3_bind_int(stmt, 5, Int32(vector.count))
        // Store as raw Float bytes
        let data = vector.withUnsafeBufferPointer { Data(buffer: $0) }
        _ = data.withUnsafeBytes { ptr in
            sqlite3_bind_blob(stmt, 6, ptr.baseAddress, Int32(data.count), nil)
        }
        sqlite3_bind_double(stmt, 7, Date().timeIntervalSince1970)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw MemoryStoreError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    /// Retrieve an embedding for a target, or nil if not present or stale.
    func embedding(targetType: String, targetId: Int64, contentHash: String? = nil) -> EmbeddingVector? {
        var sql = "SELECT vector, dimension, model FROM embeddings WHERE target_type = ?1 AND target_id = ?2"
        if contentHash != nil { sql += " AND content_hash = ?3" }
        guard let stmt = try? prepare(sql) else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (targetType as NSString).utf8String, -1, nil)
        sqlite3_bind_int64(stmt, 2, targetId)
        if let hash = contentHash {
            sqlite3_bind_text(stmt, 3, (hash as NSString).utf8String, -1, nil)
        }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }

        let blobPtr = sqlite3_column_blob(stmt, 0)
        let blobSize = Int(sqlite3_column_bytes(stmt, 0))
        let dimension = Int(sqlite3_column_int(stmt, 1))
        let model = String(cString: sqlite3_column_text(stmt, 2))

        guard let ptr = blobPtr, blobSize == dimension * MemoryLayout<Float>.size else { return nil }
        let floats = Array(UnsafeBufferPointer(start: ptr.assumingMemoryBound(to: Float.self), count: dimension))
        return EmbeddingVector(values: floats, model: model, tokenCount: 0)
    }

    /// Count how many embeddings exist of a given type.
    func embeddingCount(targetType: String) -> Int {
        guard let stmt = try? prepare("SELECT COUNT(*) FROM embeddings WHERE target_type = ?1") else { return 0 }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (targetType as NSString).utf8String, -1, nil)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }

    /// Get all file IDs that have embeddings of a given type.
    func fileIdsWithEmbeddings(targetType: String) -> Set<Int64> {
        guard let stmt = try? prepare("SELECT target_id FROM embeddings WHERE target_type = ?1") else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (targetType as NSString).utf8String, -1, nil)
        var ids: Set<Int64> = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            ids.insert(sqlite3_column_int64(stmt, 0))
        }
        return ids
    }

    // MARK: - Subtree summaries

    func upsertSubtreeSummary(root: String, summary: String, fileCount: Int,
                                firstPartyCount: Int, languageMix: [String: Int],
                                manifestPaths: [String]) throws {
        let sql = """
        INSERT OR REPLACE INTO subtree_summaries (subtree_root, summary_text, file_count,
            first_party_count, language_mix, manifest_paths)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6)
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (root as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (summary as NSString).utf8String, -1, nil)
        sqlite3_bind_int(stmt, 3, Int32(fileCount))
        sqlite3_bind_int(stmt, 4, Int32(firstPartyCount))
        let langJSON = (try? JSONSerialization.data(withJSONObject: languageMix)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        sqlite3_bind_text(stmt, 5, (langJSON as NSString).utf8String, -1, nil)
        let manifestJSON = (try? JSONSerialization.data(withJSONObject: manifestPaths)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        sqlite3_bind_text(stmt, 6, (manifestJSON as NSString).utf8String, -1, nil)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw MemoryStoreError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    func subtreeSummary(forRoot root: String) -> String? {
        guard let stmt = try? prepare("SELECT summary_text FROM subtree_summaries WHERE subtree_root = ?1") else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (root as NSString).utf8String, -1, nil)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return String(cString: sqlite3_column_text(stmt, 0))
    }

    func allSubtreeSummaries() -> [(root: String, summary: String, fileCount: Int)] {
        guard let stmt = try? prepare("SELECT subtree_root, summary_text, file_count FROM subtree_summaries ORDER BY subtree_root") else { return [] }
        defer { sqlite3_finalize(stmt) }
        var results: [(String, String, Int)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append((
                String(cString: sqlite3_column_text(stmt, 0)),
                String(cString: sqlite3_column_text(stmt, 1)),
                Int(sqlite3_column_int(stmt, 2))
            ))
        }
        return results
    }

    // MARK: - Chunk-level embedding queries

    /// Retrieve the stored content_hash for an embedding, to check freshness without loading the vector.
    func embeddingContentHash(targetType: String, targetId: Int64) -> String? {
        guard let stmt = try? prepare("SELECT content_hash FROM embeddings WHERE target_type = ?1 AND target_id = ?2") else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (targetType as NSString).utf8String, -1, nil)
        sqlite3_bind_int64(stmt, 2, targetId)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return String(cString: sqlite3_column_text(stmt, 0))
    }

    /// Delete stale embeddings whose content_hash no longer matches the current content.
    /// Returns the number of rows deleted.
    @discardableResult
    func deleteStaleEmbeddings(targetType: String, targetId: Int64, currentHash: String) -> Int {
        let sql = "DELETE FROM embeddings WHERE target_type = ?1 AND target_id = ?2 AND content_hash != ?3"
        guard let stmt = try? prepare(sql) else { return 0 }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (targetType as NSString).utf8String, -1, nil)
        sqlite3_bind_int64(stmt, 2, targetId)
        sqlite3_bind_text(stmt, 3, (currentHash as NSString).utf8String, -1, nil)
        sqlite3_step(stmt)
        return Int(sqlite3_changes(db))
    }

    /// Bulk-check which segment IDs have fresh embeddings (content_hash matches).
    /// Returns segment IDs that already have valid embeddings.
    func segmentIdsWithFreshEmbeddings(segmentIds: [Int64], contentHashes: [Int64: String]) -> Set<Int64> {
        guard !segmentIds.isEmpty else { return [] }
        var fresh: Set<Int64> = []
        for segId in segmentIds {
            guard let storedHash = embeddingContentHash(targetType: "segment", targetId: segId) else { continue }
            if let currentHash = contentHashes[segId], storedHash == currentHash {
                fresh.insert(segId)
            }
        }
        return fresh
    }

    /// Load multiple segment embeddings by ID in a single pass.
    func segmentEmbeddings(segmentIds: [Int64]) -> [Int64: EmbeddingVector] {
        guard !segmentIds.isEmpty else { return [:] }
        var result: [Int64: EmbeddingVector] = [:]
        for segId in segmentIds {
            if let vec = embedding(targetType: "segment", targetId: segId) {
                result[segId] = vec
            }
        }
        return result
    }

    /// Delete all embeddings of a given type (for full re-index).
    func deleteAllEmbeddings(targetType: String) {
        _ = try? execute("DELETE FROM embeddings WHERE target_type = '\(targetType)'")
    }

    /// Relevant subtree summaries for a set of project roots.
    func subtreeSummaries(forRoots roots: Set<String>) -> [(root: String, summary: String)] {
        guard !roots.isEmpty else { return [] }
        var results: [(String, String)] = []
        for root in roots {
            if let summary = subtreeSummary(forRoot: root) {
                results.append((root, summary))
            }
        }
        return results
    }
}
