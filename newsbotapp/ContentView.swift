//
//  NewsBot.swift — Single-file SwiftUI News App (Apple‑grade)
//  Fetches LIVE RSS, persists locally, auto-cleans 7‑day‑old data,
//  includes bookmarks, sharing, dark mode, custom sources, alerts & more.
//  iOS 17+ | Swift 5.9+
//

import SwiftUI
import SafariServices
import Combine
import UserNotifications

// MARK: - Models

struct NewsItem: Identifiable, Equatable, Codable {
    let id: String
    let title: String
    let publishedAt: Date
    let url: String
    let source: String
    let imageURL: String?
    let description: String?               // plain text for search & offline

    static func == (lhs: NewsItem, rhs: NewsItem) -> Bool { lhs.id == rhs.id }
}

// MARK: - RSS Sources

struct RSSSource: Codable, Equatable {
    let name: String
    let url: String
    let category: NewsCategory
}

enum NewsCategory: String, CaseIterable, Codable {
    case all       = "All"
    case world     = "World"
    case politics  = "Politics"
    case technology = "Tech"
    case business  = "Business"
    case science   = "Science"
    // bookmarks is handled via separate filter, not a real category
}

let RSS_SOURCES: [RSSSource] = [
    // BBC
    RSSSource(name: "BBC World",       url: "https://feeds.bbci.co.uk/news/world/rss.xml",      category: .world),
    RSSSource(name: "BBC Technology",  url: "https://feeds.bbci.co.uk/news/technology/rss.xml", category: .technology),
    RSSSource(name: "BBC Business",    url: "https://feeds.bbci.co.uk/news/business/rss.xml",   category: .business),
    RSSSource(name: "BBC Science",     url: "https://feeds.bbci.co.uk/news/science_and_environment/rss.xml", category: .science),
    RSSSource(name: "BBC Politics",    url: "https://feeds.bbci.co.uk/news/politics/rss.xml",   category: .politics),
    // Al Jazeera
    RSSSource(name: "Al Jazeera",      url: "https://www.aljazeera.com/xml/rss/all.xml",        category: .world),
    // NPR
    RSSSource(name: "NPR News",        url: "https://feeds.npr.org/1001/rss.xml",               category: .world),
    RSSSource(name: "NPR Politics",    url: "https://feeds.npr.org/1014/rss.xml",               category: .politics),
    RSSSource(name: "NPR World",       url: "https://feeds.npr.org/1004/rss.xml",               category: .world),
    // The Guardian
    RSSSource(name: "Guardian World",  url: "https://www.theguardian.com/world/rss",            category: .world),
    RSSSource(name: "Guardian Tech",   url: "https://www.theguardian.com/technology/rss",       category: .technology),
    RSSSource(name: "Guardian Business", url: "https://www.theguardian.com/business/rss",      category: .business),
    RSSSource(name: "Guardian Politics", url: "https://www.theguardian.com/politics/rss",      category: .politics),
    RSSSource(name: "Guardian Science", url: "https://www.theguardian.com/science/rss",        category: .science),
    // Sky News
    RSSSource(name: "Sky News World",  url: "https://feeds.skynews.com/feeds/rss/world.xml",   category: .world),
    RSSSource(name: "Sky News Tech",   url: "https://feeds.skynews.com/feeds/rss/technology.xml", category: .technology),
    RSSSource(name: "Sky News Politics", url: "https://feeds.skynews.com/feeds/rss/politics.xml", category: .politics),
    // Fox News
    RSSSource(name: "Fox News World",  url: "https://moxie.foxnews.com/google-publisher/world.xml", category: .world),
    RSSSource(name: "Fox News Politics", url: "https://moxie.foxnews.com/google-publisher/politics.xml", category: .politics),
    RSSSource(name: "Fox News Tech",   url: "https://moxie.foxnews.com/google-publisher/tech.xml", category: .technology),
    // USA Today
    RSSSource(name: "USA Today",       url: "https://rssfeeds.usatoday.com/usatoday-NewsTopStories", category: .world),
    // The Independent
    RSSSource(name: "The Independent", url: "https://www.independent.co.uk/news/world/rss",    category: .world),
    // Times of India
    RSSSource(name: "Times of India",  url: "https://timesofindia.indiatimes.com/rssfeeds/296589292.cms", category: .world),
    // Dawn Pakistan
    RSSSource(name: "Dawn News",       url: "https://www.dawn.com/feeds/home",                 category: .world),
    // CBS News
    RSSSource(name: "CBS News",        url: "https://www.cbsnews.com/latest/rss/main",         category: .world),
    // Google News (via RSS)
    RSSSource(name: "Google News World", url: "https://news.google.com/rss?hl=en-US&gl=US&ceid=US:en", category: .world),
    RSSSource(name: "Google News Tech",  url: "https://news.google.com/rss/topics/CAAqJggKIiBDQkFTRWdvSUwyMHZNRGRqTVhZU0FtVnVHZ0pWVXlBQVAB?hl=en-US&gl=US&ceid=US:en", category: .technology),
]

