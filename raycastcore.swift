import Foundation
import CryptoKit

/// The parts of the Raycast add-in that need neither AppKit nor a running Raycast: which Raycast is
/// installed, its ids and keys, and what to change. `tests/raycast-tests.swift` builds this file
/// alone (`tests/run.sh`).
///
/// Raycast 1.x keeps its settings in `raycast-enc.sqlite` (SQLCipher), its disabled apps as a JSON
/// list in the `builtin_package_default` configuration. Raycast 2.x (macOS 26) keeps them in
/// `settings_v2.db`, one row a command in `commands`: an app is the dynamic command
/// `c:r:applications::*::application` with the app's path as its instance, and a disabled app is
/// such a row with `enabled` 0. Its own importer writes exactly that for each v1 disabled app. Its
/// databases use a cipher of their own that no sqlcipher opens, so the dock writes them through
/// Raycast's own data core (`data.darwin-arm64.node`, run by Node), the code Raycast itself runs.
enum RaycastCore {
    static let bundle = "com.raycast.macos"
    /// Raycast's fixed salt: the database passphrase is the SHA-256, in hex, of the keychain's key
    /// and this (v1's `PRAGMA key`; v2's `derivePassphrase(from:)` holds the same string).
    static let salt = "yvkwWXzxPPBAqY2tmaKrB*DvYjjMaeEf"

    enum Kind: String, Equatable { case v1, v2, none }

    /// v1 is 1.x and v2 is 2.x by the app's version. With no readable version the files decide:
    /// v2 moves the v1 files into a backup folder when it first starts and makes `settings_v2.db`.
    static func kind(version: String?, hasV1Database: Bool, hasV2Database: Bool) -> Kind {
        if let v = version, let major = Int(v.split(separator: ".").first.map(String.init) ?? "") {
            if major >= 2 { return .v2 }
            if major == 1 { return .v1 }
        }
        if hasV2Database { return .v2 }
        if hasV1Database { return .v1 }
        return .none
    }

    // MARK: Keys

    static func hex(_ bytes: some Sequence<UInt8>) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

    static func passphrase(keychainValue k: String) -> String { hex(SHA256.hash(data: Data((k + salt).utf8))) }

    /// v2 writes `last_key` beside its databases: the SHA-512 of the passphrase it last opened them
    /// with, 64 bytes. A key that does not match it is never tried on the databases.
    static func matchesLastKey(_ passphrase: String, _ lastKey: Data) -> Bool {
        lastKey.count == 64 && Data(SHA512.hash(data: Data(passphrase.utf8))) == lastKey
    }

    /// The first passphrase that `last_key` confirms: each keychain value as Raycast derives it,
    /// then as it is (an override is already a passphrase).
    static func v2Passphrase(keychainValues: [String], lastKey: Data) -> String? {
        for v in keychainValues where !v.isEmpty {
            for p in [passphrase(keychainValue: v), v] where matchesLastKey(p, lastKey) { return p }
        }
        return nil
    }

    /// Where a v2 key may be that `security` can read: v2 keeps its own in a keychain group only
    /// Raycast can open, with a backup (`database_key_backup`) and the classic items beside it.
    static let v2KeychainItems: [(service: String, account: String)] = [
        ("com.raycast.macos", "database_key_backup"),
        ("com.raycast.macos", "database_key"),
        ("Raycast", "database_key"),
        ("Raycast", "database_key_backup"),
        ("Raycast X", "database_key"),
        ("Raycast X", "database_key_backup"),
    ]

    // MARK: v2 ids

    static let v2Extension = "e:r:applications"
    static let v2AppCommand = "c:r:applications::*::application"

    /// The path as v2 has it: without the data volume's `/System/Volumes/Data`, as its importer
    /// strips it, and with no slash at the end.
    static func v2Path(_ path: String) -> String {
        var p = path
        if p.hasPrefix("/System/Volumes/Data/") { p.removeFirst("/System/Volumes/Data".count) }
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        return p
    }

    static func v2CommandId(appPath: String) -> String { "\(v2AppCommand)::=::\(v2Path(appPath))" }

    // MARK: v1 plan

