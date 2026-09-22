import Foundation
import Network

/// Lets an assistant on this Mac drive the running app: a TCP listener on the loopback address only, off until the
/// user switches it on (Compositor > Allow Assistant Control), and closed to anything that does not present the
/// token written for it. Each connection sends lines of JSON — {"token", "command", "arguments"} — and gets one
/// line back: {"ok": true, "result": …} or {"ok": false, "error": "…"}.
@MainActor
final class ControlServer {
    static let shared = ControlServer()
    static let enabledKey = "assistantControlEnabled"
    private var listener: NWListener?
    private var token = ""
    private weak var workspace: ProjectWorkspace?

    var isEnabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }
    var isRunning: Bool { listener != nil }

    /// Where the port and token are left for the assistant's tools: the app's own container, which other users
    /// cannot read, and other processes of this user can.
    static var handoff: URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Compositor")
        return folder.appendingPathComponent("control.json")
    }

    func attach(_ workspace: ProjectWorkspace) {
        self.workspace = workspace
        if isEnabled { start() }
    }

    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        if enabled { start() } else { stop() }
    }

    private func start() {
        guard listener == nil else { return }
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters)
            token = UUID().uuidString + UUID().uuidString
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    if case .ready = state, let port = listener.port?.rawValue { self?.announce(port: Int(port)) }
                    if case .failed = state { self?.stop() }
                }
            }
            listener.start(queue: .global(qos: .userInitiated))
            self.listener = listener
        } catch { listener = nil }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        try? FileManager.default.removeItem(at: Self.handoff)
    }

    private func announce(port: Int) {
        let file = Self.handoff
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let body: [String: Any] = ["port": port, "token": token, "pid": ProcessInfo.processInfo.processIdentifier,
                                   "app": Bundle.main.bundleIdentifier ?? "Compositor"]
        if let data = try? JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted]) {
            try? data.write(to: file, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        read(connection, pending: Data())
    }

    /// Requests are whole lines; a render's reply can be megabytes, so nothing here assumes one packet is one message.
    private nonisolated func read(_ connection: NWConnection, pending: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, finished, error in
            guard let self else { connection.cancel(); return }
            var buffer = pending
            if let data { buffer.append(data) }
            guard buffer.count <= 256 << 20 else { connection.cancel(); return }
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<newline)
                buffer = buffer.subdata(in: buffer.index(after: newline)..<buffer.endIndex)
                Task { @MainActor in
                    let reply = await self.respond(to: line)
                    connection.send(content: reply + Data([0x0A]), completion: .contentProcessed { _ in })
                }
            }
            if finished || error != nil { connection.cancel(); return }
            self.read(connection, pending: buffer)
        }
    }

    func respond(to line: Data) async -> Data {
        func reply(_ body: [String: Any]) -> Data { (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{\"ok\":false}".utf8) }
        guard let request = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
            return reply(["ok": false, "error": "requests are one JSON object per line"])
        }
        guard let given = request["token"] as? String, !token.isEmpty, given == token else {
            return reply(["ok": false, "error": "wrong or missing token"])
        }
        guard let workspace else { return reply(["ok": false, "error": "the app is not ready"]) }
        do {
            let result = try await ControlCommands.handle(request["command"] as? String ?? "", request["arguments"] as? [String: Any] ?? [:], in: workspace)
            return reply(["ok": true, "result": result])
        } catch {
            return reply(["ok": false, "error": error.localizedDescription])
        }
    }

    #if DEBUG
    /// For tests: a server that answers without a listener.
    func prepareForTesting(_ workspace: ProjectWorkspace, token: String) { self.workspace = workspace; self.token = token }
    #endif
}