// MARK: - RSS Parser (extracts description as plain text)

final class RSSParser: NSObject, XMLParserDelegate {
    private var items: [[String: String]] = []
    private var current: [String: String] = [:]
    private var currentElement = ""
    private var currentText = ""
    private var insideItem = false

    func parse(data: Data) -> [[String: String]] {
        items = []
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return items
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        currentElement = elementName.lowercased()
        currentText = ""
        if currentElement == "item" || currentElement == "entry" {
            insideItem = true
            current = [:]
        }
        // Capture media thumbnail / enclosure for image
        if insideItem {
            if currentElement == "media:thumbnail" || currentElement == "media:content" {
                if let url = attributeDict["url"] { current["imageURL"] = url }
            }
            if currentElement == "enclosure" {
                if let type = attributeDict["type"], type.hasPrefix("image"),
                   let url = attributeDict["url"] { current["imageURL"] = url }
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let str = String(data: CDATABlock, encoding: .utf8) { currentText += str }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        let el = elementName.lowercased()
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        if insideItem && !text.isEmpty {
            switch el {
            case "title":           if current["title"] == nil    { current["title"] = text }
            case "link":            if current["link"] == nil     { current["link"] = text }
            case "guid":            if current["guid"] == nil     { current["guid"] = text }
            case "pubdate":         current["pubDate"] = text
            case "published":       if current["pubDate"] == nil  { current["pubDate"] = text }
            case "updated":         if current["pubDate"] == nil  { current["pubDate"] = text }
            case "description":
                // Strip HTML tags to keep plain text
                let stripped = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if current["description"] == nil { current["description"] = stripped }
            case "media:thumbnail": if current["imageURL"] == nil { current["imageURL"] = text }
            default: break
            }
        }
        if el == "item" || el == "entry" {
            if !current.isEmpty { items.append(current) }
            insideItem = false
            current = [:]
        }
        currentElement = ""
        currentText = ""
    }
}

// MARK: - Date Parsers

private let dateFormatters: [DateFormatter] = {
    let formats = [
        "EEE, dd MMM yyyy HH:mm:ss Z",
        "EEE, dd MMM yyyy HH:mm:ss z",
        "EEE, d MMM yyyy HH:mm:ss Z",
        "yyyy-MM-dd'T'HH:mm:ssZ",
        "yyyy-MM-dd'T'HH:mm:ss.SSSZ",
        "yyyy-MM-dd'T'HH:mm:ssXXXXX",
        "yyyy-MM-dd HH:mm:ss",
        "EEE, dd MMM yyyy HH:mm Z",
    ]
    return formats.map {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = $0
        return f
    }
}()

func parseDate(_ string: String?) -> Date {
    guard let s = string?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return Date() }
    for f in dateFormatters { if let d = f.date(from: s) { return d } }
    return Date()
}

// MARK: - Local Persistence (auto‑removes items older than 7 days)

final class PersistenceController {
    static let shared = PersistenceController()
    private let fileName = "news_cache.json"

    private var fileURL: URL {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(fileName)
    }

