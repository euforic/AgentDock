# Third-Party Notices

The AgentDock app includes Sparkle. Release app bundles include its complete
license text under
`AgentDock.app/Contents/Resources/Licenses/`.

| Component | Version | License |
| --- | --- | --- |
| [Sparkle](https://github.com/sparkle-project/Sparkle) | 2.9.6 | MIT |

The separate TranscriptRenderer library and TranscriptRendererShowcase executable
use the following components. They are not linked into the AgentDock app or
shortcut launcher and their license texts are not included in the app bundle.
When distributing either renderer product, include the complete license and
notice texts from the vendored subset and its resolved dependency checkouts.

| Component | Version | License |
| --- | --- | --- |
| [Streamdown Swift subset](Vendor/streamdown-swift) | vendored | [Functional Source License 1.1 with future MIT grant](Vendor/streamdown-swift/LICENSE) |
| [MarkdownView](https://github.com/LiYanan2004/MarkdownView) | 3.0.0 | MIT |
| [swift-markdown](https://github.com/swiftlang/swift-markdown) | 0.8.0 | Apache License 2.0 with Runtime Library Exception |
| [Highlightr](https://github.com/raspu/Highlightr) | 2.3.0 | MIT |
| [highlight.js](https://github.com/highlightjs/highlight.js) | 11.11.1 | BSD 3-Clause |
| [RichText](https://github.com/LiYanan2004/RichText) | 1.0.0 | MIT |
| [swift-cmark](https://github.com/swiftlang/swift-cmark) | 0.8.0 | BSD-style and embedded component notices |

Dependency versions are pinned in [Package.resolved](Package.resolved). This
file is informational and does not replace the complete license texts.
