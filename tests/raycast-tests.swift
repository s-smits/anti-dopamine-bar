import Foundation
import CryptoKit

// Tests of the Raycast add-in's core (raycastcore.swift), built alone by tests/run.sh. The pure
// parts run everywhere. The end-to-end part runs Raycast 2's own data core on a throwaway support
// folder; it needs a Raycast 2 app (RAYCAST_V2_APP, or /Applications/Raycast.app when that is 2.x)
// and a Node, and is skipped with a note otherwise. Nothing here reads the keychain or touches
// Raycast's real folder.

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var passes = 0

func check(_ ok: Bool, _ what: String, file: String = #fileID, line: Int = #line) {
    if ok { passes += 1 } else { failures += 1; print("FAIL \(what) (line \(line))") }
}

func eq<T: Equatable>(_ a: T, _ b: T, _ what: String, line: Int = #line) {
    check(a == b, "\(what): got \(a), want \(b)", line: line)
}

func sha256hex(_ s: String) -> String { RaycastCore.hex(SHA256.hash(data: Data(s.utf8))) }
func sha512(_ s: String) -> Data { Data(SHA512.hash(data: Data(s.utf8))) }

func tempDir(_ name: String) -> String {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("wb-raycast-tests-\(getpid())/\(name)").path
    try? FileManager.default.removeItem(atPath: d)
    try! FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
    return d
}

func touch(_ path: String, executable: Bool = false) {
    try! FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: path, contents: Data("#!/bin/sh\n".utf8),
                                   attributes: executable ? [.posixPermissions: 0o755] : nil)
}

// MARK: - Which Raycast

func testKind() {
    typealias K = RaycastCore.Kind
    eq(RaycastCore.kind(version: "1.103.2", hasV1Database: true, hasV2Database: false), K.v1, "1.x is v1")
    eq(RaycastCore.kind(version: "1.103.2", hasV1Database: false, hasV2Database: true), K.v1, "the version wins over files")
    eq(RaycastCore.kind(version: "2.11.1.0", hasV1Database: false, hasV2Database: true), K.v2, "2.x is v2")
    eq(RaycastCore.kind(version: "2.0", hasV1Database: true, hasV2Database: false), K.v2, "2.x before its first start is still v2")
    eq(RaycastCore.kind(version: "3.0", hasV1Database: false, hasV2Database: true), K.v2, "a later major is taken as v2")
    eq(RaycastCore.kind(version: nil, hasV1Database: false, hasV2Database: true), K.v2, "no version: settings_v2.db means v2")
    eq(RaycastCore.kind(version: nil, hasV1Database: true, hasV2Database: true), K.v2, "no version: v2 files win (v1's are its backup)")
    eq(RaycastCore.kind(version: nil, hasV1Database: true, hasV2Database: false), K.v1, "no version: raycast-enc.sqlite means v1")
    eq(RaycastCore.kind(version: "beta", hasV1Database: true, hasV2Database: false), K.v1, "an unreadable version falls back to files")
    eq(RaycastCore.kind(version: "0.9", hasV1Database: true, hasV2Database: false), K.v1, "major 0 falls back to files")
    eq(RaycastCore.kind(version: nil, hasV1Database: false, hasV2Database: false), K.none, "nothing installed")
    eq(RaycastCore.kind(version: "", hasV1Database: false, hasV2Database: false), K.none, "empty version, no files")
}

// MARK: - Keys

