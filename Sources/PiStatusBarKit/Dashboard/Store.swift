import Foundation

final class DashboardStore {
    // shortcut: a pass stops after this many scanned files so a burst of cold
    // files cannot stall the queue; the rest arrive on the next pass.
    var maxFilesPerPass = 8
    var saveInterval: TimeInterval = 5

    private let scanner: Scanner
    private let cachePath: String
    private let queue = DispatchQueue(label: "io.github.sabuz796.pistatusbar.dashboard", qos: .utility)
    private var cursors: [String: FileCursor] = [:]
    private var contributions: [String: FileContribution] = [:]
    // Transcripts pruned out of the hot set. Their totals still belong in the
    // snapshot; retiring them whole keeps sessions and project rows intact.
    private var archive: [String: FileContribution] = [:]
    // Queue-confined. The UI reads it back from the published snapshot instead.
    private var range: StatsRange = .all
    private var lastSave = Date.distantPast
    private var refreshPending = false // main thread only
    // Queue-confined: something changed since the last write. The cache holds
    // one entry per transcript, so rewriting it on every idle pass costs disk
    // time that grows with history and buys nothing.
    private var dirty = false
    // Warning fires once, not on every save past the limit.
    private var warnedAboutCacheSize = false

    // Readable from the main thread without a lock: a value type replaced
    // wholesale on publication.
    private(set) var snapshot = DashboardSnapshot()
    // Queue-confined result of the last pass, used for publication and checks.
    private(set) var lastPassSnapshot = DashboardSnapshot()

    init(cachePath: String, sessionRoot: String) {
        self.cachePath = cachePath
        self.scanner = Scanner(rootDir: sessionRoot)
        // Queue-confined load, enqueued before any refresh so the first pass
        // still starts from the saved cursors instead of a cold rescan. The
        // file grows with history, so it is never decoded on the main thread.
        queue.async { [weak self] in self?.loadCacheFromDisk() }
    }

    private func loadCacheFromDisk() {
        guard let cache = DashboardStore.loadCache(at: cachePath),
              cache.version == 2,
              cache.timeZoneIdentifier == TimeZone.current.identifier else { return }
        cursors = cache.cursors
        contributions = cache.contributions
        archive = cache.archive
        // Cursors written before pruning existed have no lastChanged stamp.
        // A cache that was just saved is fresh by definition, so backfill.
        for path in cursors.keys where cursors[path]?.lastChanged == .distantPast {
            cursors[path]?.lastChanged = cache.savedAt
        }
        range = cache.range
        lastPassSnapshot = cache.snapshot
        DispatchQueue.main.async { [weak self] in self?.snapshot = cache.snapshot }
    }

    func refresh(completion: ((DashboardSnapshot) -> Void)? = nil) {
        guard !refreshPending else { return }
        refreshPending = true
        queue.async { [weak self] in
            guard let self = self else { return }
            self.runPass()
            let published = self.lastPassSnapshot
            DispatchQueue.main.async {
                self.refreshPending = false
                self.snapshot = published
                completion?(published)
            }
        }
    }

    // Rebuilt from the day buckets already in memory, so switching range never
    // touches the transcripts.
    func setRange(_ newRange: StatsRange) {
        queue.async { [weak self] in
            guard let self = self, self.range != newRange else { return }
            self.range = newRange
            self.lastPassSnapshot = buildSnapshot(Array(self.contributions.values) + Array(self.archive.values),
                                                  range: newRange,
                                                  filesScanned: self.lastPassSnapshot.filesScanned,
                                                  scanMillis: self.lastPassSnapshot.scanMillis)
            self.dirty = true
            let published = self.lastPassSnapshot
            DispatchQueue.main.async { self.snapshot = published }
        }
    }

    func stop() {
        queue.sync { self.save(force: true) }
    }

    // Synchronous pass for the self-check: queue.sync also waits for the pending
    // cache load, so the pass starts from a known state.
    func runPassNow() { queue.sync { runPass() } }

