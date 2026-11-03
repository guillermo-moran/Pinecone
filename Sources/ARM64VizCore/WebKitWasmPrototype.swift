import Foundation
import WebKit

public struct WasmPrototypeCapabilities: Codable, Sendable {
    public let wasm: Bool
    public let sharedMemory: Bool
    public let crossOriginIsolated: Bool
    public let userAgent: String
}

public struct WasmPrototypeReport: Codable, Sendable {
    public let compileMilliseconds: Double
    public let executionMilliseconds: [Double]
    public let completedBlocks: Int
    public let retiredInstructions: String
    public let registers: [String]
    public let pc: String
    public let pstate: String
    public let ramSample: [UInt8]
    public let memoryBytes: Int
    public let capabilities: WasmPrototypeCapabilities
    public let trapped: String?
    public let engine: String
}

/// Separate execution probe, not a boot backend. Keep its view attached and
/// visible on iOS. Cancellation destroys the worker via a fresh page load.
@MainActor
public final class WebKitWasmPrototype: NSObject, WKNavigationDelegate {
    private let bridge = WasmPrototypeBridge()
    private let scheme = WasmPrototypeResources()
    public private(set) var webView: WKWebView!
    private var ready = false
    private var loading = false
    private var waiters: [CheckedContinuation<Void, Error>] = []
    private var pending: (String, CheckedContinuation<WasmPrototypeReport, Error>)?
    private var watchdog: Task<Void, Never>?

    public override init() {
        super.init()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(scheme, forURLScheme: "pinecone-wasm")
        configuration.userContentController.add(bridge, name: "pineconeWasm")
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        bridge.owner = self
    }

    public func load() async throws {
        if ready { return }
        try await withCheckedThrowingContinuation { continuation in
            waiters.append(continuation)
            if !loading {
                loading = true
                webView.load(URLRequest(url: URL(string: "pinecone-wasm://prototype/index.html")!))
                watchdog = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 15_000_000_000)
                    guard !Task.isCancelled else { return }
                    self?.fail("WebKit worker did not become ready")
                }
            }
        }
    }

    public func run(_ program: ARM64WasmProgram, blocks: UInt32,
                    registers: [UInt64], memorySeeds: [(offset: Int, bytes: [UInt8])] = [],
                    watchAddress: Int = 0x2000) async throws -> WasmPrototypeReport {
        guard registers.count == 32, blocks <= 1_000_000_000,
              watchAddress >= 0, watchAddress <= program.guestRAMBytes - 16,
              memorySeeds.allSatisfy({ $0.offset >= 0 && $0.offset <= program.guestRAMBytes - $0.bytes.count }) else {
            throw ARM64WasmError.invalid("Invalid prototype state or memory seed")
        }
        try await load()
        guard pending == nil else { throw ARM64WasmError.invalid("A prototype run is already active") }
        let id = UUID().uuidString
        let job: [String: Any] = ["kind":"run", "id":id,
            "module":program.module.base64EncodedString(), "pages":program.memoryPages,
            "blocks":blocks, "pc":String(program.basePC, radix:16),
            "registers":registers.map { String($0, radix:16) },
            "memorySeeds":(memorySeeds + [WasmPrototypeReference.codeSeed(program)]).map {
                ["offset":$0.offset, "bytes":$0.bytes] as [String:Any]
            },
            "watchAddress":watchAddress]
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                pending = (id, continuation)
                watchdog = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 90_000_000_000)
                    guard !Task.isCancelled else { return }
                    self?.cancel(reason: "WebKit execution exceeded 90 seconds")
                }
                Task { @MainActor [weak self] in
                    do {
                        _ = try await self?.webView.callAsyncJavaScript("window.pineconeRun(job); return true;",
                            arguments: ["job":job], in: nil, contentWorld: .page)
                    } catch { self?.fail(String(describing:error)) }
                }
            }
        }, onCancel: { Task { @MainActor [weak self] in self?.cancel() } })
    }

    public func cancel(reason: String = "Prototype cancelled") {
        fail(reason)
        ready = false; loading = false
        webView.loadHTMLString("<p>Execution stopped.</p>", baseURL: nil)
    }

    fileprivate func receive(_ body: Any) {
        guard let message = body as? [String:Any], let kind = message["kind"] as? String else { return }
        if kind == "ready" {
            ready = true; loading = false; watchdog?.cancel(); watchdog = nil
            let continuations = waiters; waiters.removeAll()
            continuations.forEach { $0.resume() }
        } else if kind == "fatal" { fail(message["error"] as? String ?? "Worker failed") }
        else if let id = message["id"] as? String, let active = pending, active.0 == id {
            pending = nil; watchdog?.cancel(); watchdog = nil
            do {
                guard kind == "result", let report = message["report"] else {
                    throw ARM64WasmError.invalid(message["error"] as? String ?? "Wasm execution failed")
                }
                let data = try JSONSerialization.data(withJSONObject: report)
                active.1.resume(returning: try JSONDecoder().decode(WasmPrototypeReport.self, from:data))
            } catch { active.1.resume(throwing:error) }
        }
    }
    private func fail(_ text: String) {
        watchdog?.cancel(); watchdog = nil
        let error = ARM64WasmError.invalid(text)
        let continuations = waiters; waiters.removeAll(); loading = false; ready = false
        continuations.forEach { $0.resume(throwing:error) }
        if let active = pending { pending = nil; active.1.resume(throwing:error) }
    }
    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { fail("WebKit content process terminated") }
    private func navigationFailed(_ error: Error) {
        let e = error as NSError
        if e.domain == NSURLErrorDomain && e.code == NSURLErrorCancelled { return }
        fail(String(describing:error))
    }
    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { navigationFailed(error) }
    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { navigationFailed(error) }
}

@MainActor
private final class WasmPrototypeBridge: NSObject, WKScriptMessageHandler {
    weak var owner: WebKitWasmPrototype?
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        owner?.receive(message.body)
    }
}

private final class WasmPrototypeResources: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url, url.host == "prototype",
              ["/index.html", "/worker.js"].contains(url.path),
              let resource = Bundle.module.url(forResource: String(url.path.dropFirst()),
                  withExtension: nil, subdirectory: "WasmPrototype"),
              let data = try? Data(contentsOf: resource) else {
            urlSchemeTask.didFailWithError(ARM64WasmError.invalid("Unknown prototype resource")); return
        }
        let response = HTTPURLResponse(url: url, statusCode:200, httpVersion:"HTTP/1.1",
            headerFields:["Content-Type":url.path.hasSuffix(".js") ? "text/javascript" : "text/html",
                          "Cross-Origin-Resource-Policy":"cross-origin", "Cache-Control":"no-store"])!
        // Entire response is synchronous: stop() cannot race an asynchronous
        // resource callback and leave a cancelled WKURLSchemeTask in use.
        urlSchemeTask.didReceive(response); urlSchemeTask.didReceive(data); urlSchemeTask.didFinish()
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}
