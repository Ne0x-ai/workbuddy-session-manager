import Foundation

/// 手动分流入口：带 --selftest 参数时跑命令行自检，否则进入 GUI。
/// 不能把 exit() 放进 App.init()——那会与 SwiftUI 的启动流程死锁。
@main
enum Entry {
    static func main() {
        // 工具栏提示默认要悬停半秒才出，慢得跟不上手。AppKit 读这个键决定首次延迟，
        // 越早注册越保险。
        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 100])
        if Headless.runIfRequested() { return }
        WorkBuddySessionManagerApp.main()
    }
}