    func load() -> [NewsItem] {
        guard let data = try? Data(contentsOf: fileURL),
              let items = try? JSONDecoder().decode([NewsItem].self, from: data) else {
            return []
        }
        return filterRecent(items)
    }

    func save(_ items: [NewsItem]) {
        let recent = filterRecent(items)
        if let data = try? JSONEncoder().encode(recent) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private func filterRecent(_ items: [NewsItem]) -> [NewsItem] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        return items.filter { $0.publishedAt >= cutoff }
    }
}

// MARK: - News Service

actor NewsService {
    private let session: URLSession
    private let maxRetries = 2
    private let retryDelay: UInt64 = 2_000_000_000

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/120.0.0.0 Safari/537.36"
        ]
        session = URLSession(configuration: config)
    }

    func fetchAll(enabledSources: Set<String>) async -> [NewsItem] {
        await withTaskGroup(of: [NewsItem].self) { group in
            for source in RSS_SOURCES {
                guard enabledSources.contains(source.url) else { continue }
                group.addTask { await self.fetchSource(source) }
            }
            var all: [NewsItem] = []
            for await items in group { all.append(contentsOf: items) }
            return all
        }
    }

    private func fetchSource(_ source: RSSSource, attempt: Int = 0) async -> [NewsItem] {
        guard let url = URL(string: source.url) else { return [] }
        do {
            let (data, _) = try await session.data(from: url)
            let parser = RSSParser()
            let raw = parser.parse(data: data)
            return raw.compactMap { dict -> NewsItem? in
                guard let title = dict["title"], !title.isEmpty else { return nil }
                let link = dict["link"] ?? dict["guid"] ?? ""
                guard !link.isEmpty else { return nil }
                let date = parseDate(dict["pubDate"])
                let sevenDaysAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
                guard date >= sevenDaysAgo else { return nil }
                return NewsItem(
                    id: link,
                    title: title.replacingOccurrences(of: "&amp;", with: "&")
                                .replacingOccurrences(of: "&lt;", with: "<")
                                .replacingOccurrences(of: "&gt;", with: ">")
                                .replacingOccurrences(of: "&quot;", with: "\"")
                                .replacingOccurrences(of: "&#39;", with: "'"),
                    publishedAt: date,
                    url: link,
                    source: source.name,
                    imageURL: dict["imageURL"],
                    description: dict["description"]
                )
            }
        } catch {
            if attempt < maxRetries {
                try? await Task.sleep(nanoseconds: retryDelay)
                return await fetchSource(source, attempt: attempt + 1)
            }
            return []
        }
    }
}

// MARK: - ViewModel

@MainActor
final class NewsViewModel: ObservableObject {
    @Published var items: [NewsItem] = []
    @Published var filteredItems: [NewsItem] = []
    @Published var selectedCategory: NewsCategory = .all
    @Published var searchText: String = ""
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var lastUpdated: Date?
    @Published var isRefreshing = false
    @Published var showBookmarksOnly = false
    @Published var bookmarkedIDs: Set<String> = []
    @Published var enabledSources: Set<String> = Set(RSS_SOURCES.map { $0.url })

    private let service = NewsService()
    private var seenIDs = Set<String>()
    private var refreshTimer: Timer?

    init() {
        // Load bookmarks and enabled sources from UserDefaults
        if let data = UserDefaults.standard.data(forKey: "bookmarks"),
           let ids = try? JSONDecoder().decode(Set<String>.self, from: data) {
            bookmarkedIDs = ids
        }
        if let saved = UserDefaults.standard.stringArray(forKey: "enabledSources") {
            enabledSources = Set(saved)
        }
        // Load cached articles
        items = PersistenceController.shared.load()
        seenIDs = Set(items.map { $0.id })
        lastUpdated = items.first?.publishedAt
        applyFilters()
        Task { await fetchNews() }
        startAutoRefresh()
        requestNotificationPermission()
    }

    deinit { refreshTimer?.invalidate() }