func testKeys() {
    // The v1 passphrase as the add-in has derived it since it first shipped.
    eq(RaycastCore.passphrase(keychainValue: "abc"), sha256hex("abc" + "yvkwWXzxPPBAqY2tmaKrB*DvYjjMaeEf"), "passphrase is sha256hex(key + salt)")
    eq(RaycastCore.passphrase(keychainValue: "abc").count, 64, "passphrase is 64 hex digits")
    check(RaycastCore.passphrase(keychainValue: "abc").allSatisfy { "0123456789abcdef".contains($0) }, "passphrase is lower-case hex")
    eq(RaycastCore.hex([0, 1, 0xab, 0xff]), "0001abff", "hex")

    let p = RaycastCore.passphrase(keychainValue: "secret")
    check(RaycastCore.matchesLastKey(p, sha512(p)), "last_key is sha512 of the passphrase")
    check(!RaycastCore.matchesLastKey(p, sha512(p + "x")), "another key does not match")
    check(!RaycastCore.matchesLastKey(p, Data(sha512(p).prefix(32))), "a short last_key never matches")
    check(!RaycastCore.matchesLastKey(p, Data()), "an empty last_key never matches")

    // The vector from Raycast 2.11.1's own data core: it wrote this last_key for this passphrase.
    let core = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    eq(RaycastCore.hex(sha512(core)).prefix(16), "ad2981aa58beca63", "matches the last_key Raycast 2 wrote")

    eq(RaycastCore.v2Passphrase(keychainValues: ["wrong", "secret"], lastKey: sha512(p)), p, "derived key found after a wrong one")
    eq(RaycastCore.v2Passphrase(keychainValues: [p], lastKey: sha512(p)), p, "a value that is already the passphrase")
    eq(RaycastCore.v2Passphrase(keychainValues: ["", "nope"], lastKey: sha512(p)), nil, "no match gives nil")
    eq(RaycastCore.v2Passphrase(keychainValues: [], lastKey: sha512(p)), nil, "no values gives nil")
    eq(RaycastCore.v2Passphrase(keychainValues: [""], lastKey: sha512("")), nil, "an empty value is never a key")
    let services = Set(RaycastCore.v2KeychainItems.map(\.service)), accounts = Set(RaycastCore.v2KeychainItems.map(\.account))
    check(services.isSuperset(of: ["com.raycast.macos", "Raycast"]), "keychain services include Raycast's")
    check(accounts == ["database_key", "database_key_backup"], "keychain accounts are the key and its backup")
    eq(RaycastCore.v2KeychainItems.first?.account, "database_key_backup", "the backup, readable outside Raycast's group, is tried first")
}

// MARK: - v2 ids

func testIds() {
    eq(RaycastCore.v2Path("/System/Volumes/Data/Applications/WhatsApp.app"), "/Applications/WhatsApp.app", "data volume stripped")
    eq(RaycastCore.v2Path("/Applications/WhatsApp.app/"), "/Applications/WhatsApp.app", "trailing slash stripped")
    eq(RaycastCore.v2Path("/Applications/WhatsApp.app//"), "/Applications/WhatsApp.app", "trailing slashes stripped")
    eq(RaycastCore.v2Path("/System/Applications/Mail.app"), "/System/Applications/Mail.app", "system apps unchanged")
    eq(RaycastCore.v2Path("/System/Volumes/Data"), "/System/Volumes/Data", "the bare volume is not a prefix")
    eq(RaycastCore.v2Path("/System/Volumes/DataX/A.app"), "/System/Volumes/DataX/A.app", "only the exact volume is stripped")
    eq(RaycastCore.v2Path("/Users/me/Applications/Discord.app"), "/Users/me/Applications/Discord.app", "home apps unchanged")
    eq(RaycastCore.v2Path("/"), "/", "root stays")
    eq(RaycastCore.v2CommandId(appPath: "/System/Volumes/Data/Applications/WhatsApp.app"),
       "c:r:applications::*::application::=::/Applications/WhatsApp.app", "the id Raycast 2's importer writes")
    eq(RaycastCore.v2CommandId(appPath: "/Applications/Slack.app"), "c:r:applications::*::application::=::/Applications/Slack.app", "plain path")
    eq(RaycastCore.v2CommandId(appPath: "/Applications/It's ü.app"), "c:r:applications::*::application::=::/Applications/It's ü.app", "quotes and accents kept")
    check(RaycastCore.v2CommandId(appPath: "/A.app").hasPrefix(RaycastCore.v2AppCommand + "::=::"), "instance separator")
    check(RaycastCore.v2AppCommand.hasPrefix("c:r:applications::"), "command belongs to the applications extension")
    eq(RaycastCore.v2Extension, "e:r:applications", "extension id")
}

// MARK: - v1 plan

func ids(_ l: [[String: Any]]) -> [String] { l.map { $0["identifier"] as? String ?? "?" } }

