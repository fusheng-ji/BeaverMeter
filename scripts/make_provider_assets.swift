// Run: swift scripts/make_provider_assets.swift
// Offline rasterization of the checked-in official SVG geometry using WebKit.
import AppKit
import WebKit

@MainActor
final class ProviderAssetRenderer: NSObject, WKNavigationDelegate {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let webView: WKWebView

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 256, height: 256), configuration: configuration)
        super.init()
        webView.navigationDelegate = self
    }

    func start() { webView.loadHTMLString("<html><body></body></html>", baseURL: nil) }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            do {
                let output = root.appendingPathComponent("Design/ProviderAssets")
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                for provider in ["codex", "claude", "cursor", "deepseek"] {
                    let source = try String(contentsOf: root.appendingPathComponent("Design/ProviderSources/\(provider).svg"), encoding: .utf8)
                    let script = #"""
                    const markup = source.includes('xmlns=') ? source : source.replace('<svg ', '<svg xmlns="http://www.w3.org/2000/svg" ');
                    const svg = new DOMParser().parseFromString(markup, 'image/svg+xml').documentElement;
                    if (provider === 'deepseek') {
                        // The official lockup contains the wordmark in a clipped group.
                        for (const element of [...svg.children]) {
                            if (element.tagName !== 'path') element.remove();
                        }
                    }
                    svg.style.color = '#000';
                    document.body.replaceChildren(svg);
                    const bounds = svg.getBBox();
                    const padding = Math.max(bounds.width, bounds.height) * 0.04;
                    svg.setAttribute('viewBox', `${bounds.x-padding} ${bounds.y-padding} ${bounds.width+2*padding} ${bounds.height+2*padding}`);
                    svg.setAttribute('width', '256'); svg.setAttribute('height', '256');
                    svg.setAttribute('preserveAspectRatio', 'xMidYMid meet');
                    const canvas = document.createElement('canvas');
                    canvas.width = canvas.height = 256;
                    const image = new Image();
                    const url = URL.createObjectURL(new Blob([new XMLSerializer().serializeToString(svg)], {type:'image/svg+xml'}));
                    await new Promise((resolve, reject) => { image.onload = resolve; image.onerror = reject; image.src = url; });
                    const context = canvas.getContext('2d');
                    context.drawImage(image, 0, 0, 256, 256);
                    const original = canvas.toDataURL('image/png');
                    context.globalCompositeOperation = 'source-in';
                    context.fillStyle = '#fff'; context.fillRect(0, 0, 256, 256);
                    const template = canvas.toDataURL('image/png');
                    URL.revokeObjectURL(url);
                    return [original, template];
                    """#
                    let value: Any = try await withCheckedThrowingContinuation { continuation in
                        webView.callAsyncJavaScript(script, arguments: ["source": source, "provider": provider], in: nil, in: .page) {
                            continuation.resume(with: $0)
                        }
                    }
                    guard let result = value as? [String], result.count == 2 else {
                        throw CocoaError(.coderReadCorrupt)
                    }
                    for (suffix, encoded) in zip(["", "-template"], result) {
                        guard let payload = encoded.split(separator: ",", maxSplits: 1).last,
                              let data = Data(base64Encoded: String(payload)) else { throw CocoaError(.coderReadCorrupt) }
                        try data.write(to: output.appendingPathComponent(provider + suffix + ".png"), options: .atomic)
                    }
                    print("Rendered \(provider)")
                }
                NSApplication.shared.terminate(nil)
            } catch {
                FileHandle.standardError.write(Data("\(error)\n".utf8))
                exit(1)
            }
        }
    }
}

let application = NSApplication.shared
application.setActivationPolicy(.prohibited)
MainActor.assumeIsolated {
    let renderer = ProviderAssetRenderer()
    renderer.start()
    withExtendedLifetime(renderer) { application.run() }
}
