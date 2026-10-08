import SwiftUI
import Foundation

#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif
#if canImport(WebKit)
import WebKit
#endif

public struct StreamdownMermaidView: View {
    let source: String
    let panZoom: Bool

    @Environment(\.streamdownTheme) private var theme

    public init(source: String, panZoom: Bool = false) {
        self.source = source
        self.panZoom = panZoom
    }

    public var body: some View {
        if source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            VStack {
                Text("Empty Mermaid source")
                    .font(.caption)
                    .foregroundStyle(theme.colors.mutedForeground)
            }
            .frame(maxWidth: .infinity, minHeight: 120)
            .background(theme.colors.tertiaryBackground)
        } else {
            StreamdownMermaidHost(source: source, panZoom: panZoom)
                .frame(minHeight: 140)
                .frame(maxWidth: .infinity)
                .background(theme.colors.tertiaryBackground)
        }
    }
}

private struct StreamdownMermaidHost: View {
    let source: String
    let panZoom: Bool

    @Environment(\.streamdownTheme) private var theme

    var body: some View {
        #if canImport(WebKit)
        _StreamdownMermaidWebView(source: source, panZoom: panZoom)
        #else
        Text("Mermaid is not supported on this platform")
            .font(.caption)
            .foregroundStyle(theme.colors.mutedForeground)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        #endif
    }
}

#if canImport(WebKit)
#if canImport(UIKit)
private struct _StreamdownMermaidWebView: UIViewRepresentable {
    let source: String
    let panZoom: Bool

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = panZoom
        webView.scrollView.bounces = false
        webView.scrollView.alwaysBounceVertical = false
        webView.scrollView.alwaysBounceHorizontal = false
        webView.scrollView.isUserInteractionEnabled = true
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        let payload = jsonPayload(source)
        let html = mermaidHTML(payload: payload, panZoom: panZoom)
        webView.scrollView.minimumZoomScale = panZoom ? 3 : 1
        webView.scrollView.maximumZoomScale = panZoom ? 3 : 1
        webView.loadHTMLString(html, baseURL: URL(string: "https://cdn.jsdelivr.net"))
    }
}

#elseif canImport(AppKit)
private struct _StreamdownMermaidWebView: NSViewRepresentable {
    let source: String
    let panZoom: Bool

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.setValue(false, forKey: "drawsBackground")
        return view
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        let payload = jsonPayload(source)
        let html = mermaidHTML(payload: payload, panZoom: panZoom)
        nsView.loadHTMLString(html, baseURL: URL(string: "https://cdn.jsdelivr.net"))
    }
}
#endif

private func jsonPayload(_ source: String) -> String {
    let payload = [source]
    guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
          let json = String(data: data, encoding: .utf8)
    else {
        return "[]"
    }
    return json
}

private func mermaidHTML(payload: String, panZoom: Bool) -> String {
    let panZoomStyle = panZoom
        ? "body { overflow: scroll; } .mermaid svg { width: 100%; }"
        : "body { overflow: hidden; } .mermaid svg { width: 100%; }"

    return """
        <!doctype html>
        <html>
          <head>
            <meta name="viewport" content="width=device-width, initial-scale=1.0" />
            <script src="https://cdn.jsdelivr.net/npm/mermaid@10/dist/mermaid.min.js"></script>
            <style>
                html, body {
                    margin: 0;
                    padding: 0;
                    width: 100%;
                    height: 100%;
                    background: transparent;
                }
                .container {
                    width: 100%;
                    height: 100%;
                    display: flex;
                    align-items: center;
                    justify-content: flex-start;
                    overflow: auto;
                    padding: 8px;
                }
                .mermaid {
                    width: 100%;
                    white-space: nowrap;
                }
                .mermaid svg {
                    max-width: 100%;
                    height: auto;
                }
                .error {
                    color: #9ca3af;
                    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
                    font-size: 12px;
                }
                \(panZoomStyle)
            </style>
          </head>
          <body>
            <div class="container">
              <div id="diagram" class="mermaid"></div>
            </div>
            <script>
              (function() {
                const payload = \(payload);
                const diagramText = payload[0] || '';
                const diagram = document.getElementById('diagram');
                diagram.textContent = diagramText;

                try {
                  mermaid.initialize({
                    startOnLoad: true,
                    securityLevel: 'loose',
                    theme: window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'default',
                    flowchart: { useMaxWidth: true, htmlLabels: true },
                  });
                  mermaid.run({ nodes: [diagram] });
                } catch (_e) {
                  diagram.className = 'error';
                  diagram.textContent = 'Unable to render Mermaid diagram';
                }
              })();
            </script>
          </body>
        </html>
        """
}
#endif
