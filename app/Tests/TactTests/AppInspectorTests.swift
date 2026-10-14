import Foundation
import Testing
@testable import Tact

struct AppInspectorTests {
    @Test func aReportSaysWhyItIsEmpty() throws {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("inspect-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: out) }
        #expect(AppInspector.run(bundleID: "io.github.wyh0626.tact.not-running", output: out.path))
        let report = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: out)) as? [String: Any])
        #expect(report["running"] as? Bool == false)
        #expect((report["problems"] as? [String])?.contains(L10n.tr("应用没有在运行", "The app is not running")) == true)
        #expect(report["accessibility"] == nil && report["ocr"] == nil)
    }

    @Test func identifiersNeverCarryNames() {
        #expect(AppInspector.identifierShape("chat_message_list") == "chat_message_list")
        #expect(AppInspector.identifierShape("session_item_张三") == "session_item_*")
        #expect(AppInspector.identifierShape("session_item_filehelper") == "session_item_*")
        #expect(AppInspector.identifierShape("wxid_a1b2c3") == "(other)")
        #expect(AppInspector.identifierShape("张三") == "(other)")
        #expect(AppInspector.identifierShape(String(repeating: "a", count: 49)) == "(other)")
    }

    @Test func aBubbleSideComesFromItsGaps() {
        let list = CGRect(x: 300, y: 0, width: 800, height: 600)
        let avatar = CGRect(x: 320, y: 10, width: 36, height: 36)
        let text = CGRect(x: 366, y: 10, width: 300, height: 40)
        #expect(AppInspector.side(of: [avatar, text], in: list) == .left)
        let mine = CGRect(x: 744, y: 10, width: 300, height: 40)
        let myAvatar = CGRect(x: 1054, y: 10, width: 36, height: 36)
        #expect(AppInspector.side(of: [mine, myAvatar], in: list) == .right)
        // A row as wide as the list says nothing about the sender.
        let row = CGRect(x: 300, y: 10, width: 800, height: 40)
        #expect(AppInspector.side(of: [row], in: list) == .unclear)
        #expect(AppInspector.side(of: [], in: list) == .unclear)
        let centred = CGRect(x: 600, y: 10, width: 200, height: 20)
        #expect(AppInspector.side(of: [centred], in: list) == .unclear)
    }
}
