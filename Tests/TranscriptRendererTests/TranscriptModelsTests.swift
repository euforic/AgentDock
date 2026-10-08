import Foundation
import XCTest
@testable import TranscriptRenderer

final class TranscriptModelsTests: XCTestCase {
    func testSourceOrdinalProvidesUniqueStableRowIdentity() throws {
        let data = Data(#"{"type":"response_item","payload":{"type":"message","id":"msg_1","role":"assistant","content":"hello"}}"#.utf8)
        let decoder = TranscriptRecordDecoder()

        let first = try XCTUnwrap(decoder.decode(data, sequence: 1))
        let repeated = try XCTUnwrap(decoder.decode(data, sequence: 2))
        XCTAssertEqual(first.id, "response_item.message:record:1")
        XCTAssertNotEqual(first.id, repeated.id)
        XCTAssertEqual(first.providerEventID, "msg_1")
        XCTAssertEqual(repeated.providerEventID, "msg_1")
    }

    func testMalformedAndUnsupportedRecordsRemainRenderable() throws {
        let decoder = TranscriptRecordDecoder()
        let malformed = try XCTUnwrap(decoder.decode(Data("{".utf8), sequence: 1))
        let unsupported = try XCTUnwrap(decoder.decode(
            Data(#"{"type":"event_msg","payload":{"type":"future_event","id":"new_1"}}"#.utf8),
            sequence: 2
        ))

        XCTAssertEqual(malformed.kind, .malformed)
        XCTAssertEqual(unsupported.kind, .unsupported)
        XCTAssertEqual(unsupported.sourceType, "event_msg.future_event")

        let privateScalar = try XCTUnwrap(decoder.decode(
            Data(#""private scalar content""#.utf8),
            sequence: 3
        ))
        XCTAssertEqual(privateScalar.kind, .malformed)
        XCTAssertFalse(privateScalar.text?.value.contains("private scalar content") == true)
    }

    func testLongOutputIsBoundedWithHonestMetadata() throws {
        let decoder = TranscriptRecordDecoder(textLimit: 8)
        let data = Data(#"{"type":"response_item","payload":{"type":"function_call_output","call_id":"call_1","output":"abcdefghijkl"}}"#.utf8)
        let event = try XCTUnwrap(decoder.decode(data, sequence: 0))
        let text = try XCTUnwrap(event.text)

        XCTAssertEqual(text.value, "abcdefgh")
        XCTAssertEqual(text.originalByteCount, 12)
        XCTAssertTrue(text.isTruncated)
    }

    func testCombiningMarksCannotBypassUTF8ByteLimit() {
        let oversizedCluster = "a" + String(repeating: "\u{0301}", count: 100_000)
        let text = TranscriptText(oversizedCluster, limit: 1_024)

        XCTAssertTrue(text.isTruncated)
        XCTAssertGreaterThan(text.originalByteCount, 100_000)
        XCTAssertLessThanOrEqual(text.value.utf8.count, 1_024)
        XCTAssertNotNil(text.value.data(using: .utf8))
    }

    func testMixedEventsKeepExactOrderWhenPagesMerge() throws {
        let decoder = TranscriptRecordDecoder()
        let records = [
            #"{"type":"response_item","payload":{"type":"message","id":"m1","role":"assistant","content":"one"}}"#,
            #"{"type":"response_item","payload":{"type":"reasoning","id":"r1","summary":"two"}}"#,
            #"{"type":"event_msg","payload":{"type":"task_complete","id":"s1"}}"#,
            #"{"type":"response_item","payload":{"type":"function_call","call_id":"c1","name":"search","arguments":"three"}}"#
        ]
        let events = try records.enumerated().map {
            try XCTUnwrap(decoder.decode(Data($0.element.utf8), sequence: $0.offset))
        }
        let older = TranscriptPage(events: Array(events.prefix(2)), hasOlderEvents: false)
        let current = TranscriptPage(events: Array(events.suffix(2)), hasOlderEvents: true)
        let merged = current.prepending(older)

        XCTAssertEqual(merged.events.map(\.id), events.map(\.id))
        XCTAssertEqual(merged.events.map(\.kind), [.message, .reasoning, .status, .toolCall])
        XCTAssertFalse(merged.hasOlderEvents)
    }

    func testIncrementalPrependPreservesExistingIdentityAndDeduplicatesOverlap() throws {
        let event = TranscriptEvent(
            id: "message:existing",
            sequence: 10,
            kind: .message,
            text: TranscriptText("existing"),
            sourceType: "message"
        )
        let older = TranscriptEvent(
            id: "message:older",
            sequence: 9,
            kind: .message,
            text: TranscriptText("older"),
            sourceType: "message"
        )
        let page = TranscriptPage(events: [event], hasOlderEvents: true)
            .prepending(TranscriptPage(events: [older, event], hasOlderEvents: false))

        XCTAssertEqual(page.events, [older, event])
        XCTAssertEqual(page.events[1].id, event.id)
    }

    func testIncrementalPrependKeepsCurrentVersionOfOverlappingEvent() {
        let current = TranscriptEvent(
            id: "shared",
            sequence: 10,
            kind: .status,
            text: TranscriptText("current"),
            sourceType: "status"
        )
        let staleOlderCopy = TranscriptEvent(
            id: "shared",
            sequence: 10,
            kind: .status,
            text: TranscriptText("stale"),
            sourceType: "status"
        )

        let merged = TranscriptPage(events: [current], hasOlderEvents: true)
            .prepending(TranscriptPage(events: [staleOlderCopy], hasOlderEvents: false))

        XCTAssertEqual(merged.events, [current])
    }

    func testProviderCapabilitiesExplicitlyGateApprovals() {
        XCTAssertTrue(TranscriptProvider.codex.capabilities.supportsApprovals)
        XCTAssertFalse(TranscriptProvider.claude.capabilities.supportsApprovals)

        let approval = TranscriptEvent(
            id: "approval:1",
            sequence: 0,
            kind: .approval,
            text: TranscriptText("private approval detail"),
            sourceType: "approval"
        )
        XCTAssertEqual(approval.availability(for: .codex), .available)
        XCTAssertEqual(
            approval.availability(for: .claude),
            .unavailable("Approval events are not available for this provider.")
        )
        XCTAssertEqual(approval.renderableText(for: .codex)?.value, "private approval detail")
        XCTAssertNil(approval.renderableText(for: .claude))
    }

    func testCommonRecordKindsDecode() throws {
        let decoder = TranscriptRecordDecoder()
        let samples: [(String, TranscriptEventKind)] = [
            (#"{"type":"event_msg","payload":{"type":"patch_apply_end","patch":"diff"}}"#, .patch),
            (#"{"type":"event_msg","payload":{"type":"agent_reasoning","text":"why"}}"#, .reasoning),
            (#"{"type":"response_item","payload":{"type":"custom_tool_call","name":"tool","input":"x"}}"#, .toolCall),
            (#"{"type":"response_item","payload":{"type":"tool_search_output","output":"found"}}"#, .toolOutput),
            (#"{"type":"response_item","payload":{"type":"image_generation_call","prompt":"image"}}"#, .toolCall)
        ]

        for (index, sample) in samples.enumerated() {
            XCTAssertEqual(
                decoder.decode(Data(sample.0.utf8), sequence: index)?.kind,
                sample.1
            )
        }
    }

    func testSensitiveNonConversationMessageIsNotExposed() throws {
        let privateText = "private developer instruction"
        let data = Data(
            #"{"type":"response_item","payload":{"type":"message","id":"d1","role":"developer","content":[{"type":"input_text","text":"\#(privateText)"}]}}"#.utf8
        )

        let event = try XCTUnwrap(TranscriptRecordDecoder().decode(data, sequence: 0))

        XCTAssertEqual(event.kind, .unsupported)
        XCTAssertFalse(event.text?.value.contains(privateText) == true)
        XCTAssertEqual(event.title, "Non-conversation message")
    }

    func testApprovalsErrorsFilesAndFailedPatchesAreClassified() throws {
        let decoder = TranscriptRecordDecoder()
        let samples: [(String, TranscriptEventKind)] = [
            (#"{"type":"event_msg","payload":{"type":"approval_request","message":"Allow?"}}"#, .approval),
            (#"{"type":"event_msg","payload":{"type":"stream_error","message":"Disconnected"}}"#, .error),
            (#"{"type":"response_item","payload":{"type":"file_reference","path":"Sources/App.swift"}}"#, .fileReference),
            (#"{"type":"event_msg","payload":{"type":"patch_apply_end","success":false,"stderr":"Conflict"}}"#, .error)
        ]

        for (index, sample) in samples.enumerated() {
            XCTAssertEqual(
                decoder.decode(Data(sample.0.utf8), sequence: index)?.kind,
                sample.1
            )
        }
    }

    func testInitialPreparationAndIncrementalPrependStayResponsive() throws {
        let decoder = TranscriptRecordDecoder()
        let clock = ContinuousClock()
        let preparationStart = clock.now
        let events = try (0..<5_000).map { index in
            try XCTUnwrap(decoder.decode(
                Data(
                    """
                    {"type":"response_item","payload":{"type":"message","id":"m\(index)","role":"assistant","content":"Result \(index)"}}
                    """.utf8
                ),
                sequence: index
            ))
        }
        let preparationElapsed = preparationStart.duration(to: clock.now)

        let prependStart = clock.now
        let current = TranscriptPage(events: Array(events.suffix(2_500)), hasOlderEvents: true)
        let older = TranscriptPage(events: Array(events.prefix(2_500)), hasOlderEvents: false)
        let merged = current.prepending(older)
        let prependElapsed = prependStart.duration(to: clock.now)

        print(
            "TranscriptPerformance"
                + " preparation_ms=\(milliseconds(preparationElapsed))"
                + " prepend_ms=\(milliseconds(prependElapsed))"
        )
        XCTAssertEqual(merged.events.count, 5_000)
        XCTAssertLessThan(preparationElapsed, .seconds(2))
        XCTAssertLessThan(prependElapsed, .milliseconds(100))
    }

    func testPrependOffsetPreservesVisibleContentAndClampsToBounds() {
        XCTAssertEqual(
            TranscriptScrollOffset.preservedOriginY(
                oldY: 240,
                oldDocumentHeight: 2_000,
                newDocumentHeight: 2_600,
                viewportHeight: 800,
                isFlipped: true
            ),
            840
        )
        XCTAssertEqual(
            TranscriptScrollOffset.preservedOriginY(
                oldY: 240,
                oldDocumentHeight: 2_000,
                newDocumentHeight: 2_600,
                viewportHeight: 800,
                isFlipped: false
            ),
            240
        )
        XCTAssertEqual(
            TranscriptScrollOffset.preservedOriginY(
                oldY: 1_900,
                oldDocumentHeight: 2_000,
                newDocumentHeight: 2_200,
                viewportHeight: 800,
                isFlipped: true
            ),
            1_400
        )
    }

    func testTranscriptScrollElementsHaveStableDistinctIdentity() {
        let eventID = TranscriptScrollElementID.event("event")
        let nextEventID = TranscriptScrollElementID.event("next-event")

        XCTAssertEqual(eventID, TranscriptScrollElementID.event("event"))
        XCTAssertNotEqual(eventID, nextEventID)
        XCTAssertNotEqual(eventID, .loadMore)
        XCTAssertNotEqual(eventID, .bottom)
        XCTAssertNotEqual(TranscriptScrollElementID.loadMore, .bottom)
    }


    private func milliseconds(_ duration: Duration) -> String {
        let parts = duration.components
        let value = Double(parts.seconds) * 1_000
            + Double(parts.attoseconds) / 1_000_000_000_000_000
        return value.formatted(.number.precision(.fractionLength(3)))
    }
}
