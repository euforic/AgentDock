import Combine
import Streamdown

@MainActor
public final class StreamdownRenderModel: ObservableObject {
    @Published private(set) var snapshot: StreamdownRenderSnapshot = .empty

    private let parser: StreamdownRenderActor
    private var renderTask: Task<Void, Never>?
    private var requestID = 0

    public init(parser: StreamdownRenderActor = StreamdownRenderActor()) {
        self.parser = parser
    }

    func render(
        content: String,
        mode: StreamdownMode,
        parseIncompleteMarkdown: Bool,
        normalizeHtmlIndentation: Bool
    ) async {
        requestID += 1
        let currentRequestID = requestID
        let previousSnapshot = snapshot

        renderTask?.cancel()
        renderTask = Task.detached(priority: .userInitiated) { [parser] in
            let nextSnapshot = await parser.renderSnapshot(
                content: content,
                mode: mode,
                parseIncompleteMarkdown: parseIncompleteMarkdown,
                normalizeHtmlIndentation: normalizeHtmlIndentation,
                previous: previousSnapshot
            )

            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard self.requestID == currentRequestID else { return }
                self.snapshot = nextSnapshot
            }
        }
    }

    func cancel() {
        renderTask?.cancel()
        renderTask = nil
    }
}
