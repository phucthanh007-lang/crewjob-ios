import SwiftUI
import WebKit

/// Trang web của CrewJob (Resources/index.html) chạy trong WKWebView.
/// Cầu nối CrewAuth (đăng nhập Google/Apple) và CrewPush (thông báo đẩy) giống bản Android.
struct WebContainer: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        let ucc = WKUserContentController()
        ucc.addUserScript(WKUserScript(source: Bridge.shimJS, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        ucc.add(Bridge.shared, name: "auth")
        ucc.add(Bridge.shared, name: "push")
        cfg.userContentController = ucc

        let web = WKWebView(frame: .zero, configuration: cfg)
        web.navigationDelegate = context.coordinator
        web.uiDelegate = context.coordinator
        web.scrollView.bounces = false
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.isOpaque = false
        Bridge.shared.web = web

        if let url = Bundle.main.url(forResource: "index", withExtension: "html"),
           let html = try? String(contentsOf: url, encoding: .utf8) {
            // baseURL là miền Firebase đã được cấp phép, để Firebase Auth/Firestore chạy đúng nguồn gốc (https)
            web.loadHTMLString(Self.withViewport(html), baseURL: URL(string: "https://crewjob-bdb74.firebaseapp.com"))
        }
        return web
    }
    /// Trang HTML không có thẻ viewport (bản Android tự đặt). Thêm vào để iPhone hiển thị đúng cỡ như Android.
    static func withViewport(_ html: String) -> String {
        let tag = "<meta charset=\"utf-8\">"
        let extra = tag + "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1,maximum-scale=1,viewport-fit=cover\"><style>html{-webkit-text-size-adjust:100%}body{-webkit-touch-callout:none;-webkit-tap-highlight-color:transparent}</style>"
        return html.replacingOccurrences(of: tag, with: extra)
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        // Liên kết ra ngoài (Facebook, Zalo, điện thoại, email...) mở bằng Safari/ứng dụng tương ứng
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else { decisionHandler(.allow); return }
            let host = url.host ?? ""
            let internalHost = host.hasSuffix("firebaseapp.com") || host.hasSuffix("googleapis.com") || host.hasSuffix("gstatic.com") || host.isEmpty || url.scheme == "about" || url.scheme == "blob" || url.scheme == "data"
            if action.navigationType == .linkActivated || !internalHost && action.targetFrame?.isMainFrame == true {
                if ["http", "https", "tel", "mailto", "sms", "zalo", "fb"].contains(url.scheme ?? "") {
                    UIApplication.shared.open(url); decisionHandler(.cancel); return
                }
            }
            decisionHandler(.allow)
        }
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = action.request.url { UIApplication.shared.open(url) }
            return nil
        }
    }
}
