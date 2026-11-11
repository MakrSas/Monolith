import Foundation

/// vphone's guest agent (vphoned) inside a watch or TV guest: an HTTP API on the guest's vsock port 1339,
/// which the emulator forwards to 127.0.0.1:`port` on this iPhone.
enum GuestAgent {
    static let port = 18339
    private static var base: URL { URL(string: "http://127.0.0.1:\(port)")! }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Once the machine runs. Again later is harmless: the port is already listening, and this says so.
    static func connect() {
        let ok = henge_vm_agent_forward(Int32(port)) == 0
        HengeLog.log("agent", ok ? "guest agent at 127.0.0.1:\(port)" : "guest agent channel already open or unavailable")
    }

    private static func check(_ data: Data, _ response: URLResponse) throws -> [String: Any] {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if let err = json["error"] as? [String: Any] {
            throw Failure(message: err["message"] as? String ?? "The device refused it.")
        }
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw Failure(message: "The device answered \(http.statusCode).")
        }
        return json
    }

    /// One RPC (POST /v1/rpc); nil on any failure.
    static func rpc(_ method: String, _ params: [String: Any] = [:], timeout: TimeInterval = 5) async -> [String: Any]? {
        var request = URLRequest(url: base.appendingPathComponent("v1/rpc"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeout
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["method": method, "params": params])
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let json = try? check(data, response) else { return nil }
        return json["result"] as? [String: Any]
    }

    /// Once a research guest starts: when its agent answers, its first-start setup (a watch's pairing
    /// with an iPhone, a TV's or HomeView's setup) is skipped if it has not been done, as vphone does.
    static func skipSetupWhenUp() async {
        connect()
        for _ in 0 ..< 180 { // up to 15 minutes: a watch's first start is long
            if Task.isCancelled { return }
            if let status = await rpc("setup.status", timeout: 10) {
                let done = (status["setup_done"] as? Bool) ?? false
                if done { HengeLog.log("agent", "setup already done"); return }
                let r = await rpc("setup.skip", ["force": true], timeout: 60)
                HengeLog.log("agent", "setup skipped: \(r.map { "\($0)" } ?? "no answer")")
                if r != nil { return }
            }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
    }

    /// Is the agent up (the guest has booted far enough)?
    static func ready() async -> Bool {
        var request = URLRequest(url: base.appendingPathComponent("v1/apps/foreground"))
        request.timeoutInterval = 5
        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (try? check(data, response)) != nil
    }

    /// Copies an .ipa into the guest and installs it.
    static func install(ipa: URL, progress: @escaping (String) -> Void) async throws {
        connect()
        guard await ready() else { throw Failure(message: "The device's agent is not answering yet. Wait until it has finished starting.") }
        let name = ipa.lastPathComponent.replacingOccurrences(of: " ", with: "_")
        let guestPath = "/var/mobile/Media/Monolith-\(UUID().uuidString.prefix(8))-\(name)"
        progress("Copying \(ipa.lastPathComponent) to the device…")
        var components = URLComponents(url: base.appendingPathComponent("v1/files/content"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "path", value: guestPath)]
        var put = URLRequest(url: components.url!)
        put.httpMethod = "PUT"
        put.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        put.timeoutInterval = 600
        let (pdata, presponse) = try await URLSession.shared.upload(for: put, fromFile: ipa)
        _ = try check(pdata, presponse)
        progress("Installing…")
        var post = URLRequest(url: base.appendingPathComponent("v1/apps/install"))
        post.httpMethod = "POST"
        post.setValue("application/json", forHTTPHeaderField: "Content-Type")
        post.httpBody = try JSONSerialization.data(withJSONObject: ["path": guestPath])
        post.timeoutInterval = 900
        let (idata, iresponse) = try await URLSession.shared.data(for: post)
        _ = try check(idata, iresponse)
        HengeLog.log("agent", "installed \(ipa.lastPathComponent): \(String(data: idata, encoding: .utf8) ?? "")")
        var remove = URLRequest(url: base.appendingPathComponent("v1/files/remove"))
        remove.httpMethod = "POST"
        remove.setValue("application/json", forHTTPHeaderField: "Content-Type")
        remove.httpBody = try? JSONSerialization.data(withJSONObject: ["path": guestPath])
        _ = try? await URLSession.shared.data(for: remove)
    }
}
