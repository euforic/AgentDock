# Vendored Streamdown Subset

- Upstream: https://github.com/euforicio/streamdown-swift
- Revision: `22981ab9a35c86bd69e275e48f26488c38bc9cdf`
- Imported: 2026-07-29
- License: FSL-1.1-MIT; the upstream license first appeared on 2026-03-16,
  making its future MIT grant effective on 2028-03-16.

AgentDock vendors only the `Streamdown` and `StreamdownUI` products and their
tests. The unused `EuforicAI` product and upstream repository automation are
excluded.

The local manifest preserves the upstream package's Swift 6.2, iOS 26, and
macOS 26 requirements. The source revision includes the theme propagation,
control gating, link-sheet, reduced-motion, and UI-state fixes required by
AgentDock. AgentDock additionally escapes HTML in transcript Markdown before
rendering so untrusted local transcript content cannot execute scripts or load
resources through MarkdownView's HTML web view. HTTP and HTTPS Markdown images
use an inert placeholder renderer and never fetch remote content.
