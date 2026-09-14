import Foundation

enum CommunicationRoutingPolicy {
    /// WeChat's web/media host may play Channels while the main process owns
    /// the call. Protect that separate output without tapping the call itself.
    static func protectsCallMedia(
        ownerBundleID: String,
        processBundleID: String?,
        processName: String? = nil,
        isInputting: Bool
    ) -> Bool {
        guard ownerBundleID.lowercased() == "com.tencent.xinwechat", !isInputting else {
            return false
        }

        let bundleID = processBundleID?.lowercased() ?? ""
        let executableName = processName?.lowercased() ?? ""

        // WeChat has used several output-only media hosts across releases.
        // Keep the call process excluded, but route these media hosts through
        // the unity-gain path while macOS communication ducking is active.
        let isWeChatAppEx = bundleID == "com.tencent.flue.wechatappex"
            || bundleID.hasPrefix("com.tencent.flue.wechatappex.")
        let isWeChatHelper = bundleID == "com.tencent.xinwechat.wechathelper"
            || bundleID.hasPrefix("com.tencent.xinwechat.wechathelper.")
        let isKnownMediaExecutable = executableName == "wxplayer"
            || executableName.hasPrefix("wechatappex")
            || executableName.hasPrefix("wechathelper")

        return isWeChatAppEx || isWeChatHelper || isKnownMediaExecutable
    }
}
