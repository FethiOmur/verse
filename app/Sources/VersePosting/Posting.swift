import Foundation

public enum PostingSource: String, Sendable {
    case linkedin, ashby, greenhouse, lever, page, pasted
}

public struct Posting: Sendable {
    public var url: URL?
    public var title: String
    public var company: String?
    public var text: String
    public var source: PostingSource

    public init(url: URL?, title: String, company: String?, text: String, source: PostingSource) {
        self.url = url
        self.title = title
        self.company = company
        self.text = text
        self.source = source
    }
}

public enum PostingError: Error, Sendable, Equatable {
    /// Fetched fine, but no readable job content was found: the UI should ask for pasted text.
    case unreadable
    /// The request itself failed (offline, timeout, DNS, TLS).
    case network
}

public enum PostingFetcher {
    /// Upper bound on `Posting.text`; longer postings are cut at a word boundary.
    public static let maxCharacters = 30_000
}
