import Foundation

final class DashboardStore {
    // shortcut: a pass stops after this many scanned files so a burst of cold
    // files cannot stall the queue; the rest arrive on the next pass.
    var maxFilesPerPass = 8
    var saveInterval: TimeInterval = 5

    private let scanner: Scanner
    private let cachePath: String
    private let queue = DispatchQueue(label: "com.local.pistatusbar.dashboard", qos: .utility)
    private var cursors: [String: FileCursor] = [:]
    private var contributions: [String: FileContribution] = [:]
    // Queue-confined. The UI reads it back from the published snapshot instead.
    private var range: StatsRange = .all
    private var lastSave = Date.distantPast
    private var refreshPending = false // main thread only

    // Readable from the main thread without a lock: a value type replaced
    // wholesale on publication.
    private(set) var snapshot = DashboardSnapshot()
    // Queue-confined result of the last pass, used for publication and checks.
    private(set) var lastPassSnapshot = DashboardSnapshot()

    init(cachePath: String, sessionRoot: String) {
        self.cachePath = cachePath
        self.scanner = Scanner(rootDir: sessionRoot)
        if let cache = DashboardStore.loadCache(at: cachePath),
           cache.version == 2,
           cache.timeZoneIdentifier == TimeZone.current.identifier {
            cursors = cache.cursors
            contributions = cache.contributions
            range = cache.range
            lastPassSnapshot = cache.snapshot
            snapshot = cache.snapshot
        }
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
            self.lastPassSnapshot = buildSnapshot(Array(self.contributions.values), range: newRange,
                                                  filesScanned: self.lastPassSnapshot.filesScanned,
                                                  scanMillis: self.lastPassSnapshot.scanMillis)
            let published = self.lastPassSnapshot
            DispatchQueue.main.async { self.snapshot = published }
        }
    }

    func stop() {
        queue.sync { self.save(force: true) }
    }

    func runPass() {
        let started = Date()
        let files = scanner.enumerateSessionFiles()
        let present = Set(files)
        for path in cursors.keys where !present.contains(path) {
            cursors[path] = nil
            contributions[path] = nil
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
            let decision = scanner.decide(cursor: cursors[path], inode: stat.inode, size: stat.size)
            if decision == .skipUnchanged { continue }
            guard let result = scanner.scan(path: path, decision: decision,
                                            base: contributions[path] ?? FileContribution(),
                                            inode: stat.inode, size: stat.size) else { continue }
            cursors[path] = result.cursor
            contributions[path] = result.contribution
            scanned += 1
        }

        lastPassSnapshot = buildSnapshot(Array(contributions.values), range: range, filesScanned: files.count,
                                         scanMillis: Int(Date().timeIntervalSince(started) * 1000))
        save(force: false)
    }

    func save(force: Bool) {
        let now = Date()
        guard force || now.timeIntervalSince(lastSave) >= saveInterval else { return }
        lastSave = now
        write()
    }

    func saveNow() { write() }

    private func write() {
        let cache = DashboardCache(version: 2,
                                   timeZoneIdentifier: TimeZone.current.identifier,
                                   range: range,
                                   savedAt: Date(),
                                   cursors: cursors,
                                   contributions: contributions,
                                   snapshot: lastPassSnapshot)
        guard let data = try? JSONEncoder().encode(cache) else { return }
        let dir = (cachePath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: cachePath), options: .atomic)
    }

    static func loadCache(at path: String) -> DashboardCache? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode(DashboardCache.self, from: data)
    }

    var allContributions: [FileContribution] { Array(contributions.values) }
    var contributionsByPath: [String: FileContribution] { contributions }
    var allCursors: [String: FileCursor] { cursors }
    var bytesReadLastPass: Int64 { scanner.bytesReadThisPass }
}