    /// v1's next disabled list: the user's own entries (those the dock did not add) and the apps
    /// to hide that are not already among them, each at its path; `changed` when the ids differ.
    static func v1Plan(current: [[String: Any]], added: Set<String>, hide: [String], paths: [String: String])
        -> (next: [[String: Any]], extra: [String], own: Int, changed: Bool) {
        let id = { (e: [String: Any]) in e["identifier"] as? String ?? "" }
        let own = current.filter { !added.contains(id($0)) }
        let ownIds = Set(own.map(id))
        var seen = Set<String>()
        let extra = hide.filter { !ownIds.contains($0) && paths[$0] != nil && seen.insert($0).inserted }
        let next = own + extra.map { ["path": paths[$0]!, "identifier": $0] as [String: Any] }
        return (next, extra, own.count, Set(next.map(id)) != Set(current.map(id)))
    }

    // MARK: v2 plan

    /// What the dock did to a v2 row: made it (`created`), turned an enabled row off (`flipped`),
    /// or found it off already, the user's own (`own`, never turned back on).
    enum Mark: String, Codable, Equatable { case created, flipped, own }

    struct V2Plan: Equatable {
        var disable: [String]
        var restore: [String: Mark]
        /// Only a row to write needs Raycast stopped; forgetting an `own` row does not.
        var writes: Bool { !disable.isEmpty || restore.values.contains { $0 != .own } }
    }

    static func v2Plan(managed: [String: Mark], wanted: Set<String>) -> V2Plan {
        V2Plan(disable: wanted.subtracting(managed.keys).sorted(),
               restore: managed.filter { !wanted.contains($0.key) })
    }

    /// The managed rows after the helper answered: a row it turned back on, found gone or found
    /// changed by the user leaves the list; a row it did not reach stays as it was, to try again.
    static func v2Managed(_ managed: [String: Mark], _ plan: V2Plan, results: [String: String]) -> [String: Mark] {
        var m = managed
        for (id, mark) in plan.restore where mark == .own || results[id] != nil { m[id] = nil }
        for id in plan.disable { if let r = results[id], let mark = Mark(rawValue: r) { m[id] = mark } }
        return m
    }

    // MARK: Finding Raycast's data core and a Node to run it

    /// Raycast's own data core: `Contents/Resources/<bundle>/Contents/Resources/backend/data.darwin-<arch>.node`.
    static func dataModule(appPath: String, arch: String) -> String? {
        let res = appPath + "/Contents/Resources"
        let bundles = ((try? FileManager.default.contentsOfDirectory(atPath: res)) ?? []).filter { $0.hasSuffix(".bundle") }.sorted()
        return bundles.map { "\(res)/\($0)/Contents/Resources/backend/data.darwin-\(arch).node" }
            .first { FileManager.default.fileExists(atPath: $0) }
    }

    static var arch: String {
        #if arch(arm64)
        "arm64"
        #else
        "x64"
        #endif
    }

