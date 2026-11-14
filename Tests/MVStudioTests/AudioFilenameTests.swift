import XCTest
@testable import MVStudio

final class AudioFilenameTests: XCTestCase {
    func testTempoSpecifications() {
        for (name, expected) in [("曲_bpm128.wav", 128.0), ("曲_95bpm.mp3", 95),
                                 ("曲(BPM140).aiff", 140), ("曲 123.5BpM.wav", 123.5),
                                 ("bpm20.wav", 20), ("300bpm.wav", 300),
                                 ("bpm999_120bpm.wav", 120), ("90bpm_bpm130.wav", 90)] {
            XCTAssertEqual(AudioFilename.bpm(in: URL(fileURLWithPath: "/tmp/\(name)")), expected, name)
        }
    }

    func testIgnoresMissingInvalidAndDirectorySpecifications() {
        for name in ["曲.wav", "120.wav", "bpm.wav", "bpm19.wav", "301bpm.wav",
                     "1120bpm.wav", "bpm1200.wav", "1.120bpm.wav"] {
            XCTAssertNil(AudioFilename.bpm(in: URL(fileURLWithPath: "/tmp/bpm150/\(name)")), name)
        }
    }
}
