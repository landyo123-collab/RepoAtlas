# Repo Atlas

A local-first macOS app for understanding code repositories you didn't write.

Drop in any folder — Repo Atlas scans it, ranks the important files, infers its structure, and gives you a navigable map of the codebase. No account required. Fully offline by default.

---

## Features

**Scanning and understanding** — no setup needed
- Drag-and-drop or open any local repository folder
- Deterministic recursive scan with junk filtering and size limits
- Importance-ranked file list based on structural heuristics
- Language breakdown and inferred architectural zones
- Offline repo summary generated without any LLM

**Persistent local repo memory** — optional, but powerful
- Index a repo once into a local SQLite database
- Stores file segments, symbols, and cross-file references
- Fast grounded retrieval across sessions — no re-scanning needed
- Semantic embedding support via OpenAI (optional)

**Grounded Q&A** — powered by DeepSeek (optional)
- Ask questions about the repo against its indexed memory
- Context assembled from real files using multi-phase retrieval
- FTS + graph traversal narrows candidates before any LLM call
- On-disk answer cache — same question on same repo costs nothing twice

**Launchpad** — run detection and execution (optional)
- Detects how to run the repo: Swift, Python, web servers, and more
- Resolves interpreters, virtual environments, and build tools
- Shows a run plan with confidence rating before executing
- Streams terminal output directly in the app

---

## Requirements

- macOS 13.0+
- Xcode 15+ (to build from source)
- DeepSeek API key — optional, only for Q&A features
- OpenAI API key — optional, only for semantic embeddings

---

## Building

1. Clone this repo
2. Open `RepoAtlas.xcodeproj` in Xcode
3. Select the **RepoAtlas** scheme and build/run (⌘R)

> `Package.swift` is included for SwiftPM development, but the SwiftPM executable
> target does not produce a Finder-launchable `.app` bundle with proper Dock
> behavior. Use Xcode for the full experience.

---

## Configuration

All AI features are opt-in. The app works completely offline for scanning, browsing,
importance ranking, zone inference, and file preview.

Config loads in this priority order:
1. In-app Settings (⌘,)
2. `~/.repoatlas.env`
3. Environment variables

Quick setup:
```bash
cp .env.example ~/.repoatlas.env
# then edit ~/.repoatlas.env and paste your keys
```

See `.env.example` for all available options.

Cache and memory stored at:
```
~/Library/Application Support/RepoAtlas/
```

---

## How it works

Repo Atlas is deterministic-first. For every Q&A query, it runs a multi-phase
retrieval pipeline before contacting any LLM:

1. **Scan** — files ranked by importance heuristics (pattern weights, import counts, depth)
2. **Index** — SQLite repo memory built from segments, symbols, and a reference graph
3. **Classify** — query intent classified deterministically (no LLM required for this step)
4. **Retrieve** — FTS path/content/symbol search + graph expansion narrows to relevant files
5. **Assemble** — context built from real indexed content, token-budget-aware
6. **Ask** — context sent to DeepSeek; answer cached on disk

This means answers are grounded in actual repo files rather than arbitrary
context windows, and the LLM call only happens after local work confirms
what is worth looking at.

---

## Privacy

Repo Atlas never uploads your code anywhere unless you explicitly trigger a Q&A or
embedding operation. Scanning, indexing, file preview, zone inference, and Launchpad
detection are all fully local and require no network connection.

API keys are stored in macOS UserDefaults or your local `~/.repoatlas.env` file.
They are never written to disk in the app bundle or source tree.

---

## Architecture

```
Sources/
├── RepoAtlasApp/            main macOS application
│   ├── Models/              data structures
│   ├── Services/            all business logic
│   │   └── RepoMemory/      SQLite indexing, retrieval, embeddings
│   ├── Views/               SwiftUI UI
│   └── Utilities/           config, constants, helpers
└── EvalRunner/              CLI evaluation harness for the retrieval pipeline
```

The app has no external Swift package dependencies. It uses only Foundation,
SwiftUI, AppKit, and SQLite3 (bundled with macOS).

---

## License

MIT — see [LICENSE](LICENSE).
