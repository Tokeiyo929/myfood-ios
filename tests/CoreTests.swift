import Foundation

@main
enum CoreTests {
    @MainActor
    static func main() async throws {
        var failures = 0
        try await CoreRegression.run { ok, message in
            print("\(ok ? "PASS" : "FAIL") \(message)")
            if !ok { failures += 1 }
        }
        precondition(failures == 0, "\(failures) regression failures")
        print("RESULT: ALL PASS")
    }
}