func testV1Plan() {
    let mine: [String: Any] = ["identifier": "com.me.Own", "path": "/Applications/Own.app", "extra": 1]
    let theirs: [String: Any] = ["identifier": "net.whatsapp.WhatsApp", "path": "/x/WhatsApp.app"]
    let paths = ["net.whatsapp.WhatsApp": "/System/Volumes/Data/Applications/WhatsApp.app", "com.hnc.Discord": "/System/Volumes/Data/Applications/Discord.app"]

    var p = RaycastCore.v1Plan(current: [mine], added: [], hide: ["net.whatsapp.WhatsApp", "com.hnc.Discord"], paths: paths)
    eq(ids(p.next), ["com.me.Own", "net.whatsapp.WhatsApp", "com.hnc.Discord"], "hide adds after the user's own")
    eq(p.extra, ["net.whatsapp.WhatsApp", "com.hnc.Discord"], "extra is what the dock added")
    eq(p.own, 1, "one own")
    check(p.changed, "a change")
    eq(p.next[0]["extra"] as? Int, 1, "own entries are kept whole")
    eq(p.next[1]["path"] as? String, "/System/Volumes/Data/Applications/WhatsApp.app", "path from the index")

    p = RaycastCore.v1Plan(current: [mine, theirs], added: ["net.whatsapp.WhatsApp"], hide: [], paths: [:])
    eq(ids(p.next), ["com.me.Own"], "back in Socials: only the user's own stay")
    eq(p.extra, [], "nothing added")
    check(p.changed, "removing is a change")

    p = RaycastCore.v1Plan(current: [mine, theirs], added: ["net.whatsapp.WhatsApp"], hide: ["net.whatsapp.WhatsApp"], paths: paths)
    check(!p.changed, "same set: no restart")
    eq(p.extra, ["net.whatsapp.WhatsApp"], "still managed")

    p = RaycastCore.v1Plan(current: [theirs], added: [], hide: ["net.whatsapp.WhatsApp"], paths: paths)
    eq(p.extra, [], "an app the user disabled is never taken as the dock's")
    eq(p.own, 1, "and counts as own")
    check(!p.changed, "already disabled: no change")

    p = RaycastCore.v1Plan(current: [], added: [], hide: ["com.not.Installed"], paths: paths)
    eq(p.extra, [], "an app with no path is skipped")
    check(!p.changed, "nothing to do")

    p = RaycastCore.v1Plan(current: [], added: [], hide: ["com.hnc.Discord", "com.hnc.Discord"], paths: paths)
    eq(ids(p.next), ["com.hnc.Discord"], "duplicates in the config are added once")

    p = RaycastCore.v1Plan(current: [], added: ["com.gone.App"], hide: [], paths: [:])
    check(!p.changed, "a managed id no longer in Raycast's list is no change")
    eq(p.extra, [], "and is forgotten")
}

// MARK: - v2 plan