    func fetchNews(isRefresh: Bool = false) async {
        if isRefresh { isRefreshing = true } else { isLoading = items.isEmpty }
        errorMessage = nil
        do {
            let fetched = await service.fetchAll(enabledSources: enabledSources)
            let new = fetched.filter { !seenIDs.contains($0.id) }
            seenIDs.formUnion(new.map { $0.id })

            // Deduplicate by normalized title
            var seenTitles = Set(items.map { $0.title.lowercased().trimmingCharacters(in: .whitespaces) })
            let trulyNew = new.filter { item in
                let norm = item.title.lowercased().trimmingCharacters(in: .whitespaces)
                if seenTitles.contains(norm) { return false }
                seenTitles.insert(norm)
                return true
            }

            // Check for breaking news and send local notifications
            for item in trulyNew where item.title.lowercased().contains("breaking") {
                let content = UNMutableNotificationContent()
                content.title = "Breaking News"
                content.body = item.title
                content.sound = .default
                let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
                let request = UNNotificationRequest(identifier: item.id, content: content, trigger: trigger)
                try? await UNUserNotificationCenter.current().add(request)
            }

            items.insert(contentsOf: trulyNew, at: 0)
            items.sort { $0.publishedAt > $1.publishedAt }
            // Save to local cache (auto‑prunes 7‑day‑old data)
            PersistenceController.shared.save(items)
            lastUpdated = Date()
            applyFilters()
            if fetched.isEmpty { errorMessage = "Could not reach news sources. Check your connection." }
        }
        isLoading = false
        isRefreshing = false
    }

    func toggleBookmark(_ id: String) {
        if bookmarkedIDs.contains(id) {
            bookmarkedIDs.remove(id)
        } else {
            bookmarkedIDs.insert(id)
        }
        if let data = try? JSONEncoder().encode(bookmarkedIDs) {
            UserDefaults.standard.set(data, forKey: "bookmarks")
        }
        if showBookmarksOnly { applyFilters() }
    }

    func applyFilters() {
        var result = items
        if showBookmarksOnly {
            result = result.filter { bookmarkedIDs.contains($0.id) }
        } else if selectedCategory != .all {
            let sources = RSS_SOURCES.filter { $0.category == selectedCategory }.map { $0.name }
            result = result.filter { sources.contains($0.source) }
        }
        if !searchText.isEmpty {
            let q = searchText.lowercased()
            result = result.filter {
                $0.title.lowercased().contains(q) ||
                $0.source.lowercased().contains(q) ||
                ($0.description?.lowercased().contains(q) ?? false)
            }
        }
        filteredItems = result
    }

    private func startAutoRefresh() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            Task { await self?.fetchNews(isRefresh: true) }
        }
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    /// Returns the bookmarked NewsItem objects (sorted by most recently added)
    var playlistItems: [NewsItem] {
        items
            .filter { bookmarkedIDs.contains($0.id) }
            .sorted { $0.publishedAt > $1.publishedAt }
    }

    func clearPlaylist() {
        bookmarkedIDs.removeAll()
        if let data = try? JSONEncoder().encode(Set<String>()) {
            UserDefaults.standard.set(data, forKey: "bookmarks")
        }
        if showBookmarksOnly { applyFilters() }
    }

    func relativeTime(_ date: Date) -> String {
        let diff = Date().timeIntervalSince(date)
        if diff < 60          { return "Just now" }
        if diff < 3600        { return "\(Int(diff/60))m ago" }
        if diff < 86400       { return "\(Int(diff/3600))h ago" }
        return "\(Int(diff/86400))d ago"
    }
}

// MARK: - Safari View

struct SafariView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController {
        let vc = SFSafariViewController(url: url)
        vc.preferredControlTintColor = .systemBlue
        return vc
    }
    func updateUIViewController(_ vc: SFSafariViewController, context: Context) {}
}

// MARK: - Share Sheet (UIKit bridge)

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - Source Badge Colors

private func badgeColor(for source: String) -> Color {
    let palette: [Color] = [
        Color(red: 0.22, green: 0.29, blue: 0.71),  // indigo
        Color(red: 0.12, green: 0.62, blue: 0.46),  // teal
        Color(red: 0.85, green: 0.35, blue: 0.19),  // coral
        Color(red: 0.60, green: 0.20, blue: 0.55),  // purple
        Color(red: 0.13, green: 0.48, blue: 0.71),  // blue
        Color(red: 0.73, green: 0.46, blue: 0.09),  // amber
    ]
    let hash = abs(source.hashValue) % palette.count
    return palette[hash]
}

