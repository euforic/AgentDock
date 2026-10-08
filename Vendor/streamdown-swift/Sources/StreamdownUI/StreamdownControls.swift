public struct StreamdownControls: Sendable {
    public let table: Table
    public let code: Code
    public let mermaid: Mermaid

    public struct Table: Sendable {
        public let enabled: Bool
        public let copy: Bool
        public let download: Bool
        public let fullscreen: Bool

        public init(
            enabled: Bool = true,
            copy: Bool = true,
            download: Bool = false,
            fullscreen: Bool = false
        ) {
            self.enabled = enabled
            self.copy = copy
            self.download = download
            self.fullscreen = fullscreen
        }
    }

    public struct Code: Sendable {
        public let enabled: Bool
        public let copy: Bool
        public let download: Bool
        public let lineNumbers: Bool

        public init(enabled: Bool = true, copy: Bool = true, download: Bool = false, lineNumbers: Bool = false) {
            self.enabled = enabled
            self.copy = copy
            self.download = download
            self.lineNumbers = lineNumbers
        }
    }

    public struct Mermaid: Sendable {
        public let enabled: Bool
        public let copy: Bool
        public let download: Bool
        public let fullscreen: Bool
        public let panZoom: Bool

        public init(
            enabled: Bool = true,
            copy: Bool = true,
            download: Bool = false,
            fullscreen: Bool = false,
            panZoom: Bool = false
        ) {
            self.enabled = enabled
            self.copy = copy
            self.download = download
            self.fullscreen = fullscreen
            self.panZoom = panZoom
        }
    }

    public init(
        table: Table = Table(),
        code: Code = Code(),
        mermaid: Mermaid = Mermaid()
    ) {
        self.table = table
        self.code = code
        self.mermaid = mermaid
    }

    public static let `default` = StreamdownControls()
}
