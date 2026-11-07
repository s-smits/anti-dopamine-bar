import AppKit

/// Your own add-ins, with no change to the dock: every executable file in
/// `~/.config/workspace-bar/hooks/` runs on each mode switch, in name order, with
/// `WB_FROM`, `WB_TO` and `WB_GATED` (1 going into a gated mode such as Socials, else 0) in its
/// environment and the two mode names as arguments. They run in the background and the dock does
/// not wait; what they print goes to `~/Library/Logs/workspace-bar-hooks.log`. The Custom Hooks
/// add-in switches them all off. `example.sh.off` shows the shape and runs only once renamed and
/// made executable.
enum Hooks {
    static let dirURL = dir.appendingPathComponent("hooks")
    static let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/workspace-bar-hooks.log")

    /// The folder, made with its example the first time.
    static func folder() -> URL {
        let fm = FileManager.default
        if !fm.fileExists(atPath: dirURL.path) {
            try? fm.createDirectory(at: dirURL, withIntermediateDirectories: true)
            let example = """
            #!/bin/zsh
            # Runs on every mode switch once renamed to example.sh and made executable (chmod +x).
            # $1 / WB_FROM: the mode left; $2 / WB_TO: the mode now; WB_GATED: 1 going into Socials.
            if [[ $WB_TO == Socials ]]; then
              : # e.g. open -g -a Spotify
            fi
            echo "$(date +%T) $WB_FROM -> $WB_TO"

            """
            try? example.write(to: dirURL.appendingPathComponent("example.sh.off"), atomically: true, encoding: .utf8)
        }
        return dirURL
    }

    /// Only your own: a script (and its folder) owned by you and writable by no one else, as ssh
    /// asks of its keys. Anything else could be swapped for another program by another account.
    static func trusted(_ url: URL) -> Bool {
        for path in [url.path, dirURL.path] {
            var st = stat()
            // stat follows a link: the script it runs is checked, and the folder keeps the link itself.
            guard stat(path, &st) == 0, st.st_uid == getuid(), st.st_mode & (S_IWGRP | S_IWOTH) == 0 else {
                log("hook \(url.lastPathComponent): not run, \(path) is not yours alone (owner, or writable by others)")
                return false
            }
        }
        return true
    }

    static func run(from: String, to: String, gated: Bool) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dirURL.path) else { return }
        let scripts = names.sorted().filter { !$0.hasPrefix(".") }.map { dirURL.appendingPathComponent($0) }
            .filter { url in
                var isDir: ObjCBool = false
                return fm.fileExists(atPath: url.path, isDirectory: &isDir) && !isDir.boolValue
                    && fm.isExecutableFile(atPath: url.path) && trusted(url)
            }
        guard !scripts.isEmpty else { return }
        if !fm.fileExists(atPath: logURL.path) { fm.createFile(atPath: logURL.path, contents: nil) }
        var env = ProcessInfo.processInfo.environment
        env["WB_FROM"] = from
        env["WB_TO"] = to
        env["WB_GATED"] = gated ? "1" : "0"
        for url in scripts {
            let p = Process()
            p.executableURL = url
            p.arguments = [from, to]
            p.environment = env
            p.currentDirectoryURL = dirURL
            if let out = try? FileHandle(forWritingTo: logURL) {
                out.seekToEndOfFile()
                p.standardOutput = out
                p.standardError = out
            }
            let name = url.lastPathComponent
            p.terminationHandler = { p in
                if p.terminationStatus != 0 { log("hook \(name) exited \(p.terminationStatus)") }
            }
            do { try p.run() } catch { log("hook \(name): \(error.localizedDescription)") }
        }
    }
}
