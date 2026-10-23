import UIKit
import WebKit
import AuthenticationServices
import CryptoKit
import FirebaseCore
import FirebaseMessaging
import GoogleSignIn
import UserNotifications

/// Cầu nối giữa trang web và iOS. Cùng giao thức với bản Android:
///   window.__gsCb({idToken}|{appleIdToken,nonce}|{cancelled:true}|{err})   và   window.__pushCb(token)
final class Bridge: NSObject, WKScriptMessageHandler {
    static let shared = Bridge()
    weak var web: WKWebView?

    /// Client ID loại "Web" của dự án Firebase (giống bản Android)
    private let webClientID = "756648034190-rv8v9sct1pi8vn23re675f5fofi9vqvs.apps.googleusercontent.com"
    private var currentNonce = ""

    static let shimJS = """
    (function(){
      var p=function(n,m){window.webkit.messageHandlers[n].postMessage(m||{})};
      window.CrewAuth={available:function(){return true},apple:true,
        signIn:function(){p('auth',{kind:'google'})},signInApple:function(){p('auth',{kind:'apple'})}};
      window.CrewPush={request:function(){p('push',{})}};
      window.CrewNative={docs:function(a){p('docs',{items:a})}};
    })();
    """

    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        let kind = (m.body as? [String: Any])?["kind"] as? String ?? ""
        switch m.name {
        case "auth": kind == "apple" ? signInApple() : signInGoogle()
        case "push": requestPush()
        case "docs": scheduleDocs((m.body as? [String: Any])?["items"] as? [[String: Any]] ?? [])
        default: break
        }
    }

    // MARK: - JS helpers
    private func send(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let json = String(data: data, encoding: .utf8) else { return }
        DispatchQueue.main.async { self.web?.evaluateJavaScript("window.__gsCb&&window.__gsCb(\(json))") }
    }
    func sendPush(_ token: String) {
        let quoted = (try? JSONSerialization.data(withJSONObject: [token]))
            .flatMap { String(data: $0, encoding: .utf8) }.map { String($0.dropFirst().dropLast()) } ?? "\"\""
        DispatchQueue.main.async { self.web?.evaluateJavaScript("window.__pushCb&&window.__pushCb(\(quoted))") }
    }
    private var topVC: UIViewController? {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first?.rootViewController
    }

    // MARK: - Google
    private func signInGoogle() {
        guard let vc = topVC else { send(["err": "no-view"]); return }
        let clientID = FirebaseApp.app()?.options.clientID ?? ""
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID, serverClientID: webClientID)
        GIDSignIn.sharedInstance.signIn(withPresenting: vc) { [weak self] result, error in
            if let error = error as NSError? {
                if error.code == GIDSignInError.canceled.rawValue { self?.send(["cancelled": true]) }
                else { self?.send(["err": error.localizedDescription]) }
                return
            }
            if let tok = result?.user.idToken?.tokenString { self?.send(["idToken": tok]) }
            else { self?.send(["err": "credential"]) }
        }
    }

    // MARK: - Apple (bắt buộc theo quy định App Store khi có đăng nhập Google)
    private func signInApple() {
        currentNonce = Bridge.randomNonce()
        let req = ASAuthorizationAppleIDProvider().createRequest()
        req.requestedScopes = [.email]
        req.nonce = Bridge.sha256(currentNonce)
        let ctl = ASAuthorizationController(authorizationRequests: [req])
        ctl.delegate = self
        ctl.presentationContextProvider = self
        ctl.performRequests()
    }
    private static func randomNonce(_ n: Int = 32) -> String {
        let chars = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        return String((0..<n).map { _ in chars[Int.random(in: 0..<chars.count)] })
    }
    private static func sha256(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Nhac het han giay to (thong bao cuc bo, chay ngay tren may, khong can mang)
    private func scheduleDocs(_ items: [[String: Any]]) {
        let c = UNUserNotificationCenter.current()
        c.getNotificationSettings { s in
            guard s.authorizationStatus == .authorized || s.authorizationStatus == .provisional else { return }
            c.getPendingNotificationRequests { pending in
                let old = pending.map { $0.identifier }.filter { $0.hasPrefix("doc-") }
                c.removePendingNotificationRequests(withIdentifiers: old)
                let fmt = DateFormatter()
                fmt.dateFormat = "yyyy-MM-dd"
                fmt.locale = Locale(identifier: "en_US_POSIX")
                let cal = Calendar.current
                for it in items.prefix(20) {
                    guard let id = it["id"] as? String, let name = it["name"] as? String,
                          let ds = it["expiry"] as? String, let exp = fmt.date(from: ds) else { continue }
                    for d in [90, 30, 7] {
                        guard let day = cal.date(byAdding: .day, value: -d, to: exp) else { continue }
                        var comp = cal.dateComponents([.year, .month, .day], from: day)
                        comp.hour = 9
                        guard let fire = cal.date(from: comp), fire > Date() else { continue }
                        let content = UNMutableNotificationContent()
                        content.title = "Giấy tờ sắp hết hạn"
                        content.body = "\(name) còn \(d) ngày là hết hạn (\(ds))."
                        content.sound = .default
                        let trig = UNCalendarNotificationTrigger(dateMatching: comp, repeats: false)
                        c.add(UNNotificationRequest(identifier: "doc-\(id)-\(d)", content: content, trigger: trig))
                    }
                }
            }
        }
    }

    // MARK: - Push
    private func requestPush() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
            DispatchQueue.main.async {
                if granted { UIApplication.shared.registerForRemoteNotifications() } else { self.sendPush("") }
            }
        }
    }
    func didGetAPNs(_ token: Data) {
        guard FirebaseApp.app() != nil else { sendPush(""); return }
        Messaging.messaging().apnsToken = token
        Messaging.messaging().token { tok, _ in self.sendPush(tok ?? "") }
    }
}

extension Bridge: ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor()
    }
    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization auth: ASAuthorization) {
        guard let cred = auth.credential as? ASAuthorizationAppleIDCredential,
              let data = cred.identityToken, let tok = String(data: data, encoding: .utf8) else {
            send(["err": "credential"]); return
        }
        send(["appleIdToken": tok, "nonce": currentNonce])
    }
    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        if (error as NSError).code == ASAuthorizationError.canceled.rawValue { send(["cancelled": true]) }
        else { send(["err": error.localizedDescription]) }
    }
}
