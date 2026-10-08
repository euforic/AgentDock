import SwiftUI
import TranscriptRenderer

@main
struct TranscriptRendererShowcaseApp: App {
    var body: some Scene {
        WindowGroup {
            TranscriptView(document: ShowcaseDocument.document)
                .frame(minWidth: 920, minHeight: 720)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
    }
}

private enum ShowcaseDocument {
    static let document = TranscriptDocument(
        id: "visual-acceptance",
        sessionID: "visual-acceptance",
        provider: .codex,
        events: [
            event(
                id: "user",
                sequence: 0,
                kind: .message,
                role: .user,
                text: """
                Build a compact transcript renderer with **safe links**, tables, and code that stays readable.
                """
            ),
            event(
                id: "assistant",
                sequence: 1,
                kind: .message,
                role: .assistant,
                text: """
                ## Rendering plan

                The transcript keeps prose at a comfortable measure and preserves source order.

                - User prompts use a restrained surface.
                - Assistant responses remain open and selectable.
                - Activity stays compact until expanded.

                > Long output is bounded before it reaches layout.

                | Content | Treatment |
                | --- | --- |
                | Markdown | Native hierarchy |
                | Code | Highlighted and horizontally scrollable |

                ```swift
                struct StableRow: Identifiable {
                    let id: String
                    let content: String
                }
                ```
                """
            ),
            event(
                id: "reasoning",
                sequence: 2,
                kind: .reasoning,
                title: "Reasoning",
                text: "Checked the requested visual rhythm against the available reference constraints."
            ),
            event(
                id: "command",
                sequence: 3,
                kind: .command,
                title: "Run focused renderer tests",
                text: "swift test --filter TranscriptRendererTests"
            ),
            event(
                id: "tool",
                sequence: 4,
                kind: .toolOutput,
                title: "Test result",
                text: """
                Test Suite 'TranscriptRendererTests' passed.
                Executed 12 tests, with 0 failures.
                """
            ),
            event(
                id: "patch",
                sequence: 5,
                kind: .patch,
                title: "3 files changed",
                text: """
                Sources/TranscriptRenderer/TranscriptView.swift | +420
                Tests/TranscriptRendererTests/...               | +120
                """
            ),
            event(
                id: "error",
                sequence: 6,
                kind: .error,
                title: "Example error",
                text: "The record ended before its payload was complete."
            ),
            event(
                id: "unsupported",
                sequence: 7,
                kind: .unsupported,
                title: "Unsupported transcript record",
                text: "response_item.future_event"
            ),
            TranscriptEvent(
                id: "long-output",
                sequence: 8,
                kind: .toolOutput,
                title: "Long bounded output",
                text: TranscriptText(String(repeating: "0123456789abcdef\n", count: 5_000)),
                sourceType: "response_item.function_call_output"
            )
        ]
    )

    private static func event(
        id: String,
        sequence: Int,
        kind: TranscriptEventKind,
        role: TranscriptMessageRole = .unknown,
        title: String? = nil,
        text: String
    ) -> TranscriptEvent {
        TranscriptEvent(
            id: id,
            sequence: sequence,
            kind: kind,
            role: role,
            title: title,
            text: TranscriptText(text),
            sourceType: "showcase.\(kind.rawValue)"
        )
    }
}
