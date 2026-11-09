import SwiftUI

// @main SwiftUI 生命周期（替代 AppDelegate/SceneDelegate/MainTabBarController）
// tab 布局：0 地图 | 1 轨迹 | 2 历史(中心) | 3 设置 | 4 摘抄
@main
@MainActor
struct MyFoodApp: App {
    // 单例注入：SmokeTour/AutoTest 驱动 AppModel.shared，必须与 UI 用同一个实例
    @State private var app = AppModel.shared

    init() {
        #if DEBUG
        if AutoTest.enabled || SmokeTour.enabled {
            TestFixture.install() // 测试会话：fixture 服务端，不走离线同步
        } else {
            Self.startSync()
        }
        #else
        Self.startSync()
        #endif
        // 轨迹默认记录：启动即自动开始（测试模式跳过，避免首启弹窗干扰冒烟截图）
        if !SmokeTour.enabled, !AutoTest.enabled {
            TrackRecorder.shared.start()
        }
    }

    // 离线同步：启动/恢复联网时先静默拉取远端存暂存（git fetch，失败静默），
    // 再排空队列自动补传——冲突记录的队列项跳过，留给手动同步解决冲突后推送
    static func startSync() {
        NetworkMonitor.shared.start()
        let auto: () async throws -> Void = {
            await SyncDiff.fetchAndStash()
            try? await SyncEngine.drain(conflictIds: SyncDiff.compute().conflictIds)
        }
        NetworkMonitor.shared.onReconnect = { Task { try? await auto() } }
        Task { try? await auto() }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .task {
                    SmokeTour.start() // CI 冒烟巡访（仅 -autoSmoke 时生效，内部有防重入）
                    AutoTest.start() // CI 自测（仅 -autoTest 时生效，内部有防重入）
                }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        TabView(selection: $app.tab) {
            NavigationStack { FoodMapView() }
                .tabItem { Label("地图", systemImage: "map") }
                .tag(AppTab.map)
            TrackRootView()
                .tabItem { Label("轨迹", systemImage: "calendar") }
                .tag(AppTab.tracks)
            HistoryView()
                .tabItem { Label("历史", systemImage: "clock") }
                .tag(AppTab.history)
            NavigationStack { SettingsView() }
                .tabItem { Label("设置", systemImage: "gearshape") }
                .tag(AppTab.settings)
            NavigationStack { QuotesView() }
                .tabItem { Label("摘抄", systemImage: "text.quote") }
                .tag(AppTab.quotes)
        }
        .tint(Theme.primary)
    }
}

enum AppTab: Hashable {
    case map, tracks, history, settings, quotes
}

// 全局状态容器：页面 ViewModel 挂这里，冒烟巡访据此驱动与断言（替代原 UIViewController 层级遍历）
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    var tab: AppTab = AutoTest.enabled ? .quotes : .history // 自测先打开无需配置依赖的摘抄页
    var historyPath: [Int] = [] // 历史 tab 导航栈（详情页）
    var daysPath: [TrackDestination] = [] // 轨迹 tab 导航栈（每日记录/某天）

    let history = HistoryViewModel()
    let detail = DetailViewModel()
    let foodMap = FoodMapViewModel()
    let tracks = TrackViewModel()
    let dayVM = TrackViewModel()
    let days = TrackDaysViewModel()
    let quotes = QuotesViewModel()
}
