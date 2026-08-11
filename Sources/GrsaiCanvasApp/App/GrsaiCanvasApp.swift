import SwiftUI

/// Grsai Canvas 的 macOS 应用入口。
@main
struct GrsaiCanvasApp: App {
    @State private var model = WorkspaceViewModel()

    var body: some Scene {
        WindowGroup {
            WorkspaceView(model: model)
                .frame(minWidth: 980, minHeight: 640)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1280, height: 820)
    }
}