// MARK: - Views

// MARK: Category Pill
struct CategoryPill: View {
    let category: NewsCategory
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(category.rawValue)
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? .white : Color.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(
                    isSelected
                    ? Color.accentColor
                    : Color(.systemGray6)
                )
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: Source Badge
struct SourceBadge: View {
    let name: String
    var body: some View {
        Text(name)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(badgeColor(for: name))
            .clipShape(Capsule())
            .lineLimit(1)
    }
}

// MARK: Featured Card (large)
struct FeaturedCard: View {
    let item: NewsItem
    let relTime: String
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .bottomLeading) {
                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [badgeColor(for: item.source).opacity(0.25),
                                         badgeColor(for: item.source).opacity(0.08)],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            )
                        )
                        .frame(height: 160)
                    VStack(alignment: .leading, spacing: 4) {
                        SourceBadge(name: item.source)
                        Text(item.title)
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(3)
                            .shadow(color: .black.opacity(0.5), radius: 2, x: 0, y: 1)
                    }
                    .padding(14)
                }
                .overlay(
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.7)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                HStack {
                    Image(systemName: "clock")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(relTime)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 10)
                .padding(.horizontal, 2)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: News Row Card
struct NewsRowCard: View {
    let item: NewsItem
    let relTime: String
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(badgeColor(for: item.source))
                    .frame(width: 3)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        SourceBadge(name: item.source)
                        Spacer()
                        Text(relTime)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    Text(item.title)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
            .background(Color(.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color(.separator).opacity(0.4), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: Empty/Error State
struct EmptyStateView: View {
    let error: String?
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: error != nil ? "wifi.slash" : "newspaper")
                .font(.system(size: 52, weight: .ultraLight))
                .foregroundStyle(.secondary)
            Text(error != nil ? "Connection Error" : "No Recent News")
                .font(.system(size: 20, weight: .semibold))
            Text(error ?? "No articles found in the last 7 days for this category.")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button(action: onRetry) {
                Label("Try Again", systemImage: "arrow.clockwise")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 12)
                    .background(Color.accentColor)
                    .clipShape(Capsule())
            }
            Spacer()
        }
    }
}

// MARK: Stats Banner
struct StatsBanner: View {
    let count: Int
    let lastUpdated: Date?

    private let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 7, height: 7)
                Text("Live")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.green)
            }
            Text("\(count) articles")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
            if let date = lastUpdated {
                Text("Updated \(timeFormatter.string(from: date))")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemBackground))
    }
}

// MARK: Source Count Footer
struct SourceCountFooter: View {
    var body: some View {
        VStack(spacing: 4) {
            Divider()
            Text("Aggregating \(RSS_SOURCES.count) live RSS sources worldwide")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.vertical, 8)
        }
    }
}