    /// Numeric order of versions such as 22.23.4 and 22.9.0.
    static func versionLess(_ a: String, _ b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l < r }
        }
        return false
    }

    /// Node runtimes in the order tried: Raycast's own, newest first, then the usual installs.
    static func nodeCandidates(supportDir: String, home: String) -> [String] {
        let runtimes = supportDir + "/NodeJS/runtime"
        let own = ((try? FileManager.default.contentsOfDirectory(atPath: runtimes)) ?? [])
            .filter { $0.first?.isNumber == true }.sorted { versionLess($1, $0) }
            .map { "\(runtimes)/\($0)/bin/node" }
        return own + ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/opt/zerobrew/bin/node",
                      home + "/.local/share/fnm/aliases/default/bin/node", home + "/.volta/bin/node"]
    }

    static func node(supportDir: String, home: String) -> String? {
        nodeCandidates(supportDir: supportDir, home: home).first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: The v2 helper

    struct V2Request: Encodable {
        var module: String
        var supportDir: String
        var key: String
        var extensionId = RaycastCore.v2Extension
        var disable: [String]
        var restore: [String: Mark]

        /// An `own` row is the user's and is never sent to be turned back on.
        init(module: String, supportDir: String, key: String, disable: [String], restore: [String: Mark]) {
            (self.module, self.supportDir, self.key, self.disable) = (module, supportDir, key, disable)
            self.restore = restore.filter { $0.value != .own }
        }
    }

    struct V2Report: Decodable {
        var ok: Bool
        var error: String?
        var results: [String: String]?
    }

    /// Runs the helper under `node`: the request, key included, goes on its standard input, never
    /// in its arguments or environment, and the answer is the last line it prints.
    static func runV2Helper(node: String, request: V2Request, timeout: TimeInterval = 30) -> V2Report? {
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("workspace-bar-raycast-v2.cjs")
        guard (try? Data(v2HelperSource.utf8).write(to: script, options: .atomic)) != nil,
              let input = try? JSONEncoder().encode(request) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: node)
        p.arguments = [script.path]
        p.currentDirectoryURL = FileManager.default.temporaryDirectory
        let out = Pipe(), inp = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = inp
        do { try p.run() } catch { return nil }
        inp.fileHandleForWriting.write(input)
        try? inp.fileHandleForWriting.close()
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        let last = String(decoding: data, as: UTF8.self).split(separator: "\n").last { $0.hasPrefix("{") }
        return last.flatMap { try? JSONDecoder().decode(V2Report.self, from: Data($0.utf8)) }
    }

    /// The helper. It opens Raycast's databases with Raycast's own `DatabaseClient`, which aborts
    /// on a key that does not match and then writes nothing, and changes only the rows it is sent.
    static let v2HelperSource = #"""
    'use strict';
    // Anti-Dopamine Bar: turns Raycast v2's app rows off and on through Raycast's own data core.
    const fs = require('fs'), path = require('path');
    const PLAIN = new Set(['id', 'extensionId', 'enabled', 'deviceGenerations', 'updatedAt']);
    const plain = (row) => Object.keys(row).every((k) => PLAIN.has(k) || row[k] == null || (k === 'deviceGenerations' && row[k] === '{}'));
    async function main(req) {
      const sup = req.supportDir;
      for (const f of ['main.db', 'settings_v2.db', 'last_key'])
        if (!fs.existsSync(path.join(sup, f))) return { ok: false, error: `no ${f} in ${sup}` };
      const m = require(req.module);
      if (typeof m.DatabaseClient !== 'function') return { ok: false, error: 'the data core has no DatabaseClient' };
      const notes = [];
      const client = new m.DatabaseClient(sup, req.key, (_t, n) => { if (n && n.level === 'error') notes.push(String(n.message)); }, undefined);
      try {
        const report = client.initReport;
        if (!report || !report.overallSuccess)
          return { ok: false, error: 'Raycast data did not open: ' + ([...((report && report.warnings) || []), ...notes].join('; ') || 'no reason given') };
        const s = client.settings;
        for (const f of ['getCommandSettings', 'addCommandSettings', 'updateCommandSettings', 'deleteCommandSettings'])
          if (!s || typeof s[f] !== 'function') return { ok: false, error: `the settings have no ${f}` };
        const results = {};
        for (const id of req.disable) {
          const row = await s.getCommandSettings(id);
          if (!row) { await s.addCommandSettings({ id, extensionId: req.extensionId, enabled: false }); results[id] = 'created'; }
          else if (row.enabled !== false) { await s.updateCommandSettings(id, { enabled: false }); results[id] = 'flipped'; }
          else results[id] = 'own';
        }
        for (const [id, mark] of Object.entries(req.restore)) {
          if (mark !== 'created' && mark !== 'flipped') continue;
          const row = await s.getCommandSettings(id);
          if (!row) { results[id] = 'gone'; continue; }
          if (row.enabled !== false) { results[id] = 'kept'; continue; }
          if (mark === 'created' && plain(row)) await s.deleteCommandSettings(id);
          else await s.updateCommandSettings(id, { enabled: true });
          results[id] = 'restored';
        }
        return { ok: true, results };
      } finally {
        try { await client.shutdown(); } catch {}
      }
    }
    let input = '';
    process.stdin.setEncoding('utf8');
    process.stdin.on('data', (d) => { input += d; });
    process.stdin.on('end', () => {
      Promise.resolve().then(() => main(JSON.parse(input)))
        .catch((e) => ({ ok: false, error: String((e && e.message) || e) }))
        .then((r) => { process.stdout.write('\n' + JSON.stringify(r) + '\n', () => process.exit(0)); });
    });
    """#
}