func testV2Plan() {
    typealias M = RaycastCore.Mark
    let a = "c:r:applications::*::application::=::/Applications/A.app"
    let b = "c:r:applications::*::application::=::/Applications/B.app"
    let c = "c:r:applications::*::application::=::/Applications/C.app"

    var plan = RaycastCore.v2Plan(managed: [:], wanted: [b, a])
    eq(plan.disable, [a, b], "all wanted, sorted")
    eq(plan.restore, [:], "nothing to restore")
    check(plan.writes, "writes")

    var m = RaycastCore.v2Managed([:], plan, results: [a: "created", b: "own"])
    eq(m, [a: .created, b: .own], "marks from the helper")

    plan = RaycastCore.v2Plan(managed: m, wanted: [a, b])
    check(!plan.writes, "same wanted: nothing to write, no restart")
    eq(plan.disable, [], "none")

    plan = RaycastCore.v2Plan(managed: m, wanted: [])
    eq(plan.restore, [a: .created, b: .own], "leaving: restore all")
    check(plan.writes, "a created row to restore writes")
    m = RaycastCore.v2Managed(m, plan, results: [a: "restored"])
    eq(m, [:], "restored and own both leave the list")

    plan = RaycastCore.v2Plan(managed: [b: .own], wanted: [])
    check(!plan.writes, "forgetting an own row needs no restart")
    eq(RaycastCore.v2Managed([b: .own], plan, results: [:]), [:], "and is forgotten")

    plan = RaycastCore.v2Plan(managed: [a: .flipped, c: .created], wanted: [b, c])
    eq(plan.disable, [b], "only new rows disabled")
    eq(plan.restore, [a: .flipped], "only rows no longer wanted restored")
    m = RaycastCore.v2Managed([a: .flipped, c: .created], plan, results: [b: "flipped"])
    eq(m, [a: .flipped, b: .flipped, c: .created], "a restore the helper did not reach stays, to try again")

    m = RaycastCore.v2Managed([a: .flipped], RaycastCore.V2Plan(disable: [b], restore: [a: .flipped]), results: [a: "kept", b: "bogus"])
    eq(m, [:], "kept leaves the list; an unknown answer adds nothing")
    m = RaycastCore.v2Managed([a: .created], RaycastCore.V2Plan(disable: [], restore: [a: .created]), results: [a: "gone"])
    eq(m, [:], "gone leaves the list")
    m = RaycastCore.v2Managed([:], RaycastCore.V2Plan(disable: [a], restore: [:]), results: [:])
    eq(m, [:], "a failed helper adds nothing")

    // The marks round-trip through raycast-v2.json.
    let json = try! JSONEncoder().encode([a: M.created, b: M.own])
    eq(try! JSONDecoder().decode([String: M].self, from: json), [a: .created, b: .own], "marks round-trip")
}

// MARK: - Finding things

