import Foundation
import SQLite3

/// A website's own search, found the way browsers find it. So "search for X" on YouTube shows YouTube's results,
/// not Google's. Sources, best first: the site searches your browser already learned (Chrome's "tab to search"
/// list — it saw the site's OpenSearch description with your real session), a few built-ins, then the site's
/// OpenSearch description fetched directly.
public actor SiteSearch {
    public static let shared = SiteSearch()

    /// host → URL template with {searchTerms} (nil: the site has none). Filled as sites are visited.
    private var templates: [String: String?] = [:]
    private var learned: [String: String] = [:]
    private var learnedAt = Date.distantPast

    /// A few big sites, so the first search there needs no lookup. `{host}` keeps regional domains (amazon.in).
    private static let known: [String: String] = [
        "youtube.com": "https://www.youtube.com/results?search_query={searchTerms}",
        "amazon": "https://{host}/s?k={searchTerms}",
        "github.com": "https://github.com/search?q={searchTerms}",
        "wikipedia.org": "https://{host}/w/index.php?search={searchTerms}",
        "reddit.com": "https://www.reddit.com/search/?q={searchTerms}",
        "linkedin.com": "https://www.linkedin.com/search/results/all/?keywords={searchTerms}",
        "x.com": "https://x.com/search?q={searchTerms}",
        "flipkart.com": "https://www.flipkart.com/search?q={searchTerms}",
    ]

    /// The results page for `query` on the site at `host`, or nil if the site has no search Hark can find.
    public func url(host: String, query: String) async -> URL? {
        let bare = host.lowercased().replacingOccurrences(of: #"^www\."#, with: "", options: .regularExpression)
        if Date().timeIntervalSince(learnedAt) > 600 { learned = Self.browserSearches(); learnedAt = Date() }
        let template: String?
        if let fromBrowser = learned[bare] ?? learned.first(where: { bare.hasSuffix("." + $0.key) })?.value {
            template = fromBrowser
        } else if let cached = templates[bare] {
            template = cached
        } else if let seeded = Self.known.first(where: { bare == $0.key || bare.hasSuffix("." + $0.key) || bare.hasPrefix($0.key + ".") })?.value {
            template = seeded
        } else {
            template = await discover(host: host)
            templates[bare] = template
            Log.info(template.map { "Found \(bare)'s search: \($0)" } ?? "\(bare) publishes no search")
        }
        guard let template else { return nil }
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#")
        let terms = query.addingPercentEncoding(withAllowedCharacters: allowed) ?? query
        let filled = template.replacingOccurrences(of: "{host}", with: host)
            .replacingOccurrences(of: "{searchTerms}", with: terms)
            .replacingOccurrences(of: #"&[^&=]+=\{[A-Za-z:]+\?\}"#, with: "", options: .regularExpression)  // optional params
            .replacingOccurrences(of: #"\{[A-Za-z:]+\?\}"#, with: "", options: .regularExpression)
        return URL(string: filled)
    }

    /// Reads the site's home page for its OpenSearch link, then the description for the HTML results URL.
    private func discover(host: String) async -> String? {
        guard let home = URL(string: "https://\(host)/"), let html = await fetch(home) else { return nil }
        guard let tag = html.firstMatch(#"(?i)<link\b[^>]*\brel=["']search["'][^>]*>"#)?[0],
              let href = tag.firstMatch(#"(?i)\bhref=["']([^"']+)["']"#)?[1],
              let descriptionURL = URL(string: href.replacingOccurrences(of: "&amp;", with: "&"), relativeTo: home),
              let xml = await fetch(descriptionURL.absoluteURL) else { return nil }
        let urls = xml.components(separatedBy: "<").filter { $0.lowercased().hasPrefix("url ") }
        guard let entry = urls.first(where: { $0.lowercased().contains("text/html") }) ?? urls.first,
              let template = entry.firstMatch(#"(?i)\btemplate=["']([^"']+)["']"#)?[1],
              template.contains("{searchTerms}") else { return nil }
        return template.replacingOccurrences(of: "&amp;", with: "&")
    }

    /// Site searches Chromium browsers recorded for every profile: domain → template. Read from a copy (the
    /// browser keeps its database open), keywords table only.
    static func browserSearches() -> [String: String] {
        let support = Paths.home.appendingPathComponent("Library/Application Support")
        let roots = ["Google/Chrome", "BraveSoftware/Brave-Browser", "Microsoft Edge", "Arc/User Data", "Chromium"]
            .map { support.appendingPathComponent($0) }
        var found: [String: String] = [:]
        let fm = FileManager.default
        for root in roots {
            let profiles = ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).filter { $0 == "Default" || $0.hasPrefix("Profile ") }
            for profile in profiles {
                let source = root.appendingPathComponent(profile).appendingPathComponent("Web Data")
                guard fm.fileExists(atPath: source.path) else { continue }
                let copy = fm.temporaryDirectory.appendingPathComponent("hark-webdata-\(UUID().uuidString).db")
                defer { try? fm.removeItem(at: copy) }
                guard (try? fm.copyItem(at: source, to: copy)) != nil else { continue }
                var db: OpaquePointer?
                guard sqlite3_open_v2(copy.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { sqlite3_close(db); continue }
                var statement: OpaquePointer?
                let sql = "SELECT keyword, url FROM keywords WHERE url LIKE '%{searchTerms}%' AND url NOT LIKE '%{google:%'"
                if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
                    while sqlite3_step(statement) == SQLITE_ROW {
                        guard let k = sqlite3_column_text(statement, 0), let u = sqlite3_column_text(statement, 1) else { continue }
                        let keyword = String(cString: k).lowercased().replacingOccurrences(of: #"^www\."#, with: "", options: .regularExpression)
                        // Site entries are named by their domain; skip custom shortcuts like "@bookmarks" or "yt".
                        guard keyword.contains("."), !keyword.contains(" "), found[keyword] == nil else { continue }
                        found[keyword] = String(cString: u)
                    }
                }
                sqlite3_finalize(statement)
                sqlite3_close(db)
            }
        }
        return found
    }

    private func fetch(_ url: URL) async -> String? {
        var request = URLRequest(url: url, timeoutInterval: 3)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 14_6) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Safari/605.1.15",
                         forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false else { return nil }
        return String(decoding: data.prefix(600_000), as: UTF8.self)
    }
}
