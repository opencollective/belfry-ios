import Foundation
import Network

// The outside web as a link preview reaches it (SPEC 19.69, docs/link-previews-v2.md "How the sender
// gets it"): the name resolved once by `SystemResolver`, every address checked by `FetchRules`, then
// a TLS connection made to exactly those addresses (Network.framework: the certificate is still
// checked for the NAME, which is also sent as SNI), so a second lookup can never point the fetch
// somewhere else. One plain HTTP/1.1 GET: no redirect followed, no cookies, no cache, no proxy,
// nothing about the person; at most MAX bytes of the body are kept.

/// The system's resolver (getaddrinfo), off the caller's thread. Empty: unknown.
public struct SystemResolver: PreviewResolver {
    public init() {}
    public func resolve(_ host: String) async -> [String] {
        await withCheckedContinuation { (c: CheckedContinuation<[String], Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: IPPROTO_TCP,
                                     ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
                var res: UnsafeMutablePointer<addrinfo>?
                guard getaddrinfo(host, "443", &hints, &res) == 0, let first = res else { c.resume(returning: []); return }
                defer { freeaddrinfo(first) }
                var out = [String]()
                var p: UnsafeMutablePointer<addrinfo>? = first
                while let a = p {
                    var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(a.pointee.ai_addr, a.pointee.ai_addrlen, &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 {
                        let s = String(cString: buf)
                        if !out.contains(s) { out.append(s) }
                    }
                    p = a.pointee.ai_next
                }
                c.resume(returning: out)
            }
        }
    }
}

public struct PinnedNet: PreviewNet {
    public static let userAgent = "Mozilla/5.0 (compatible; BelfryLinkPreview/1.0)"
    public init() {}

    public func get(_ url: URL, host: String, addresses: [String], accept: String, maxBytes: Int, timeout: TimeInterval) async -> NetAnswer? {
        let deadline = Date().addingTimeInterval(timeout)
        var path = url.path.isEmpty ? "/" : url.path
        if let q = url.query { path += "?" + q }
        // the path as it was written (percent-encoding kept)
        if let c = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            path = (c.percentEncodedPath.isEmpty ? "/" : c.percentEncodedPath) + (c.percentEncodedQuery.map { "?" + $0 } ?? "")
        }
        let request = "GET \(path) HTTP/1.1\r\nHost: \(host)\r\nUser-Agent: \(PinnedNet.userAgent)\r\nAccept: \(accept)\r\n" +
            "Accept-Language: en\r\nAccept-Encoding: identity\r\nConnection: close\r\n\r\n"
        for address in addresses {
            let left = deadline.timeIntervalSinceNow
            if left <= 0 { return nil }
            if let a = await PinnedRequest(address: address, host: host, request: Data(request.utf8), maxBytes: maxBytes).run(timeout: left) { return a }
        }
        return nil
    }
}

/// One request on one connection to ADDRESS (TLS for HOST).
final class PinnedRequest: @unchecked Sendable {
    let address: String
    let host: String
    let request: Data
    let maxBytes: Int
    private var buffer = Data()
    private var done = false
    private let lock = NSLock()
    private var continuation: CheckedContinuation<NetAnswer?, Never>?
    private var connection: NWConnection?

    init(address: String, host: String, request: Data, maxBytes: Int) {
        self.address = address; self.host = host; self.request = request; self.maxBytes = maxBytes
    }

    func run(timeout: TimeInterval) async -> NetAnswer? {
        await withCheckedContinuation { (c: CheckedContinuation<NetAnswer?, Never>) in
            continuation = c
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, host)
            let tcp = NWProtocolTCP.Options()
            tcp.connectionTimeout = max(1, Int(timeout))
            let params = NWParameters(tls: tls, tcp: tcp)
            params.preferNoProxies = true
            let conn = NWConnection(host: NWEndpoint.Host(address), port: 443, using: params)
            connection = conn
            conn.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    conn.send(content: self.request, completion: .contentProcessed { [weak self] err in
                        if err != nil { self?.finish(nil) } else { self?.receive() }
                    })
                case .failed, .cancelled: self.finish(self.answer(final: true))
                case .waiting: self.finish(nil)
                default: break
                }
            }
            conn.start(queue: .global(qos: .userInitiated))
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in self?.finish(nil) }
        }
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, err in
            guard let self else { return }
            if let data { self.lock.lock(); self.buffer.append(data); self.lock.unlock() }
            // enough of the body: stop reading
            if let a = self.answer(final: false) { self.finish(a); return }
            if complete || err != nil { self.finish(self.answer(final: true)); return }
            self.receive()
        }
    }

    private func finish(_ a: NetAnswer?) {
        lock.lock()
        if done { lock.unlock(); return }
        done = true
        let c = continuation
        continuation = nil
        lock.unlock()
        connection?.cancel()
        c?.resume(returning: a)
    }

    /// The answer once it is complete enough: the headers, then a body of Content-Length bytes,
    /// or MAX+1 bytes (overflow), or everything at the end (FINAL); chunked bodies decoded.
    private func answer(final: Bool) -> NetAnswer? {
        lock.lock(); let b = buffer; lock.unlock()
        guard let end = b.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let head = String(data: b[..<end.lowerBound], encoding: .isoLatin1) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2, parts[0].hasPrefix("HTTP/1."), let status = Int(parts[1]) else { return nil }
        var h = [String: String]()
        for l in lines.dropFirst() {
            guard let i = l.firstIndex(of: ":") else { continue }
            let k = l[..<i].trimmingCharacters(in: .whitespaces).lowercased()
            if h[k] == nil { h[k] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces) }
        }
        let length = h["content-length"].flatMap { Int($0) }
        var a = NetAnswer(status: status, location: h["location"], contentType: h["content-type"], contentLength: length)
        if status != 200 { return a }
        var body = Data(b[end.upperBound...])
        if h["transfer-encoding"]?.lowercased().contains("chunked") == true {
            guard let (decoded, complete) = PinnedRequest.dechunk(body) else { return final ? nil : nil }
            body = decoded
            if !complete && !final && body.count <= maxBytes { return nil }
        } else if let length, body.count < length, body.count <= maxBytes, !final {
            return nil
        } else if length == nil, !final, body.count <= maxBytes {
            return nil
        }
        a.overflow = body.count > maxBytes || (length ?? 0) > maxBytes
        a.body = body.prefix(maxBytes)
        return a
    }

    /// A chunked body: the bytes so far and whether the last chunk came; nil when malformed.
    static func dechunk(_ d: Data) -> (Data, Bool)? {
        var out = Data(), i = d.startIndex
        while true {
            guard let lineEnd = d[i...].range(of: Data("\r\n".utf8)) else { return (out, false) }
            guard let line = String(data: d[i..<lineEnd.lowerBound], encoding: .ascii),
                  let size = Int(line.split(separator: ";").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? "", radix: 16) else { return nil }
            if size == 0 { return (out, true) }
            let start = lineEnd.upperBound
            guard d.distance(from: start, to: d.endIndex) >= size else { out.append(d[start...]); return (out, false) }
            let stop = d.index(start, offsetBy: size)
            out.append(d[start..<stop])
            guard d.distance(from: stop, to: d.endIndex) >= 2 else { return (out, false) }
            i = d.index(stop, offsetBy: 2)
        }
    }
}
