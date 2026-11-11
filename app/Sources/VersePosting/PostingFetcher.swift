import Foundation
import Darwin

extension PostingFetcher {
    public static func fetch(_ url: URL, session: URLSession = .shared) async throws -> Posting {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", let host = url.host?.lowercased() else {
            throw PostingError.unreadable
        }
        let parts = url.path.split(separator: "/").map(String.init)

        if host == "linkedin.com" || host.hasSuffix(".linkedin.com"), let id = linkedInID(url, parts) {
            return try await linkedIn(id: id, original: url, session: session)
        }
        if host == "jobs.ashbyhq.com", parts.count >= 2 {
            return try await ashby(org: parts[0], id: parts[1], original: url, session: session)
        }
        if host.hasSuffix("greenhouse.io"), let ji = parts.firstIndex(of: "jobs"), ji >= 1, parts.count > ji + 1,
           parts[ji + 1].allSatisfy(\.isNumber) {
            return try await greenhouse(org: parts[0], id: parts[ji + 1], original: url, session: session)
        }
        if host.hasPrefix("jobs.") && host.hasSuffix("lever.co"), parts.count >= 2 {
            let api = host.contains(".eu.") ? "api.eu.lever.co" : "api.lever.co"
            return try await lever(apiHost: api, org: parts[0], id: parts[1], original: url, session: session)
        }
        return try await page(url, session: session)
    }

    public static func pasted(_ text: String) -> Posting {
        let clean = HTMLText.normalise(text)
        let firstLine = clean.split(separator: "\n").first.map(String.init) ?? ""
        return Posting(url: nil, title: String(firstLine.prefix(120)), company: nil, text: clean, source: .pasted)
    }

    // MARK: transport

    /// The most of a response body that is read; the rest is never downloaded.
    static let maxBodyBytes = 3_000_000

    static func get(_ url: URL, session: URLSession, accept: String = "*/*") async throws -> Data {
        guard isFetchable(url) else { throw PostingError.unreadable }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
                     forHTTPHeaderField: "User-Agent")
        req.setValue(accept, forHTTPHeaderField: "Accept")
        req.setValue("en-US,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        do {
            let (bytes, resp) = try await session.bytes(for: req, delegate: RedirectGuard())
            if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw PostingError.unreadable }
            // Stop at the cap instead of downloading the whole body first; leaving the loop cancels the transfer.
            var data = Data()
            for try await b in bytes {
                data.append(b)
                if data.count >= maxBodyBytes { break }
            }
            return data
        } catch let e as PostingError {
            throw e
        } catch is CancellationError {
            throw CancellationError()
        } catch let e as URLError where e.code == .cancelled {
            throw CancellationError()
        } catch {
            throw PostingError.network
        }
    }

    // MARK: address safety

    /// http(s) to a host that is not loopback, link-local, private or a local name.
    static func isFetchable(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", let host = url.host else { return false }
        return !isBlockedHost(host)
    }

    /// True for hosts a job posting must never be fetched from: localhost and local names, single-label names, and IP
    /// literals in loopback, link-local, private, unique-local, carrier-grade NAT, multicast and reserved ranges (every
    /// legacy IPv4 spelling too: `2130706433`, `0x7f.1`, `127.1`). A pure check on the host text; it does not resolve names.
    static func isBlockedHost(_ rawHost: String) -> Bool {
        var host = rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if let pct = host.firstIndex(of: "%") { host = String(host[..<pct]) }
        while host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty else { return true }

        if host.contains(":") {
            var a6 = in6_addr()
            guard inet_pton(AF_INET6, host, &a6) == 1 else { return true }
            return isBlockedIPv6(a6)
        }
        if host.unicodeScalars.allSatisfy({ "0123456789abcdefx.".unicodeScalars.contains($0) }), host.contains(where: \.isNumber) {
            var a4 = in_addr()
            if inet_aton(host, &a4) == 1 { return isBlockedIPv4(UInt32(bigEndian: a4.s_addr)) }
        }
        if !host.contains(".") { return true }
        for suffix in [".localhost", ".local", ".internal", ".localdomain", ".lan", ".home.arpa", ".intranet"] where host.hasSuffix(suffix) {
            return true
        }
        return false
    }

    private static func isBlockedIPv4(_ ip: UInt32) -> Bool {
        let a = ip >> 24, b = (ip >> 16) & 0xFF, c = (ip >> 8) & 0xFF
        switch (a, b, c) {
        case (0, _, _), (10, _, _), (127, _, _): return true
        case (100, 64...127, _): return true                    // carrier-grade NAT
        case (169, 254, _): return true                         // link-local, cloud metadata
        case (172, 16...31, _): return true
        case (192, 0, 0), (192, 168, _): return true
        case (198, 18...19, _): return true                     // benchmarking
        case (224...255, _, _): return true                     // multicast, reserved, broadcast
        default: return false
        }
    }

    private static func isBlockedIPv6(_ addr: in6_addr) -> Bool {
        let b = withUnsafeBytes(of: addr) { Array($0) }
        guard b.count == 16 else { return true }
        if b.dropLast().allSatisfy({ $0 == 0 }) && b[15] <= 1 { return true }            // :: and ::1
        if b[0] == 0xFE && (b[1] & 0xC0) == 0x80 { return true }                          // fe80::/10 link-local
        if (b[0] & 0xFE) == 0xFC { return true }                                          // fc00::/7 unique local
        if b[0] == 0xFF { return true }                                                   // multicast
        let embedded = (UInt32(b[12]) << 24) | (UInt32(b[13]) << 16) | (UInt32(b[14]) << 8) | UInt32(b[15])
        if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xFF && b[11] == 0xFF { return isBlockedIPv4(embedded) }   // ::ffff:a.b.c.d
        if b[0..<12].elementsEqual([0x00, 0x64, 0xFF, 0x9B, 0, 0, 0, 0, 0, 0, 0, 0]) { return isBlockedIPv4(embedded) } // 64:ff9b::/96
        if b[0..<12].allSatisfy({ $0 == 0 }) { return isBlockedIPv4(embedded) }           // ::a.b.c.d (deprecated)
        return false
    }

    /// Refuses a redirect to a blocked address or a non-http(s) scheme (the 3xx answer then reads as unreadable).
    private final class RedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            guard let url = request.url, PostingFetcher.isFetchable(url) else { completionHandler(nil); return }
            completionHandler(request)
        }
    }

    static func string(_ data: Data) -> String {
        let capped = data.prefix(maxBodyBytes)
        return String(data: capped, encoding: .utf8) ?? String(decoding: capped, as: UTF8.self)
    }

    static func json(_ data: Data) throws -> Any {
        do { return try JSONSerialization.jsonObject(with: data) } catch { throw PostingError.unreadable }
    }

    static func prettify(slug: String) -> String {
        slug.split(whereSeparator: { $0 == "-" || $0 == "_" })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    static func make(_ source: PostingSource, url: URL, title: String?, company: String?, text: String) throws -> Posting {
        let t = HTMLText.normalise(text)
        let title = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !title.isEmpty else { throw PostingError.unreadable }
        let co = company?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Posting(url: url, title: title, company: (co?.isEmpty ?? true) ? nil : co, text: t, source: source)
    }

    // MARK: LinkedIn

    static func linkedInID(_ url: URL, _ parts: [String]) -> String? {
        if let vi = parts.firstIndex(of: "view"), vi >= 1, parts[vi - 1] == "jobs", parts.count > vi + 1 {
            return HTMLText.capture(parts[vi + 1], "(?:^|-)(\\d{6,})$")
        }
        if let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
           let v = items.first(where: { $0.name == "currentJobId" })?.value, v.allSatisfy(\.isNumber), !v.isEmpty {
            return v
        }
        return nil
    }

    static func linkedIn(id: String, original: URL, session: URLSession) async throws -> Posting {
        let api = URL(string: "https://www.linkedin.com/jobs-guest/jobs/api/jobPosting/\(id)")!
        let html = string(try await get(api, session: session, accept: "text/html"))
        let title = HTMLText.capture(html, "<h2[^>]*class=\"[^\"]*topcard__title[^\"]*\"[^>]*>(.*?)</h2>")
            .map { HTMLText.plain($0) }
        let company = HTMLText.capture(html, "class=\"[^\"]*topcard__org-name-link[^\"]*\"[^>]*>(.*?)</a>").map { HTMLText.plain($0) }
            ?? HTMLText.capture(html, "class=\"[^\"]*topcard__flavor[^\"]*\"[^>]*>(.*?)</span>").map { HTMLText.plain($0) }
        let body = HTMLText.capture(html, "class=\"[^\"]*show-more-less-html__markup[^\"]*\"[^>]*>(.*?)</div>")
            ?? HTMLText.capture(html, "class=\"[^\"]*description__text[^\"]*\"[^>]*>(.*?)</section>")
        guard let body else { throw PostingError.unreadable }
        return try make(.linkedin, url: original, title: title, company: company, text: HTMLText.plain(body))
    }

    // MARK: Ashby

    static func ashby(org: String, id: String, original: URL, session: URLSession) async throws -> Posting {
        let api = URL(string: "https://api.ashbyhq.com/posting-api/job-board/\(org)")!
        guard let root = try json(try await get(api, session: session)) as? [String: Any],
              let jobs = root["jobs"] as? [[String: Any]],
              let job = jobs.first(where: { ($0["id"] as? String)?.lowercased() == id.lowercased() })
        else { throw PostingError.unreadable }
        let text = (job["descriptionHtml"] as? String).map { HTMLText.plain($0) } ?? (job["descriptionPlain"] as? String) ?? ""
        // The Ashby board API carries no company name: the board slug is the best available label.
        return try make(.ashby, url: original, title: job["title"] as? String, company: prettify(slug: org), text: text)
    }

    // MARK: Greenhouse

    static func greenhouse(org: String, id: String, original: URL, session: URLSession) async throws -> Posting {
        let api = URL(string: "https://boards-api.greenhouse.io/v1/boards/\(org)/jobs/\(id)")!
        guard let job = try json(try await get(api, session: session)) as? [String: Any] else { throw PostingError.unreadable }
        // `content` is HTML that was entity-escaped once more: decode, then strip.
        let text = HTMLText.plain(HTMLText.decodeEntities((job["content"] as? String) ?? ""))
        return try make(.greenhouse, url: original, title: job["title"] as? String,
                        company: (job["company_name"] as? String) ?? prettify(slug: org), text: text)
    }

    // MARK: Lever

    static func lever(apiHost: String, org: String, id: String, original: URL, session: URLSession) async throws -> Posting {
        let api = URL(string: "https://\(apiHost)/v0/postings/\(org)/\(id)")!
        guard let job = try json(try await get(api, session: session)) as? [String: Any] else { throw PostingError.unreadable }
        var blocks: [String] = []
        if let d = job["descriptionPlain"] as? String { blocks.append(d) }
        else if let d = job["description"] as? String { blocks.append(HTMLText.plain(d)) }
        for list in (job["lists"] as? [[String: Any]]) ?? [] {
            let heading = (list["text"] as? String) ?? ""
            let content = HTMLText.plain((list["content"] as? String) ?? "")
            blocks.append([heading, content].filter { !$0.isEmpty }.joined(separator: "\n"))
        }
        if let a = job["additionalPlain"] as? String { blocks.append(a) }
        return try make(.lever, url: original, title: job["text"] as? String, company: prettify(slug: org),
                        text: blocks.joined(separator: "\n\n"))
    }

    // MARK: generic page

    static let minPageCharacters = 200

    static func page(_ url: URL, session: URLSession) async throws -> Posting {
        let html = string(try await get(url, session: session, accept: "text/html,application/xhtml+xml"))
        if let ld = jsonLD(html, url: url) { return ld }

        var scope = html
        if let main = HTMLText.capture(html, "<main\\b[^>]*>(.*)</main>") {
            scope = main
        } else if let art = HTMLText.capture(html, "<article\\b[^>]*>(.*?)</article>") {
            scope = art
        } else if let body = HTMLText.capture(html, "<body\\b[^>]*>(.*)</body>") {
            scope = HTMLText.sub(body, "<header\\b[^>]*>.*?</header\\s*>", "")
        }
        for tag in ["nav", "footer", "aside", "form", "button"] {
            scope = HTMLText.sub(scope, "<\(tag)\\b[^>]*>.*?</\(tag)\\s*>", "")
        }
        let text = HTMLText.plain(scope)
        guard text.count >= minPageCharacters else { throw PostingError.unreadable }

        let h1 = HTMLText.capture(scope, "<h1\\b[^>]*>(.*?)</h1>").map { HTMLText.plain($0) }
        let docTitle = HTMLText.capture(html, "<title[^>]*>(.*?)</title>").map { HTMLText.plain($0) }
            .map { String($0.split(whereSeparator: { "|–—".contains($0) }).first ?? "").trimmingCharacters(in: .whitespaces) }
        let title = [h1, meta(html, "og:title"), docTitle].compactMap { $0 }.first { !$0.isEmpty } ?? ""
        return try make(.page, url: url, title: title, company: meta(html, "og:site_name"), text: text)
    }

    static func meta(_ html: String, _ property: String) -> String? {
        let p = NSRegularExpression.escapedPattern(for: property)
        let v = HTMLText.capture(html, "<meta[^>]+(?:property|name)=[\"']\(p)[\"'][^>]*content=[\"']([^\"']*)[\"']")
            ?? HTMLText.capture(html, "<meta[^>]+content=[\"']([^\"']*)[\"'][^>]*(?:property|name)=[\"']\(p)[\"']")
        return v.map { HTMLText.decodeEntities($0) }
    }

    static func jsonLD(_ html: String, url: URL) -> Posting? {
        for raw in HTMLText.allCaptures(html, "<script[^>]*type\\s*=\\s*[\"']application/ld\\+json[\"'][^>]*>(.*?)</script>") {
            guard let data = raw.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data),
                  let job = findJobPosting(obj),
                  let title = job["title"] as? String ?? job["name"] as? String,
                  var desc = job["description"] as? String else { continue }
            if desc.contains("&lt;") { desc = HTMLText.decodeEntities(desc) }
            let org = job["hiringOrganization"]
            let company = (org as? [String: Any])?["name"] as? String ?? (org as? String)
            if let p = try? make(.page, url: url, title: HTMLText.decodeEntities(title), company: company, text: HTMLText.plain(desc)),
               p.text.count >= 40 { return p }
        }
        return nil
    }

    static func findJobPosting(_ node: Any) -> [String: Any]? {
        if let arr = node as? [Any] { return arr.lazy.compactMap(findJobPosting).first }
        guard let d = node as? [String: Any] else { return nil }
        let type = d["@type"]
        if (type as? String) == "JobPosting" || ((type as? [String])?.contains("JobPosting") ?? false) { return d }
        if let g = d["@graph"] { return findJobPosting(g) }
        return nil
    }
}
