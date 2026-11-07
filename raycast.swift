import AppKit
import Combine

/// Keeps the gated mode's apps (Socials) out of Raycast while you are in another mode: they are
/// added to Raycast's own disabled apps, and taken out again in Socials. Raycast reads that list
/// only when it starts, so the dock stops Raycast, writes the list and starts it again, in the
/// background (under half a second). Going into the gated mode does it at once, so Raycast offers
/// its apps by the time you open it there (it used to wait for Raycast's window to close, and you
/// were back out before then). Leaving waits 10 s with no Raycast window open, the time in
/// which going back needs no wait, so a quick look in and out restarts Raycast once at most. Apps
/// you disabled in Raycast yourself stay disabled: the dock takes out only what it put in
/// (`raycast.json` for v1, `raycast-v2.json` for v2). The Raycast add-in (`addIns.raycast`) turns it
/// off, and gives back what it hid.
///
/// Which Raycast is installed is read at each change (`RaycastCore.kind`), so an update from 1.x to
/// 2.x is followed without a restart of the dock. v2 support is untried on a real v2 install (it
/// needs macOS 26): it is built from Raycast 2.11.1's own code and tested against its data core in
/// `tests/run.sh`, and it touches nothing unless a key matches Raycast's `last_key`.
@MainActor
final class RaycastSync {
    private let model: DockModel
    private var timer: Timer?               // runs only while Raycast is out of step with the mode
    private var watch: AnyCancellable?
    private var seen: (gated: Bool, since: Date)?
    private var applied: Bool?               // the gated state the list was last made for
    private var jobs = 0                    // changes queued and not yet back: one count, not one flag per owner
    private let work = DispatchQueue(label: "raycast-sync")
    nonisolated private static let support = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/com.raycast.macos").path
    nonisolated private static let v1DB = support + "/raycast-enc.sqlite"
    nonisolated private static let managedURL = dir.appendingPathComponent("raycast.json")
    nonisolated private static let managedV2URL = dir.appendingPathComponent("raycast-v2.json")
    nonisolated private static let sqlcipher = ["/opt/zerobrew/bin/sqlcipher", "/opt/homebrew/bin/sqlcipher", "/usr/local/bin/sqlcipher"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }
    /// The v2 passphrase once found, so the keychain is asked once a run of the dock. Read and
    /// written on the `raycast-sync` queue only.
    nonisolated(unsafe) private static var v2Key: String?
    /// The `last_key` no keychain item matched, so that the keychain is not asked again at each
    /// switch until Raycast's key changes.
    nonisolated(unsafe) private static var v2Missed: Data?

    init(model: DockModel) {
        self.model = model
    }

