import Foundation

struct PushPayload {
    let url: URL?

    init(userInfo: [AnyHashable: Any]) {
        let keys = ["url", "link", "deeplink", "click_action"]
        var found: URL?

        for k in keys {
            if let s = userInfo[k] as? String,
               let u = URL(string: s),
               u.scheme != nil {
                found = u
                break
            }
        }
        self.url = found
    }
}
