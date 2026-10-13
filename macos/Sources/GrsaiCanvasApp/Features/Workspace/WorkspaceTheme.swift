import SwiftUI

/// 画境工作区的温暖手绘视觉令牌，使用米白、森林绿、天空蓝和暖橙构成动漫感色板。
enum WorkspaceTheme {
    static let void = Color(red: 0.945, green: 0.925, blue: 0.875)
    static let boneWhite = Color(red: 1, green: 0.992, blue: 0.965)
    static let ashGray = Color(red: 0.42, green: 0.38, blue: 0.32)
    static let silverMist = Color(red: 0.52, green: 0.48, blue: 0.42)
    static let electricIris = Color(red: 0.31, green: 0.55, blue: 0.63)
    static let saffronSpark = Color(red: 0.78, green: 0.38, blue: 0.20)
    static let deepVerdant = Color(red: 0.29, green: 0.49, blue: 0.34)

    /// 用于工作区功能面板的微弱黑色层次，不引入 Material 的模糊和高光。
    static let surface = Color(red: 1, green: 0.992, blue: 0.965)
    static let raisedSurface = Color(red: 0.91, green: 0.87, blue: 0.79)
    static let subtleBorder = Color(red: 0.55, green: 0.46, blue: 0.34).opacity(0.30)
}
