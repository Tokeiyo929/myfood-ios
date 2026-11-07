import Foundation

@main
enum CoreTests {
    @MainActor
    static func main() async throws {
        setvbuf(stdout, nil, _IOLBF, 0) // 行缓冲：管道/tee 下也能看到逐条 PASS，用于定位卡死点
        var failures = 0
        try await CoreRegression.run { ok, message in
            print("\(ok ? "PASS" : "FAIL") \(message)")
            if !ok { failures += 1 }
        }
        precondition(failures == 0, "\(failures) regression failures")
        print("RESULT: ALL PASS")
    }
}
