import Foundation
@testable import VerseVoice

/// Thread-safe box (the tests run on many threads; URLProtocol callbacks are not on the test's).
final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func with<R>(_ body: (inout T) -> R) -> R { lock.lock(); defer { lock.unlock() }; return body(&value) }
}

/// URLProtocol stub: no request leaves the process. Records every request (method, URL, headers, body).
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Captured: Sendable { var request: URLRequest; var body: Data }
    struct Reply: Sendable {
        var status = 200
        var headers: [String: String] = [:]
        var body = Data()
        var delay: TimeInterval = 0
        var failure: URLError.Code? = nil
    }

    static let captured = Locked<[Captured]>([])
    static let handler = Locked<@Sendable (Captured) -> Reply>({ _ in Reply() })

    static func reset(_ h: @escaping @Sendable (Captured) -> Reply = { _ in Reply() }) {
        captured.with { $0 = [] }
        handler.with { $0 = h }
    }

    static func session() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: c)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let req = request
        let body = req.httpBody ?? Self.drain(req.httpBodyStream)
        let cap = Captured(request: req, body: body)
        Self.captured.with { $0.append(cap) }
        let reply = Self.handler.with { $0 }(cap)
        let client = self.client
        DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay) { [weak self] in
            guard let self else { return }
            if let f = reply.failure {
                client?.urlProtocol(self, didFailWithError: URLError(f))
                return
            }
            let resp = HTTPURLResponse(url: req.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: reply.body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}

    private static func drain(_ stream: InputStream?) -> Data {
        guard let stream else { return Data() }
        stream.open(); defer { stream.close() }
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buf, maxLength: buf.count)
            if n <= 0 { break }
            out.append(buf, count: n)
        }
        return out
    }
}

final class LogCollector: @unchecked Sendable {
    private let lines = Locked<[String]>([])
    var sink: @Sendable (String) -> Void { { [lines] line in lines.with { $0.append(line) } } }
    var all: [String] { lines.with { $0 } }
}

final class FakePlayer: AudioPlaying, @unchecked Sendable {
    struct Played: Sendable { var audio: Data; var format: AudioFormat }
    private let state = Locked<(played: [Played], stops: Int)>(([], 0))
    var failure: VoiceError?
    var played: [Played] { state.with { $0.played } }
    var stopCount: Int { state.with { $0.stops } }
    func play(_ audio: Data, format: AudioFormat) async throws {
        if let failure { throw failure }
        state.with { $0.played.append(Played(audio: audio, format: format)) }
    }
    func stop() async { state.with { $0.stops += 1 } }
}

final class FakeEngine: VoiceEngine, @unchecked Sendable {
    let kind: VoiceKind
    var failure: (any Error)?
    private let state = Locked<(spoken: [String], stops: Int)>(([], 0))
    init(_ kind: VoiceKind, failure: (any Error)? = nil) { self.kind = kind; self.failure = failure }
    var spoken: [String] { state.with { $0.spoken } }
    var stopCount: Int { state.with { $0.stops } }
    func speak(_ sentence: String) async throws {
        state.with { $0.spoken.append(sentence) }
        if let failure { throw failure }
    }
    func stop() async { state.with { $0.stops += 1 } }
}

func json(_ data: Data) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
}

/// A dummy that looks like a provider key (letters, digits, - and _), never a real one.
func dummyKey(_ tag: String) -> String { "sk-TESTDUMMY-\(tag)-" + String(repeating: "q", count: 24) + "_7e1d" }