    func runPass() {
        let started = Date()
        let files = scanner.enumerateSessionFiles()
        let present = Set(files)
        for path in cursors.keys where !present.contains(path) {
            cursors[path] = nil
            contributions[path] = nil
            archive[path] = nil
            dirty = true
        }

        scanner.resetByteCounter()
        // A cold cache must converge in one pass. The steady-state cap exists so a
        // burst of newly written files cannot hold the queue, not to ration the
        // first build, which would otherwise take six refreshes to fill in.
        let cap = cursors.isEmpty ? Int.max : maxFilesPerPass
        var scanned = 0
        for path in files {
            guard scanned < cap else { break }
            guard let stat = scanner.stat(at: path) else { continue }
            let decision = scanner.decide(cursor: cursors[path], inode: stat.inode, size: stat.size,
                                          mtime: stat.mtime)
            if decision == .skipUnchanged { continue }
            guard let result = scanner.scan(path: path, decision: decision,
                                            base: contributions[path] ?? FileContribution(),
                                            inode: stat.inode, size: stat.size, mtime: stat.mtime) else { continue }
            cursors[path] = result.cursor
            contributions[path] = result.contribution
            // A fresh scan covers the whole file, so an archived copy of the
            // same transcript is subsumed from now on.
            archive[path] = nil
            dirty = true
            scanned += 1
        }
        pruneIfNeeded()

        lastPassSnapshot = buildSnapshot(Array(contributions.values) + Array(archive.values), range: range,
                                         filesScanned: files.count,
                                         scanMillis: Int(Date().timeIntervalSince(started) * 1000))
        save(force: false)
    }

    // Retire cold transcripts so the hot set (and the file this writes) stays
    // bounded without losing anyone's totals. Stale ones first, then the
    // oldest beyond the cap.
    private static let hotFiles = 64
    private static let staleDays = 60

    static func retiredPaths(_ contributions: [String: FileContribution],
                             _ cursors: [String: FileCursor],
                             staleCutoff: Date, hotCap: Int) -> Set<String> {
        func lastChanged(_ path: String) -> Date { cursors[path]?.lastChanged ?? .distantPast }
        let order = contributions.keys.sorted { lastChanged($0) < lastChanged($1) }
        var retired: Set<String> = []
        for path in order where lastChanged(path) < staleCutoff { retired.insert(path) }
        var kept = contributions.count - retired.count
        for path in order where !retired.contains(path) {
            guard kept > hotCap else { break }
            retired.insert(path)
            kept -= 1
        }
        return retired
    }

    private func pruneIfNeeded() {
        guard !contributions.isEmpty else { return }
        let cutoff = Calendar.current.date(byAdding: .day, value: -Self.staleDays, to: Date()) ?? Date()
        let retired = DashboardStore.retiredPaths(contributions, cursors,
                                                  staleCutoff: cutoff, hotCap: Self.hotFiles)
        guard !retired.isEmpty else { return }
        for path in retired {
            if let contribution = contributions.removeValue(forKey: path) { archive[path] = contribution }
            cursors[path] = nil
        }
        dirty = true
    }

    func save(force: Bool) {
        let now = Date()
        guard force || dirty else { return }
        guard force || now.timeIntervalSince(lastSave) >= saveInterval else { return }
        lastSave = now
        write()
    }

    func saveNow() { queue.sync { write() } }

    private func write() {
        let cache = DashboardCache(version: 2,
                                   timeZoneIdentifier: TimeZone.current.identifier,
                                   range: range,
                                   savedAt: Date(),
                                   cursors: cursors,
                                   contributions: contributions,
                                   archive: archive,
                                   snapshot: lastPassSnapshot)
        guard let data = try? JSONEncoder().encode(cache) else { return }
        if data.count > 20 * 1024 * 1024 && !warnedAboutCacheSize {
            warnedAboutCacheSize = true
            logEvent(level: "warn", source: "app", event: "dashboard-cache-huge",
                     ["bytes": String(data.count)])
        }
        let dir = (cachePath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        do {
            try data.write(to: URL(fileURLWithPath: cachePath), options: .atomic)
            dirty = false
        } catch {}
    }

    static func loadCache(at path: String) -> DashboardCache? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode(DashboardCache.self, from: data)
    }

    var allContributions: [FileContribution] {
        Array(contributions.values) + Array(archive.values)
    }
    var contributionsByPath: [String: FileContribution] { contributions }
    var archivedByPath: [String: FileContribution] { archive }
    var allCursors: [String: FileCursor] { cursors }
    var bytesReadLastPass: Int64 { scanner.bytesReadThisPass }
}
