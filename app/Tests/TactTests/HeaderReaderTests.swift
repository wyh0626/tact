import Foundation
import ScreenCaptureKit
import Testing
@testable import Tact

struct HeaderReaderTests {
    /// A refused capture reads as what to do about it, not as an error code.
    @Test func aRefusedCaptureSaysWhatToDo() throws {
        let refused = NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.userDeclined.rawValue)
        let explained = try #require(HeaderReader.explained(refused) as? HeaderError)
        #expect(explained == .screenRecordingDenied)
        #expect(explained.errorDescription?.contains(L10n.tr("屏幕录制", "Screen Recording")) == true)

        let other = NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.failedToStart.rawValue)
        #expect((HeaderReader.explained(other) as NSError).code == other.code)
    }
}