    /// The Raycast add-in. Off, the dock gives Raycast back the apps it hid (one restart, if any).
    func setEnabled(_ on: Bool) {
        guard on != (watch != nil) else { return }
        if on {
            if let why = Self.unusable() { log("raycast: \(why), Raycast left alone"); return }
            applied = nil
            // `state` publishes before it changes: look once the change is in.
            watch = model.$state.sink { [weak self] _ in DispatchQueue.main.async { MainActor.assumeIsolated { self?.wake() } } }
            return
        }
        watch = nil
        timer?.invalidate()
        timer = nil
        jobs += 1
        // A change under way finishes first; the queue runs them in order.
        work.async { [weak self] in
            _ = Self.apply(hide: [])
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.jobs -= 1 } }
        }
    }

    private func wake() {
        tick()
        if timer == nil, applied != (model.currentMode?.gate != nil) { timer = every(0.25) { [weak self] in self?.tick() } }
    }

    private func tick() {
        guard jobs == 0 else { return }
        let gated = model.currentMode?.gate != nil
        if seen?.gated != gated { seen = (gated, Date()) }
        guard applied != gated, let s = seen else { timer?.invalidate(); timer = nil; return }
        if !gated, applied != nil, Date().timeIntervalSince(s.since) < 10 || raycastWindowOpen() { return }
        let hide = gated ? [] : model.config.modes.filter { $0.gate != nil }.flatMap { $0.apps ?? [] }
        jobs += 1
        work.async { [weak self] in
            let ok = Self.apply(hide: hide)
            DispatchQueue.main.async { MainActor.assumeIsolated {
                self?.jobs -= 1
                // A failure is not retried every second: the next change of mode tries again.
                self?.applied = gated
                if !ok { log("raycast: list not changed") }
            } }
        }
    }

    private func raycastWindowOpen() -> Bool {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.contains { ($0[kCGWindowOwnerName as String] as? String) == "Raycast" && [1, 2, 3, 8, 101].contains($0[kCGWindowLayer as String] as? Int ?? 0) }
    }

    // MARK: Off the main thread

    private struct Managed: Codable { var added: [String] }
    private struct ManagedV2: Codable { var rows: [String: RaycastCore.Mark] }

    nonisolated private static func appURL() -> URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: RaycastCore.bundle) }

    /// The installed Raycast, read from its Info.plist each time (a Bundle would cache it across an update).
    nonisolated private static func kind() -> RaycastCore.Kind {
        let version = appURL().flatMap { NSDictionary(contentsOf: $0.appendingPathComponent("Contents/Info.plist")) }?["CFBundleShortVersionString"] as? String
        let fm = FileManager.default
        return RaycastCore.kind(version: version, hasV1Database: fm.fileExists(atPath: v1DB),
                                hasV2Database: fm.fileExists(atPath: support + "/settings_v2.db"))
    }

    /// Why the add-in cannot work here, or nil.
    nonisolated private static func unusable() -> String? {
        switch kind() {
        case .none: return "no Raycast found"
        case .v1:
            if sqlcipher == nil { return "Raycast 1 needs sqlcipher, not found" }
            if !FileManager.default.fileExists(atPath: v1DB) { return "no Raycast 1 database" }
        case .v2:
            guard let app = appURL() else { return "no Raycast 2 app" }
            if RaycastCore.dataModule(appPath: app.path, arch: RaycastCore.arch) == nil { return "Raycast 2's data core not found" }
            if RaycastCore.node(supportDir: support, home: NSHomeDirectory()) == nil { return "no Node to run Raycast 2's data core" }
        }
        return nil
    }

    nonisolated private static func apply(hide: [String]) -> Bool {
        let k = kind()
        switch k {
        case .v1: return applyV1(hide: hide)
        case .v2: return applyV2(hide: hide)
        case .none: log("raycast: no Raycast found"); return false
        }
    }

    /// Stops Raycast outright rather than asking it to quit: a quit took seconds and writes
    /// Raycast's settings back. Its databases are SQLite with a write-ahead log, which a stop
    /// leaves whole. Returns whether it ran, or nil when it would not stop.
    nonisolated private static func stopRaycast() -> Bool? {
        let running = DispatchQueue.main.sync { NSRunningApplication.runningApplications(withBundleIdentifier: RaycastCore.bundle) }
        running.forEach { $0.forceTerminate() }
        for _ in 0..<100 where running.contains(where: { !$0.isTerminated }) { usleep(20_000) }
        if running.contains(where: { !$0.isTerminated }) { log("raycast: did not quit"); return nil }
        return !running.isEmpty
    }

    nonisolated private static func startRaycast() {
        guard let url = appURL() else { return }
        let c = NSWorkspace.OpenConfiguration()
        c.activates = false
        c.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: url, configuration: c)
    }

    // MARK: Raycast 1

    /// Makes Raycast's disabled apps the user's own plus `hide`, restarting Raycast only on a change.
    nonisolated private static func applyV1(hide: [String]) -> Bool {
        guard let key = v1Passphrase() else { log("raycast: no database key"); return false }
        guard let raw = sql(key, "SELECT configuration FROM raycastConfiguration WHERE extensionId='builtin_package_default';"),
              let data = raw.data(using: .utf8),
              var conf = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { log("raycast: could not read its settings"); return false }
        let current = conf["disabledApps"] as? [[String: Any]] ?? []
        let added = Set(readJSON(managedURL, Managed.self)?.added ?? [])
        let ownIds = Set(current.compactMap { $0["identifier"] as? String }).subtracting(added)
        let paths = appPaths(key, hide.filter { !ownIds.contains($0) })
        let plan = RaycastCore.v1Plan(current: current, added: added, hide: hide, paths: paths)
        guard plan.changed else {
            writeJSON(managedURL, Managed(added: plan.extra))
            return true
        }
        conf["disabledApps"] = plan.next
        guard let out = try? JSONSerialization.data(withJSONObject: conf, options: [.prettyPrinted, .sortedKeys]) else { return false }
        let t0 = Date()
        guard let wasRunning = stopRaycast() else { return false }
        let wrote = sql(key, "UPDATE raycastConfiguration SET configuration = CAST(x'\(RaycastCore.hex(out))' AS TEXT) WHERE extensionId='builtin_package_default'; SELECT changes();") == "1"
        if wrote { writeJSON(managedURL, Managed(added: plan.extra)) }
        if wasRunning { startRaycast() }
        log("raycast: \(hide.isEmpty ? "Socials apps back" : "Socials apps hidden") (\(plan.extra.count) added, \(plan.own) your own)\(wrote ? "" : ", write failed"), restarted in \(String(format: "%.2f", Date().timeIntervalSince(t0))) s")
        return wrote
    }

    /// Raycast's own path for each app, as its search index has it; else where macOS finds the app.
    nonisolated private static func appPaths(_ key: String, _ ids: [String]) -> [String: String] {
        guard !ids.isEmpty else { return [:] }
        let list = ids.map { "'\($0.replacingOccurrences(of: "'", with: "''"))'" }.joined(separator: ",")
        var paths: [String: String] = [:]
        for line in (sql(key, "SELECT key || char(9) || path FROM search WHERE key IN (\(list)) AND path IS NOT NULL AND uninstalled = 0;") ?? "")
            .split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            if parts.count == 2 { paths[parts[0]] = parts[1] }
        }
        for id in ids where paths[id] == nil {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { paths[id] = "/System/Volumes/Data" + url.path }
        }
        return paths
    }

    nonisolated private static func v1Passphrase() -> String? {
        keychain("Raycast", "database_key").map { RaycastCore.passphrase(keychainValue: $0) }
    }

    nonisolated private static func keychain(_ service: String, _ account: String) -> String? {
        guard let k = run("/usr/bin/security", ["find-generic-password", "-s", service, "-a", account, "-w"], input: nil),
              !k.isEmpty else { return nil }
        return k
    }

    nonisolated private static func sql(_ key: String, _ statement: String) -> String? {
        guard let bin = sqlcipher else { return nil }
        let input = "PRAGMA key = '\(key)';\nPRAGMA busy_timeout = 5000;\n.mode list\n\(statement)\n"
        guard let out = run(bin, [v1DB], input: input) else { return nil }
        // The two pragmas answer "ok" and "5000" first.
        let lines = out.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            .filter { $0 != "ok" && $0 != "5000" }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Raycast 2

    /// The same for v2: one `commands` row an app, written through Raycast's own data core while
    /// Raycast is stopped. Apps are found by path, every copy macOS knows of.
    nonisolated private static func applyV2(hide: [String]) -> Bool {
        guard let app = appURL(), let module = RaycastCore.dataModule(appPath: app.path, arch: RaycastCore.arch) else {
            log("raycast 2: data core not found"); return false
        }
        guard let node = RaycastCore.node(supportDir: support, home: NSHomeDirectory()) else { log("raycast 2: no Node found"); return false }
        let managed = readJSON(managedV2URL, ManagedV2.self)?.rows ?? [:]
        let wanted = Set(hide.flatMap { id in
            NSWorkspace.shared.urlsForApplications(withBundleIdentifier: id)
                .filter { !$0.path.contains("/.Trash/") }
                .map { RaycastCore.v2CommandId(appPath: $0.path) }
        })
        let plan = RaycastCore.v2Plan(managed: managed, wanted: wanted)
        guard plan.writes else {
            if !plan.restore.isEmpty { writeJSON(managedV2URL, ManagedV2(rows: RaycastCore.v2Managed(managed, plan, results: [:]))) }
            return true
        }
        guard let lastKey = FileManager.default.contents(atPath: support + "/last_key") else { log("raycast 2: no last_key, Raycast not set up yet"); return false }
        if let k = v2Key, !RaycastCore.matchesLastKey(k, lastKey) { v2Key = nil }
        if v2Key == nil, v2Missed != lastKey {
            let values = RaycastCore.v2KeychainItems.compactMap { keychain($0.service, $0.account) }
            v2Key = RaycastCore.v2Passphrase(keychainValues: values, lastKey: lastKey)
            if v2Key == nil { v2Missed = lastKey }
        }
        guard let key = v2Key else {
            log("raycast 2: no keychain key matches its databases (Raycast 2 keeps its key where only it can read it), Raycast left alone")
            return false
        }
        let t0 = Date()
        guard let wasRunning = stopRaycast() else { return false }
        let report = RaycastCore.runV2Helper(node: node, request: .init(module: module, supportDir: support, key: key,
                                                                         disable: plan.disable, restore: plan.restore))
        let results = report?.results ?? [:]
        writeJSON(managedV2URL, ManagedV2(rows: RaycastCore.v2Managed(managed, plan, results: results)))
        if wasRunning { startRaycast() }
        let added = results.values.filter { $0 == "created" || $0 == "flipped" }.count
        let own = results.values.filter { $0 == "own" }.count
        let fault = report == nil ? ", helper gave no answer" : report?.ok == false ? ", \(report?.error ?? "failed")" : ""
        log("raycast 2: \(hide.isEmpty ? "Socials apps back" : "Socials apps hidden") (\(added) hidden, \(own) your own, \(results.values.filter { $0 == "restored" }.count) back)\(fault), restarted in \(String(format: "%.2f", Date().timeIntervalSince(t0))) s")
        return report?.ok == true
    }

    nonisolated private static func run(_ path: String, _ args: [String], input: String?) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe(), inp = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = inp
        do { try p.run() } catch { return nil }
        if let input { inp.fileHandleForWriting.write(Data(input.utf8)) }
        try? inp.fileHandleForWriting.close()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .newlines)
    }
}
