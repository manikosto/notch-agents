import Foundation
import Network

/// Мини HTTP-сервер для хуков Claude Code.
/// POST /hook       — fire-and-forget события (Stop, Notification, ...)
/// POST /permission — long-poll: хук ждёт решения Allow/Deny из нотча
final class HookServer {
    static let port: UInt16 = 48738

    var onEvent: (([String: Any]) -> Void)?
    /// (payload, responder) — responder.send(json) можно вызвать ровно один раз.
    var onPermission: (([String: Any], PermissionResponder) -> Void)?
    /// AskUserQuestion через блокирующий PreToolUse-хук.
    var onQuestion: (([String: Any], PermissionResponder) -> Void)?

    private var listener: NWListener?

    func start() {
        guard let port = NWEndpoint.Port(rawValue: Self.port) else { return }
        do {
            let listener = try NWListener(using: .tcp, on: port)
            listener.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
            listener.start(queue: .global(qos: .utility))
            self.listener = listener
        } catch {
            NSLog("HookServer: не удалось занять порт \(Self.port): \(error)")
        }
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: .global(qos: .utility))
        receive(conn, buffer: Data())
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 128 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { conn.cancel(); return }
            var buf = buffer
            if let data { buf.append(data) }
            if let req = Self.parseRequest(buf) {
                self.route(path: req.path, body: req.body, conn: conn)
            } else if isComplete || error != nil {
                conn.cancel()
            } else {
                self.receive(conn, buffer: buf)
            }
        }
    }

    private func route(path: String, body: Data, conn: NWConnection) {
        let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        let longPoll: (([String: Any], PermissionResponder) -> Void)?
        if path.hasPrefix("/permission") {
            longPoll = onPermission
        } else if path.hasPrefix("/question") {
            longPoll = onQuestion
        } else {
            Self.respond(conn, body: "{}")
            DispatchQueue.main.async { self.onEvent?(obj) }
            return
        }
        let responder = PermissionResponder(conn: conn)
        // страховка: если UI так и не ответит, отпускаем запрос в терминальный диалог
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 50) {
            responder.send("{}")
        }
        DispatchQueue.main.async { longPoll?(obj, responder) }
    }

    static func respond(_ conn: NWConnection, body: String) {
        let payload = body.data(using: .utf8) ?? Data()
        var out = Data()
        out.append("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n".data(using: .utf8)!)
        out.append(payload)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }

    /// Возвращает (путь, тело), когда запрос получен целиком (по Content-Length).
    private static func parseRequest(_ data: Data) -> (path: String, body: Data)? {
        guard let sep = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(data: data[..<sep.lowerBound], encoding: .utf8) ?? ""
        let lines = head.components(separatedBy: "\r\n")
        let requestParts = (lines.first ?? "").components(separatedBy: " ")
        let path = requestParts.count > 1 ? requestParts[1] : "/"
        var length = 0
        for line in lines {
            let l = line.lowercased()
            if l.hasPrefix("content-length:") {
                length = Int(l.dropFirst("content-length:".count)
                    .trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        let body = data[sep.upperBound...]
        guard body.count >= length else { return nil }
        return (path, Data(body.prefix(length)))
    }
}

/// Одноразовый ответчик на long-poll запрос разрешения.
final class PermissionResponder {
    private let conn: NWConnection
    private let lock = NSLock()
    private var responded = false

    init(conn: NWConnection) {
        self.conn = conn
    }

    func send(_ json: String) {
        lock.lock()
        let already = responded
        responded = true
        lock.unlock()
        guard !already else { return }
        HookServer.respond(conn, body: json)
    }
}
