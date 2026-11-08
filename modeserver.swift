import AppKit
import Network

/// Tells the browser extension in `extension/` which mode is current, on 127.0.0.1 only:
/// `GET /mode?browser=brave` answers `{"mode": "Profile 1", "social": false, "sites": [...]}`.
/// `social` is true in a gated mode (Socials) and while the timer is paused; otherwise the extension blocks `sites`, the
/// config's `socialSites` or the list below. Each browser is its own add-in (Brave, Chrome,
/// Firefox): the extension names its browser, and one whose add-in is off is answered as if
/// in Socials, so it blocks nothing. No CORS header, so a web page cannot read the answer, and only
/// a request addressed to 127.0.0.1 or localhost is answered, so a page on a domain made to
/// point at this Mac (DNS rebinding) cannot either; the extension's host permission lets it.
@MainActor
final class ModeServer {
    nonisolated static let port: NWEndpoint.Port = 47391
    static let defaultSites = ["x.com", "twitter.com", "facebook.com", "instagram.com", "threads.net", "threads.com",
                               "tiktok.com", "reddit.com", "linkedin.com", "bsky.app", "web.whatsapp.com",
                               "messenger.com", "snapchat.com", "pinterest.com", "tumblr.com",
                               "youtube.com", "youtu.be"]
    private let model: DockModel
    private var listener: NWListener?
    private var heard: Set<String> = []

    init(model: DockModel) {
        self.model = model
    }

    /// On while any browser add-in is: off, nothing answers and every extension blocks nothing.
    func setEnabled(_ on: Bool) {
        if on, listener == nil { start() }
        if !on, let l = listener { l.cancel(); listener = nil; log("mode server: off") }
    }

    private func start() {
        _ = Self.extensionsFolder()
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: Self.port)
        params.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: params) else { log("mode server: could not listen on \(Self.port)"); return }
        listener.newConnectionHandler = { [weak self] c in
            MainActor.assumeIsolated { self?.serve(c) }
        }
        listener.stateUpdateHandler = { state in
            if case .failed(let e) = state { log("mode server: \(e)") }
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    private func serve(_ c: NWConnection) {
        c.start(queue: .main)
        // A connection that sends nothing is closed after 2 s rather than held open.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { if c.state != .cancelled { c.cancel() } }
        c.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            MainActor.assumeIsolated {
                let req = Request(data.map { String(decoding: $0, as: UTF8.self) } ?? "")
                let ok = req.path == "/mode" && req.localHost
                let body = ok ? (self?.answer(req.browser) ?? "{}") : "not found"
                let head = "HTTP/1.1 \(ok ? "200 OK" : "404 Not Found")\r\nContent-Type: \(ok ? "application/json" : "text/plain")\r\n"
                    + "Cache-Control: no-store\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n"
                c.send(content: Data((head + body).utf8), completion: .contentProcessed { _ in c.cancel() })
            }
        }
    }

    /// The parts of a request the server reads.
    struct Request {
        var path = ""
        var browser = "chrome"
        var localHost = false

        init(_ raw: String) {
            let lines = raw.components(separatedBy: "\r\n")
            let first = lines.first?.split(separator: " ") ?? []
            guard first.count >= 2, first[0] == "GET" else { return }
            let target = URLComponents(string: String(first[1]))
            path = target?.path ?? ""
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            let host = headers["host"] ?? ""
            localHost = ["127.0.0.1", "localhost"].contains { host == $0 || host == "\($0):\(ModeServer.port)" }
            let named = target?.queryItems?.first { $0.name == "browser" }?.value
            let hints = (headers["sec-ch-ua"] ?? "") + " " + (headers["user-agent"] ?? "")
            browser = Self.browser(named: named, hints: hints)
        }

        /// The extension's own word first, then its request headers; any other Chromium browser is Chrome's.
        static func browser(named: String?, hints: String) -> String {
            if let n = named?.lowercased(), AddIns.browsers.contains(where: { $0.name == n }) { return n }
            if hints.contains("Firefox/") { return "firefox" }
            if hints.contains("\"Brave\"") { return "brave" }
            return "chrome"
        }
    }

    private func answer(_ browser: String) -> String {
        if heard.insert(browser).inserted { log("mode server: the \(browser) extension asked") }
        let mode = model.currentMode
        let key = AddIns.browsers.first { $0.name == browser }?.key ?? \.chrome
        let on = model.addIn(key)
        let sites = on ? (model.config.socialSites ?? Self.defaultSites) : []
        var json: [String: Any] = ["mode": mode?.name ?? "", "social": !on || mode?.gate != nil || model.paused, "sites": sites]
        if !on { json["off"] = true }
        return (try? JSONSerialization.data(withJSONObject: json)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    // MARK: The extension's files

    static let extensionsURL = dir.appendingPathComponent("extensions")

    /// `~/.config/workspace-bar/extensions/{chromium,firefox}`, brought up to date from the app's
    /// own copy (`Contents/Resources/extensions`, made by build.sh), a place that outlives a
    /// rebuild of the app for the browsers to load the extension from.
    static func extensionsFolder() -> URL {
        let fm = FileManager.default
        guard let src = Bundle.main.resourceURL?.appendingPathComponent("extensions"),
              let walk = fm.enumerator(at: src, includingPropertiesForKeys: [.isRegularFileKey]) else { return extensionsURL }
        for case let url as URL in walk where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            let rel = url.path.dropFirst(src.path.count + 1)
            let dest = extensionsURL.appendingPathComponent(String(rel))
            guard let data = try? Data(contentsOf: url), (try? Data(contentsOf: dest)) != data else { continue }
            try? fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: dest, options: .atomic)
        }
        return extensionsURL
    }
}
