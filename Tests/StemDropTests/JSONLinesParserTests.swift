import XCTest
@testable import StemDrop

final class JSONLinesParserTests: XCTestCase {
    func testLoadingEvent() {
        let event = JSONLinesParser.parse(#"{"event":"loading"}"#)
        XCTAssertEqual(event, .loading)
    }

    func testProgressEvent() {
        let event = JSONLinesParser.parse(#"{"event":"progress","fraction":0.42}"#)
        XCTAssertEqual(event, .progress(0.42))
    }

    func testStemEvent() {
        let event = JSONLinesParser.parse(#"{"event":"stem","name":"drums","path":"/tmp/drums.wav"}"#)
        XCTAssertEqual(event, .stem(.drums, URL(fileURLWithPath: "/tmp/drums.wav")))
    }

    func testDoneEvent() {
        let event = JSONLinesParser.parse(#"{"event":"done"}"#)
        XCTAssertEqual(event, .done)
    }

    func testErrorEvent() {
        let event = JSONLinesParser.parse(#"{"event":"error","message":"boom"}"#)
        XCTAssertEqual(event, .error("boom"))
    }

    func testGarbageInputReturnsNil() {
        XCTAssertNil(JSONLinesParser.parse("not json at all"))
        XCTAssertNil(JSONLinesParser.parse(#"{"event":"unknown-thing"}"#))
        XCTAssertNil(JSONLinesParser.parse(""))
    }

    /// Simulates the partial-line reassembly a line-buffered stdout reader
    /// must perform: a JSON object split across two stdout reads should
    /// only parse once the trailing newline arrives.
    func testPartialLineReassembly() {
        var buffer = ""
        var events: [EngineEvent] = []

        func feed(_ chunk: String) {
            buffer += chunk
            var lines = buffer.components(separatedBy: "\n")
            buffer = lines.removeLast()
            for line in lines {
                if let event = JSONLinesParser.parse(line) {
                    events.append(event)
                }
            }
        }

        feed(#"{"event":"progress","#)
        XCTAssertTrue(events.isEmpty, "should not parse an incomplete line")

        feed("\"fraction\":0.5}\n")
        XCTAssertEqual(events, [.progress(0.5)])
    }
}
