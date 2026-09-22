import AppKit
import Foundation
import Security

/// Todoist as a task source, over its REST API: today, tomorrow, one
/// project; complete, add, open in the Todoist app. The API token comes
/// from Todoist → Settings → Integrations → Developer and lives in the
/// login keychain, under Codenotch's own item.
///
/// Every call here is synchronous, like the other bridges: `TodoStore`
/// runs them off the main thread and publishes the result.
enum TodoistBridge {
    static let bundleID = "com.todoist.mac.Todoist"
    static var isInstalled: Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil }

    // MARK: Token

    private static let service = "com.vinz.codenotch.todoist"
    private static let account = "api-token"
    private static var cachedToken: String??

    static var token: String {
        get {
            if let cached = cachedToken { return cached ?? "" }
            let query: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: service,
                kSecAttrAccount: account,
                kSecReturnData: true,
                kSecMatchLimit: kSecMatchLimitOne
            ]
            var result: CFTypeRef?
            let found = SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
            let value = found ? (result as? Data).flatMap { String(data: $0, encoding: .utf8) } : nil
            cachedToken = .some(value)
            return value ?? ""
        }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let base: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: service,
                kSecAttrAccount: account
            ]
            SecItemDelete(base as CFDictionary)
            if !trimmed.isEmpty {
                var item = base
                item[kSecValueData] = Data(trimmed.utf8)
                item[kSecAttrLabel] = "Codenotch · Todoist API token"
                SecItemAdd(item as CFDictionary, nil)
            }
            cachedToken = .some(trimmed.isEmpty ? nil : trimmed)
            projectCache = nil
        }
    }

    static var hasToken: Bool { !token.isEmpty }

    // MARK: HTTP

    /// Todoist's unified API; the REST v2 and Sync v9 endpoints answer 410.
    private static let api = URL(string: "https://api.todoist.com/api/v1/")!

    private static func request(_ url: URL, method: String = "GET", json: [String: Any]? = nil) -> Data? {
        guard hasToken else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let json {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: json)
        }
        let done = DispatchSemaphore(value: 0)
        var body: Data?
        var ok = false
        URLSession.shared.dataTask(with: req) { data, response, error in
            if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), error == nil {
                body = data ?? Data(); ok = true
            } else if let error {
                Log.usage.error("todoist: \(url.lastPathComponent, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            } else if let http = response as? HTTPURLResponse {
                Log.usage.error("todoist: \(url.lastPathComponent, privacy: .public) HTTP \(http.statusCode, privacy: .public)")
            }
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 20)
        return ok ? body : nil
    }

    private static func get(_ path: String, query: [String: String] = [:]) -> Any? {
        var comps = URLComponents(url: api.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        guard let url = comps.url, let data = request(url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    /// Every page of a paginated list (`results` or `items`, then `next_cursor`).
    private static func pages(_ path: String, query: [String: String] = [:]) -> [[String: Any]]? {
        var all: [[String: Any]] = []
        var cursor: String? = nil
        var q = query; q["limit"] = "200"
        repeat {
            if let cursor { q["cursor"] = cursor }
            guard let page = get(path, query: q) as? [String: Any] else { return all.isEmpty ? nil : all }
            all += (page["results"] ?? page["items"]) as? [[String: Any]] ?? []
            cursor = page["next_cursor"] as? String
        } while cursor != nil && all.count < 1000
        return all
    }

    // MARK: Projects

    private static var projectCache: (at: Date, byID: [String: String])?

    /// Project id → name, refreshed every few minutes.
    private static func projects() -> [String: String] {
        if let cache = projectCache, Date().timeIntervalSince(cache.at) < 300 { return cache.byID }
        guard let list = pages("projects") else { return projectCache?.byID ?? [:] }
        var byID: [String: String] = [:]
        for p in list {
            if let id = p["id"] as? String, let name = p["name"] as? String { byID[id] = name }
        }
        projectCache = (Date(), byID)
        return byID
    }

    private static func projectID(named name: String) -> String? {
        projects().first { $0.value == name }?.key
    }

    // MARK: Tasks

    static func todos(in list: String) -> [Todo]? {
        guard hasToken else { return nil }
        // Today and tomorrow are filters; a project is listed by id, every
        // task in it whatever its date. (A `#Name` filter returns nothing
        // for a project whose name carries an emoji.)
        let items: [[String: Any]]?
        switch list {
        case "Today": items = pages("tasks/filter", query: ["query": "today | overdue"])
        case "Tomorrow": items = pages("tasks/filter", query: ["query": "tomorrow"])
        default:
            guard let id = projectID(named: list) else { return [] }
            items = pages("tasks", query: ["project_id": id])
        }
        guard let items else { return nil }
        let names = projects()
        return items.compactMap { task -> Todo? in
            guard let id = task["id"] as? String, let content = task["content"] as? String else { return nil }
            let due = (task["due"] as? [String: Any])?["date"] as? String
            let project = (task["project_id"] as? String).flatMap { names[$0] }
            let labels = (task["labels"] as? [String]) ?? []
            return Todo(id: id, name: content, due: due.map { String($0.prefix(10)) }, when: nil,
                        project: project == "Inbox" ? nil : project,
                        tags: labels.isEmpty ? nil : labels.joined(separator: ", "))
        }
        .sorted { ($0.due ?? "9999") < ($1.due ?? "9999") }
    }

    static func completedToday() -> Int {
        guard hasToken else { return 0 }
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        let end = cal.date(byAdding: .day, value: 1, to: start)!
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return pages("tasks/completed/by_completion_date",
                     query: ["since": f.string(from: start), "until": f.string(from: end)])?.count ?? 0
    }

    static func complete(_ id: String) -> Bool {
        request(api.appendingPathComponent("tasks/\(id)/close"), method: "POST") != nil
    }

    static func create(_ name: String, in list: String, project: String? = nil) -> Bool {
        var body: [String: Any] = ["content": name]
        switch list {
        case "Today": body["due_string"] = "today"
        case "Tomorrow": body["due_string"] = "tomorrow"
        default:
            if let id = projectID(named: list) { body["project_id"] = id }
        }
        if let project, let id = projectID(named: project) { body["project_id"] = id }
        return request(api.appendingPathComponent("tasks"), method: "POST", json: body) != nil
    }

    // MARK: Opening

    static func show(_ id: String) {
        let url = isInstalled
            ? URL(string: "todoist://task?id=\(id)")
            : URL(string: "https://app.todoist.com/app/task/\(id)")
        if let url { NSWorkspace.shared.open(url) }
    }

    static func showList(_ list: String) {
        let url: URL?
        switch list {
        case "Today": url = URL(string: isInstalled ? "todoist://today" : "https://app.todoist.com/app/today")
        case "Tomorrow": url = URL(string: isInstalled ? "todoist://upcoming" : "https://app.todoist.com/app/upcoming")
        default:
            if let id = projectID(named: list) {
                url = URL(string: isInstalled ? "todoist://project?id=\(id)" : "https://app.todoist.com/app/project/\(id)")
            } else {
                url = URL(string: isInstalled ? "todoist://today" : "https://app.todoist.com/app/today")
            }
        }
        if let url { NSWorkspace.shared.open(url) }
    }

    static func pickableLists() -> [String] {
        guard hasToken else { return [] }
        return projects().values.filter { $0 != "Inbox" }.sorted()
    }
}
