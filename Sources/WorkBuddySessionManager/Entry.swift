import Foundation

/// 手动分流入口：带 --selftest 参数时跑命令行自检，否则进入 GUI。
/// 不能把 exit() 放进 App.init()——那会与 SwiftUI 的启动流程死锁。
@main
enum Entry {
    static func main() {
        if Headless.runIfRequested() { return }
        WorkBuddySessionManagerApp.main()
    }
}