// MARK: Article Detail Sheet (web + offline fallback)
struct ArticleDetailView: View {
    let item: NewsItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let url = URL(string: item.url) {
            SafariView(url: url)
                .ignoresSafeArea()
        } else if let desc = item.description, !desc.isEmpty {
            NavigationStack {
                ScrollView {
                    Text(desc)
                        .padding()
                }
                .navigationTitle("Offline Reading")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
            }
        } else {
            VStack(spacing: 16) {
                Image(systemName: "link.badge.plus")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
                Text("Could not open article")
                    .font(.headline)
                Button("Dismiss") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

// MARK: Settings Sheet (manage sources + dark mode)
struct SettingsView: View {
    @ObservedObject var vm: NewsViewModel
    @Binding var isDarkMode: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("Dark Mode", isOn: $isDarkMode)
                } header: {
                    Text("Appearance")
                }

                Section {
                    ForEach(RSS_SOURCES, id: \.url) { source in
                        Toggle(source.name, isOn: Binding(
                            get: { vm.enabledSources.contains(source.url) },
                            set: { newValue in
                                if newValue {
                                    vm.enabledSources.insert(source.url)
                                } else {
                                    vm.enabledSources.remove(source.url)
                                }
                                UserDefaults.standard.set(Array(vm.enabledSources), forKey: "enabledSources")
                            }
                        ))
                    }
                } header: {
                    Text("News Sources")
                } footer: {
                    Text("Disable sources you don't want to see. Changes apply on next refresh.")
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Playlist View
struct PlaylistView: View {
    @ObservedObject var vm: NewsViewModel
    @State private var selectedItem: NewsItem?
    @State private var showDetail = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if vm.playlistItems.isEmpty {
                    VStack(spacing: 20) {
                        Spacer()
                        Image(systemName: "bookmark.slash")
                            .font(.system(size: 52, weight: .ultraLight))
                            .foregroundStyle(.secondary)
                        Text("Your Playlist is Empty")
                            .font(.system(size: 20, weight: .semibold))
                        Text("Swipe right on any article to bookmark it and it will appear here.")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                        Spacer()
                    }
                } else {
                    List {
                        ForEach(vm.playlistItems) { item in
                            Button {
                                selectedItem = item
                                showDetail = true
                            } label: {
                                HStack(spacing: 12) {
                                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                                        .fill(badgeColor(for: item.source))
                                        .frame(width: 3)

                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack(spacing: 6) {
                                            SourceBadge(name: item.source)
                                            Spacer()
                                            Text(vm.relativeTime(item.publishedAt))
                                                .font(.system(size: 11))
                                                .foregroundStyle(.tertiary)
                                        }
                                        Text(item.title)
                                            .font(.system(size: 15, weight: .medium))
                                            .foregroundStyle(.primary)
                                            .lineLimit(2)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    vm.toggleBookmark(item.id)
                                } label: {
                                    Label("Remove", systemImage: "bookmark.slash.fill")
                                }
                            }
                        }
                        .onDelete { indexSet in
                            for index in indexSet {
                                let item = vm.playlistItems[index]
                                vm.toggleBookmark(item.id)
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            if !vm.playlistItems.isEmpty {
                                EditButton()
                            }
                        }
                        ToolbarItem(placement: .navigationBarLeading) {
                            if !vm.playlistItems.isEmpty {
                                Button("Clear All", role: .destructive) {
                                    vm.clearPlaylist()
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Playlist (\(vm.playlistItems.count))")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showDetail) {
                if let item = selectedItem {
                    ArticleDetailView(item: item)
                        .presentationDragIndicator(.visible)
                }
            }
        }
    }
}

// MARK: - Main Feed View
struct NewsFeedView: View {
    @StateObject private var vm = NewsViewModel()
    @State private var selectedItem: NewsItem?
    @State private var showDetail = false
    @State private var shareURL: URL?
    @AppStorage("isDarkMode") private var isDarkMode = false
    @State private var showSettings = false
    @State private var showPlaylist = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Category pills
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(NewsCategory.allCases, id: \.self) { cat in
                            CategoryPill(
                                category: cat,
                                isSelected: vm.selectedCategory == cat && !vm.showBookmarksOnly
                            ) {
                                vm.showBookmarksOnly = false
                                vm.selectedCategory = cat
                                vm.applyFilters()
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
                .background(Color(.systemBackground))

                // Stats banner
                StatsBanner(count: vm.filteredItems.count, lastUpdated: vm.lastUpdated)

                // Content
                if vm.isLoading {
                    Spacer()
                    VStack(spacing: 16) {
                        ProgressView()
                            .scaleEffect(1.4)
                        Text("Fetching live news from \(RSS_SOURCES.count) sources…")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    Spacer()
                } else if vm.filteredItems.isEmpty {
                    EmptyStateView(error: vm.errorMessage) {
                        Task { await vm.fetchNews() }
                    }
                } else {
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            // Featured (first 2) only when not in bookmarks only and no search
                            if !vm.showBookmarksOnly && vm.selectedCategory == .all && vm.searchText.isEmpty {
                                VStack(spacing: 10) {
                                    ForEach(vm.filteredItems.prefix(2)) { item in
                                        FeaturedCard(
                                            item: item,
                                            relTime: vm.relativeTime(item.publishedAt)
                                        ) {
                                            selectedItem = item
                                            showDetail = true
                                        }
                                    }
                                }
                                .padding(.horizontal, 16)
                                .padding(.top, 12)

                                HStack {
                                    Text("Latest Headlines")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                        .textCase(.uppercase)
                                        .tracking(0.8)
                                    Spacer()
                                    if vm.isRefreshing {
                                        ProgressView().scaleEffect(0.7)
                                    }
                                }
                                .padding(.horizontal, 16)
                                .padding(.top, 10)
                                .padding(.bottom, 2)
                            }

                            // Article list rows
                            let startIdx = (!vm.showBookmarksOnly && vm.selectedCategory == .all && vm.searchText.isEmpty) ? 2 : 0
                            ForEach(vm.filteredItems.dropFirst(startIdx)) { item in
                                NewsRowCard(
                                    item: item,
                                    relTime: vm.relativeTime(item.publishedAt)
                                ) {
                                    selectedItem = item
                                    showDetail = true
                                }
                                .swipeActions(edge: .leading) {
                                    Button {
                                        shareURL = URL(string: item.url)
                                    } label: {
                                        Label("Share", systemImage: "square.and.arrow.up")
                                    }
                                    .tint(.blue)
                                }
                                .swipeActions(edge: .trailing) {
                                    Button {
                                        vm.toggleBookmark(item.id)
                                    } label: {
                                        Label(
                                            vm.bookmarkedIDs.contains(item.id) ? "Unbookmark" : "Bookmark",
                                            systemImage: vm.bookmarkedIDs.contains(item.id) ? "bookmark.slash.fill" : "bookmark.fill"
                                        )
                                    }
                                    .tint(.orange)
                                }
                                .padding(.horizontal, 16)
                            }

                            SourceCountFooter()
                                .padding(.horizontal, 16)
                                .padding(.bottom, 8)
                        }
                        .padding(.top, 4)
                    }
                    .refreshable {
                        await vm.fetchNews(isRefresh: true)
                    }
                }
            }
            .navigationTitle("NewsBot")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        showPlaylist.toggle()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "bookmark.fill")
                                .font(.system(size: 14))
                            if !vm.playlistItems.isEmpty {
                                Text("\(vm.playlistItems.count)")
                                    .font(.system(size: 12, weight: .semibold))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(Color.accentColor)
                                    .foregroundStyle(.white)
                                    .clipShape(Capsule())
                            }
                        }
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 12) {
                        Button {
                            showSettings.toggle()
                        } label: {
                            Image(systemName: "gearshape.fill")
                                .font(.system(size: 18))
                        }
                        Button {
                            Task { await vm.fetchNews(isRefresh: true) }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .rotationEffect(.degrees(vm.isRefreshing ? 360 : 0))
                                .animation(vm.isRefreshing ? .linear(duration: 1).repeatForever(autoreverses: false) : .default,
                                           value: vm.isRefreshing)
                        }
                    }
                }
            }
            .searchable(text: $vm.searchText, prompt: "Search headlines or article content…")
            .onChange(of: vm.searchText) { _, _ in vm.applyFilters() }
            .sheet(isPresented: $showDetail) {
                if let item = selectedItem {
                    ArticleDetailView(item: item)
                        .presentationDragIndicator(.visible)
                }
            }
            .sheet(isPresented: Binding<Bool>(
                get: { shareURL != nil },
                set: { if !$0 { shareURL = nil } }
            )) {
                if let url = shareURL {
                    ShareSheet(items: [url])
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(vm: vm, isDarkMode: $isDarkMode)
            }
            .sheet(isPresented: $showPlaylist) {
                PlaylistView(vm: vm)
            }
        }
        .preferredColorScheme(isDarkMode ? .dark : nil)
    }
}

// MARK: - App Entry Point
@main
struct NewsBotApp: App {
    var body: some Scene {
        WindowGroup {
            NewsFeedView()
                .tint(.blue)
        }
    }
}