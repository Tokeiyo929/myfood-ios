import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

let BASE_URL = "https://myfood.tuqingyu.xyz"

struct APIError: LocalizedError { let message: String; var errorDescription: String? { message } }

enum API {
    static var session = URLSession.shared
    static func imageUrl(_ path: String?) -> URL? {
        guard let p = path, !p.isEmpty else { return nil }
        if p.hasPrefix("offline:") { return OfflineStore.localImageURL(p) } // 离线待传原图
        if p.hasPrefix("http") { return URL(string: p) }
        return URL(string: BASE_URL + p)
    }

    static func request(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> [String: Any] {
        guard let url = URL(string: BASE_URL + path) else { throw APIError(message: "bad url") }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 30
        if let b = body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: b)
        }
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw APIError(message: "网络错误") }
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(http.statusCode) else {
            throw APIError(message: (obj?["error"] as? String) ?? "HTTP \(http.statusCode)")
        }
        guard let obj else { throw APIError(message: "服务器返回的数据格式无效") }
        return obj
    }

    // 上传图片（multipart/form-data），返回 ["path": ..., "metadata": ...]
    static func uploadImage(jpegData: Data) async throws -> [String: Any] {
        guard !jpegData.isEmpty else { throw APIError(message: "图片编码失败") }
        guard let url = URL(string: BASE_URL + "/api/upload") else { throw APIError(message: "bad url") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 90
        let boundary = "myfood\(Int.random(in: 100000...999999))"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"image\"; filename=\"photo.jpg\"\r\nContent-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
        body.append(jpegData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw APIError(message: "上传失败")
        }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let path = obj["path"] as? String, !path.isEmpty else {
            throw APIError(message: "上传失败：服务器未返回图片路径")
        }
        return obj
    }

    // MARK: - 接口
    static func getConfig() async throws -> [String: Any] { try await request("/api/config") }
    static func getFoods(page: Int, limit: Int, search: String = "", today: Bool = false) async throws -> [String: Any] {
        var query = URLComponents()
        query.queryItems = [URLQueryItem(name: "page", value: String(page)), URLQueryItem(name: "limit", value: String(limit))]
        if !search.isEmpty { query.queryItems?.append(URLQueryItem(name: "search", value: search)) }
        if today { query.queryItems?.append(URLQueryItem(name: "today", value: "1")) }
        let encoded = query.percentEncodedQuery!.replacingOccurrences(of: "+", with: "%2B")
        let result = try await request("/api/foods?\(encoded)")
        guard let items = result["items"] as? [[String: Any]],
              let total = result["total"] as? Int, total >= 0,
              items.allSatisfy({ $0["id"] is Int }) else { throw APIError(message: "记录列表格式无效") }
        return result
    }
    static func getFoodById(_ id: Int) async throws -> [String: Any] {
        let result = try await request("/api/foods/\(id)")
        guard result["id"] as? Int == id else { throw APIError(message: "记录格式无效") }
        return result
    }
    static func getAllFoods(limit: Int, today: Bool = false) async throws -> [[String: Any]] {
        var foods: [[String: Any]] = []
        var page = 1
        while true {
            let result = try await getFoods(page: page, limit: limit, today: today)
            let items = result["items"] as! [[String: Any]]
            foods += items
            if foods.count >= result["total"] as! Int { return foods }
            guard !items.isEmpty else { throw APIError(message: "记录分页不完整，请重试") }
            page += 1
        }
    }
    static func getCategories() async throws -> [String: Any] {
        let result = try await request("/api/categories")
        guard result["items"] is [[String: Any]] else { throw APIError(message: "类别列表格式无效") }
        return result
    }
    static func addIngredient(_ name: String) async throws -> [String: Any] { try await request("/api/ingredients", method: "POST", body: ["name": name]) }
    static func submitFood(_ record: [String: Any]) async throws -> [String: Any] { try await request("/api/foods", method: "POST", body: record) }
    static func updateFoodDetails(_ id: Int, fields: [String: Any]) async throws -> [String: Any] { try await request("/api/foods/\(id)", method: "PATCH", body: ["fields": fields]) }
    static func addComment(_ id: Int, comment: [String]) async throws -> [String: Any] { try await request("/api/foods/\(id)", method: "PATCH", body: ["comment": comment]) }
    static func deleteFood(_ id: Int) async throws -> [String: Any] { try await request("/api/foods/\(id)", method: "DELETE") }
    static func postTrackPoints(_ points: [[String: Any]]) async throws { _ = try await request("/api/tracks", method: "POST", body: ["points": points]) }
    static func getTrackPoints(day: String) async throws -> [[String: Any]] {
        let r = try await request("/api/tracks?day=\(day)")
        guard let points = r["points"] as? [[String: Any]] else { throw APIError(message: "轨迹格式无效") }
        return points
    }
    static func getTrackDays() async throws -> [[String: Any]] {
        let r = try await request("/api/tracks/days")
        guard let days = r["days"] as? [[String: Any]] else { throw APIError(message: "轨迹日期格式无效") }
        return days
    }

    // MARK: - 摘抄
    static func getQuotes() async throws -> [String: Any] {
        let r = try await request("/api/quotes")
        guard r["items"] is [[String: Any]] else { throw APIError(message: "摘抄列表格式无效") }
        return r
    }
    static func createQuote(text: String, note: String, clientKey: String) async throws -> [String: Any] {
        try await request("/api/quotes", method: "POST", body: ["text": text, "note": note, "client_key": clientKey])
    }
    static func deleteQuote(_ id: Int) async throws -> [String: Any] {
        try await request("/api/quotes/\(id)", method: "DELETE")
    }
}
