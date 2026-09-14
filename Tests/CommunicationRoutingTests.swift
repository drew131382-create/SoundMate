import Foundation

@main
enum CommunicationRoutingTests {
    static func main() {
        let owner = "com.tencent.xinWeChat"
        precondition(CommunicationRoutingPolicy.protectsCallMedia(ownerBundleID: owner, processBundleID: "com.tencent.flue.WeChatAppEx", isInputting: false))
        precondition(CommunicationRoutingPolicy.protectsCallMedia(ownerBundleID: owner, processBundleID: "com.tencent.flue.WeChatAppEx.helper", isInputting: false))
        precondition(CommunicationRoutingPolicy.protectsCallMedia(ownerBundleID: owner, processBundleID: nil, processName: "wxplayer", isInputting: false))
        precondition(CommunicationRoutingPolicy.protectsCallMedia(ownerBundleID: owner, processBundleID: "com.tencent.xinWeChat.WeChatHelper", isInputting: false))
        precondition(CommunicationRoutingPolicy.protectsCallMedia(ownerBundleID: owner, processBundleID: nil, processName: "WeChatAppEx Helper (Renderer)", isInputting: false))
        precondition(!CommunicationRoutingPolicy.protectsCallMedia(ownerBundleID: owner, processBundleID: "com.tencent.flue.WeChatAppEx", isInputting: true))
        precondition(!CommunicationRoutingPolicy.protectsCallMedia(ownerBundleID: owner, processBundleID: nil, processName: "wxplayer", isInputting: true))
        for bundle in [owner, "com.tencent.flue.WeChatAppExOther", "com.apple.FaceTime", "us.zoom.xos", "com.microsoft.teams", nil] {
            precondition(!CommunicationRoutingPolicy.protectsCallMedia(ownerBundleID: owner, processBundleID: bundle, isInputting: false))
        }
        precondition(!CommunicationRoutingPolicy.protectsCallMedia(ownerBundleID: "com.apple.FaceTime", processBundleID: "com.tencent.flue.WeChatAppEx", isInputting: false))
        print("PASS: WeChat media protected; call input, main process and other call apps excluded")
    }
}
