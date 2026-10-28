import Foundation

let BASE_URL = "https://myfood-worker.keiyokaze.workers.dev"

struct APIError: Error { let message: String }

enum API {
    static func imageUrl(_ path: String?) -> URL? {
        guard let p = path, !p.isEmpty else { return nil }
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
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw APIError(message: "网络错误") }
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(http.statusCode) else {
            throw APIError(message: (obj?["error"] as? String) ?? "HTTP \(http.statusCode)")
        }
        return obj ?? [:]
    }

    // 上传图片（multipart/form-data），返回 ["path": ..., "metadata": ...]
    static func uploadImage(jpegData: Data) async throws -> [String: Any] {
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
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw APIError(message: "上传失败")
        }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let path = obj["path"] as? String else {
            throw APIError(message: "上传失败：服务器未返回图片路径")
        }
        return obj
    }

    // MARK: - 接口
    static func getConfig() async throws -> [String: Any] { try await request("/api/config") }
    static func getFoods(page: Int, limit: Int, search: String = "", today: Bool = false) async throws -> [String: Any] {
        var qs = "page=\(page)&limit=\(limit)"
        if !search.isEmpty { qs += "&search=\(search.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!)" }
        if today { qs += "&today=1" }
        return try await request("/api/foods?\(qs)")
    }
    static func getFoodById(_ id: Int) async throws -> [String: Any] { try await request("/api/foods/\(id)") }
    static func submitFood(_ record: [String: Any]) async throws -> [String: Any] { try await request("/api/foods", method: "POST", body: record) }
    static func updateFoodDetails(_ id: Int, fields: [String: Any]) async throws -> [String: Any] { try await request("/api/foods/\(id)", method: "PATCH", body: ["fields": fields]) }
    static func addComment(_ id: Int, comment: [String]) async throws -> [String: Any] { try await request("/api/foods/\(id)", method: "PATCH", body: ["comment": comment]) }
    static func deleteFood(_ id: Int) async throws -> [String: Any] { try await request("/api/foods/\(id)", method: "DELETE") }
    static func postTrackPoints(_ points: [[String: Any]]) async throws { _ = try await request("/api/tracks", method: "POST", body: ["points": points]) }
    static func getTrackPoints(day: String) async throws -> [[String: Any]] {
        let r = try await request("/api/tracks?day=\(day)")
        return r["points"] as? [[String: Any]] ?? []
    }
    static func getTrackDays() async throws -> [[String: Any]] {
        let r = try await request("/api/tracks/days")
        return r["days"] as? [[String: Any]] ?? []
    }
}