func testFinding() {
    check(RaycastCore.versionLess("22.9.0", "22.23.4"), "numeric version order")
    check(!RaycastCore.versionLess("22.23.4", "22.9.0"), "and not the other way")
    check(RaycastCore.versionLess("8", "22.0.1"), "single component")
    check(!RaycastCore.versionLess("1.0", "1"), "1.0 is not below 1")
    check(!RaycastCore.versionLess("1", "1.0"), "1 is not below 1.0")

    let sup = tempDir("support")
    for v in ["22.9.0", "22.23.4", "8.1.0"] { touch("\(sup)/NodeJS/runtime/\(v)/bin/node", executable: true) }
    touch("\(sup)/NodeJS/runtime/current/bin/node", executable: true)
    let c = RaycastCore.nodeCandidates(supportDir: sup, home: "/h")
    eq(Array(c.prefix(3)), ["22.23.4", "22.9.0", "8.1.0"].map { "\(sup)/NodeJS/runtime/\($0)/bin/node" }, "Raycast's own Node first, newest first")
    check(!c.contains { $0.contains("/current/") }, "non-version folders skipped")
    check(c.contains("/h/.local/share/fnm/aliases/default/bin/node"), "fnm default is a fallback")
    eq(RaycastCore.node(supportDir: sup, home: "/h"), "\(sup)/NodeJS/runtime/22.23.4/bin/node", "picks the newest executable")
    try! FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: "\(sup)/NodeJS/runtime/22.23.4/bin/node")
    eq(RaycastCore.node(supportDir: sup, home: "/h"), "\(sup)/NodeJS/runtime/22.9.0/bin/node", "skips one that cannot run")
    eq(RaycastCore.nodeCandidates(supportDir: "/nonexistent", home: "/h").first, "/opt/homebrew/bin/node", "no Raycast Node: system ones")

    let app = tempDir("Raycast.app")
    eq(RaycastCore.dataModule(appPath: app, arch: "arm64"), nil, "no data core in an empty app")
    touch("\(app)/Contents/Resources/macos-app_RaycastDesktopApp.bundle/Contents/Resources/backend/data.darwin-x64.node")
    eq(RaycastCore.dataModule(appPath: app, arch: "arm64"), nil, "the other arch is not taken")
    touch("\(app)/Contents/Resources/Renamed.bundle/Contents/Resources/backend/data.darwin-arm64.node")
    eq(RaycastCore.dataModule(appPath: app, arch: "arm64"), "\(app)/Contents/Resources/Renamed.bundle/Contents/Resources/backend/data.darwin-arm64.node", "found in any resource bundle")
    eq(RaycastCore.dataModule(appPath: app, arch: "x64"), "\(app)/Contents/Resources/macos-app_RaycastDesktopApp.bundle/Contents/Resources/backend/data.darwin-x64.node", "x64 too")

    // The request carries what the helper reads, the marks as words.
    let req = RaycastCore.V2Request(module: "/m.node", supportDir: "/s", key: "k", disable: ["x"], restore: ["y": .flipped])
    let obj = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(req)) as! [String: Any]
    eq(Set(obj.keys), ["module", "supportDir", "key", "extensionId", "disable", "restore"], "request keys")
    eq(obj["extensionId"] as? String, "e:r:applications", "extension id sent")
    eq((obj["restore"] as? [String: String])?["y"], "flipped", "mark as a word")
    let mixed = RaycastCore.V2Request(module: "/m", supportDir: "/s", key: "k", disable: [], restore: ["a": .own, "b": .created])
    eq(mixed.restore, ["b": .created], "the user's own rows are never sent to be turned on")
    eq(try? JSONDecoder().decode(RaycastCore.V2Report.self, from: Data(#"{"ok":false,"error":"e"}"#.utf8)).error, "e", "report without results")
}

// MARK: - End to end, with Raycast 2's own data core

/// Runs a small script under `node` with JSON on its standard input; returns its last JSON line.
func js(_ node: String, _ source: String, _ input: Any) -> Any? {
    let f = FileManager.default.temporaryDirectory.appendingPathComponent("wb-raycast-tests-\(getpid())/t.cjs")
    try! Data(source.utf8).write(to: f)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: node)
    p.arguments = [f.path]
    let out = Pipe(), inp = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    p.standardInput = inp
    try! p.run()
    inp.fileHandleForWriting.write(try! JSONSerialization.data(withJSONObject: input))
    try? inp.fileHandleForWriting.close()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard let last = String(decoding: data, as: UTF8.self).split(separator: "\n").last(where: { $0.hasPrefix("{") || $0.hasPrefix("[") }) else { return nil }
    return try? JSONSerialization.jsonObject(with: Data(last.utf8))
}

/// Opens the folder with the data core and runs `body` (a function of the settings repository).
let harness = #"""
let input = ''; process.stdin.on('data', (d) => input += d).on('end', async () => {
  const q = JSON.parse(input); const m = require(q.module);
  const c = new m.DatabaseClient(q.dir, q.key, () => {}, undefined);
  let r;
  try { r = c.initReport.overallSuccess ? await (BODY)(c.settings, q) : { failed: c.initReport.warnings }; }
  finally { try { await c.shutdown(); } catch {} }
  process.stdout.write('\n' + JSON.stringify(r) + '\n', () => process.exit(0));
});
"""#

func withBody(_ body: String) -> String { harness.replacingOccurrences(of: "BODY", with: body) }

func testEndToEnd() {
    let env = ProcessInfo.processInfo.environment
    var app = env["RAYCAST_V2_APP"]
    if app == nil, let v = NSDictionary(contentsOfFile: "/Applications/Raycast.app/Contents/Info.plist")?["CFBundleShortVersionString"] as? String,
       RaycastCore.kind(version: v, hasV1Database: false, hasV2Database: false) == .v2 { app = "/Applications/Raycast.app" }
    guard let app else { print("skip end to end: no Raycast 2 (set RAYCAST_V2_APP to a Raycast 2 app, e.g. from its dmg)"); return }
    guard let module = RaycastCore.dataModule(appPath: app, arch: RaycastCore.arch) else { failures += 1; print("FAIL no data core in \(app)"); return }
    let realSupport = NSHomeDirectory() + "/Library/Application Support/com.raycast.macos"
    guard let node = env["NODE"] ?? RaycastCore.node(supportDir: realSupport, home: NSHomeDirectory()) else { print("skip end to end: no Node"); return }
    print("end to end: \(module)\n  node \(node)")

    // A support folder as Raycast 2 makes it on first start, on a key from a fake keychain value.
    let sup = tempDir("v2-support")
    let key = RaycastCore.passphrase(keychainValue: "test keychain value")
    let made = js(node, withBody("async (s) => ({ ok: true })"), ["module": module, "dir": sup, "key": key]) as? [String: Any]
    eq(made?["ok"] as? Bool, true, "data core made a support folder")
    for f in ["main.db", "settings_v2.db", "last_key"] { check(FileManager.default.fileExists(atPath: "\(sup)/\(f)"), "\(f) made") }
    guard let lastKey = FileManager.default.contents(atPath: "\(sup)/last_key") else { return }
    eq(lastKey.count, 64, "last_key is 64 bytes")
    check(RaycastCore.matchesLastKey(key, lastKey), "our last_key reading agrees with the data core")
    eq(RaycastCore.v2Passphrase(keychainValues: ["other", "test keychain value"], lastKey: lastKey), key, "key found from keychain values")

    let own = RaycastCore.v2CommandId(appPath: "/Applications/Own.app")
    let flip = RaycastCore.v2CommandId(appPath: "/System/Volumes/Data/Applications/Flip.app")
    let new = RaycastCore.v2CommandId(appPath: "/Applications/New.app")
    let back = RaycastCore.v2CommandId(appPath: "/Applications/Back.app")
    // The user disabled Own themselves; Flip has an alias and is enabled.
    _ = js(node, withBody("""
    async (s, q) => { await s.addCommandSettings({ id: q.own, extensionId: 'e:r:applications', enabled: false });
      await s.addCommandSettings({ id: q.flip, extensionId: 'e:r:applications', enabled: true, alias: 'fl' }); return {}; }
    """), ["module": module, "dir": sup, "key": key, "own": own, "flip": flip])
    let read = withBody("async (s) => Object.fromEntries((await s.allCommandSettingsForExtension('e:r:applications')).map((r) => [r.id, r]))")
    func rows() -> [String: [String: Any]] { (js(node, read, ["module": module, "dir": sup, "key": key]) as? [String: [String: Any]]) ?? [:] }
    eq(rows().count, 2, "seeded two rows")

    // Outside Socials: hide Own, Flip, New and Back.
    var plan = RaycastCore.v2Plan(managed: [:], wanted: [own, flip, new, back])
    let t0 = Date()
    var r = RaycastCore.runV2Helper(node: node, request: .init(module: module, supportDir: sup, key: key, disable: plan.disable, restore: plan.restore))
    print("  helper took \(String(format: "%.2f", Date().timeIntervalSince(t0))) s")
    eq(r?.ok, true, "helper ok: \(r?.error ?? "")")
    eq(r?.results ?? [:], [own: "own", flip: "flipped", new: "created", back: "created"], "helper results")
    var managed = RaycastCore.v2Managed([:], plan, results: r?.results ?? [:])
    eq(managed, [own: .own, flip: .flipped, new: .created, back: .created], "managed after hiding")
    var now = rows()
    eq(Set(now.keys), [own, flip, new, back], "a row for each")
    check(now.values.allSatisfy { $0["enabled"] as? Bool == false }, "all disabled")
    eq(now[flip]?["alias"] as? String, "fl", "flip keeps its alias")
    eq(now[new]?["extensionId"] as? String, "e:r:applications", "new row under the applications extension")
    check((now[new]?["updatedAt"] as? String)?.hasSuffix("Z") == true, "the data core stamps updatedAt")

    // Same mode again: nothing to write.
    check(!RaycastCore.v2Plan(managed: managed, wanted: [own, flip, new, back]).writes, "no second write")

    // The user turns Back on again in Raycast while hidden; then into Socials.
    _ = js(node, withBody("async (s, q) => { await s.updateCommandSettings(q.back, { enabled: true }); return {}; }"),
           ["module": module, "dir": sup, "key": key, "back": back])
    plan = RaycastCore.v2Plan(managed: managed, wanted: [])
    eq(plan.restore, [own: .own, flip: .flipped, new: .created, back: .created], "restore plan")
    r = RaycastCore.runV2Helper(node: node, request: .init(module: module, supportDir: sup, key: key, disable: plan.disable, restore: plan.restore))
    eq(r?.ok, true, "restore ok: \(r?.error ?? "")")
    eq(r?.results ?? [:], [flip: "restored", new: "restored", back: "kept"], "restore results (own never sent)")
    managed = RaycastCore.v2Managed(managed, plan, results: r?.results ?? [:])
    eq(managed, [:], "nothing managed in Socials")
    now = rows()
    eq(now[own]?["enabled"] as? Bool, false, "the user's own stays disabled")
    eq(now[flip]?["enabled"] as? Bool, true, "flip enabled again")
    eq(now[flip]?["alias"] as? String, "fl", "with its alias")
    check(now[new] == nil, "the row the dock made is gone")
    eq(now[back]?["enabled"] as? Bool, true, "the user's change kept")

    // A created row the user gave an alias is turned on, not deleted.
    plan = RaycastCore.v2Plan(managed: [:], wanted: [new])
    r = RaycastCore.runV2Helper(node: node, request: .init(module: module, supportDir: sup, key: key, disable: plan.disable, restore: plan.restore))
    eq(r?.results?[new], "created", "new made again")
    _ = js(node, withBody("async (s, q) => { await s.updateCommandSettings(q.new, { alias: 'nw' }); return {}; }"),
           ["module": module, "dir": sup, "key": key, "new": new])
    r = RaycastCore.runV2Helper(node: node, request: .init(module: module, supportDir: sup, key: key, disable: [], restore: [new: .created]))
    eq(r?.results?[new], "restored", "restored")
    now = rows()
    eq(now[new]?["enabled"] as? Bool, true, "kept as an enabled row")
    eq(now[new]?["alias"] as? String, "nw", "with the user's alias")

    // A wrong key: the data core refuses, the helper says so, and nothing changes.
    let before = rows()
    let files = { (try? FileManager.default.contentsOfDirectory(atPath: sup))?.sorted() ?? [] }
    let filesBefore = files()
    r = RaycastCore.runV2Helper(node: node, request: .init(module: module, supportDir: sup, key: RaycastCore.passphrase(keychainValue: "wrong"), disable: [own, flip], restore: [:]))
    eq(r?.ok, false, "wrong key refused")
    check(r?.error?.contains("did not open") == true, "and says why: \(r?.error ?? "")")
    eq(files(), filesBefore, "no file made or removed")
    eq(FileManager.default.contents(atPath: "\(sup)/last_key"), lastKey, "last_key unchanged")
    eq(rows().mapValues { $0["enabled"] as? Bool }, before.mapValues { $0["enabled"] as? Bool }, "no row changed")

    // A folder that is not Raycast 2's: the helper makes nothing.
    let empty = tempDir("v2-empty")
    r = RaycastCore.runV2Helper(node: node, request: .init(module: module, supportDir: empty, key: key, disable: [own], restore: [:]))
    eq(r?.ok, false, "an empty folder is refused")
    eq((try? FileManager.default.contentsOfDirectory(atPath: empty)) ?? ["?"], [], "and stays empty")

    // A data core that is not one: an error, not a crash.
    let bogus = tempDir("bogus") + "/data.node"
    touch(bogus)
    r = RaycastCore.runV2Helper(node: node, request: .init(module: bogus, supportDir: sup, key: key, disable: [own], restore: [:]))
    eq(r?.ok, false, "a bad module is reported")

    // A helper that hangs is stopped at its deadline.
    let hang = tempDir("hang") + "/node"
    FileManager.default.createFile(atPath: hang, contents: Data("#!/bin/sh\nexec sleep 30\n".utf8), attributes: [.posixPermissions: 0o755])
    let t1 = Date()
    r = RaycastCore.runV2Helper(node: hang, request: .init(module: module, supportDir: sup, key: key, disable: [], restore: [:]), timeout: 1)
    check(r == nil && Date().timeIntervalSince(t1) < 10, "a hung helper is stopped")
}

@main
struct Tests {
    static func main() {
        if CommandLine.arguments.contains("--helper") { print(RaycastCore.v2HelperSource); return }
        testKind()
        testKeys()
        testIds()
        testV1Plan()
        testV2Plan()
        testFinding()
        testEndToEnd()
        try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent("wb-raycast-tests-\(getpid())"))
        print("\(passes) passed, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
