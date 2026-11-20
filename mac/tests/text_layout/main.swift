import AppKit
import WebKit

final class Probe: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    let web: WKWebView
    let script: String
    var result: Int32?

    init(resource: URL, catalog: URL, checks: URL, language: String, width: CGFloat) throws {
        let configuration = WKWebViewConfiguration()
        let strings = language == "en" ? [:] : try JSONDecoder().decode([String: String].self, from: Data(contentsOf: catalog))
        let settings = try JSONSerialization.data(withJSONObject: ["language": language, "strings": strings])
        configuration.userContentController.addUserScript(WKUserScript(source: "window.liberatorLocalization = " + String(decoding: settings, as: UTF8.self), injectionTime: .atDocumentStart, forMainFrameOnly: true))
        script = try String(contentsOf: checks, encoding: .utf8)
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: 760), configuration: configuration)
        super.init()
        configuration.userContentController.add(self, name: "nm")
        web.navigationDelegate = self
        web.loadFileURL(resource.appendingPathComponent("index.html"), allowingReadAccessTo: resource)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {}
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            do {
                let value = try await webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page)
                print(value ?? "OK")
                self.result = 0
            } catch {
                print(error)
                self.result = 1
            }
        }
    }
}

let args = CommandLine.arguments
guard args.count == 4, let width = Int(args[3]), width > 0 else {
    print("Usage: text-layout-test <mac source directory> <en|zh-Hans|zh-Hant> <width>")
    exit(64)
}
_ = NSApplication.shared
let root = URL(fileURLWithPath: args[1])
let lang = args[2]
let probe = try Probe(resource: root.appendingPathComponent("Resources"),
                      catalog: root.appendingPathComponent("Localizations/\(lang).lproj/Interface.json"),
                      checks: root.appendingPathComponent("tests/text_layout/checks.js"),
                      language: lang, width: CGFloat(width))
let deadline = Date().addingTimeInterval(18)
while probe.result == nil && Date() < deadline {
    _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
}
if probe.result == nil { print("WebKit probe timed out") }
exit(probe.result ?? 1)
