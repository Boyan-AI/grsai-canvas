import SwiftUI

/// 画境工作区的深色视觉令牌，映射 Refero 风格的黑、紫、琥珀和深绿色色板。
enum WorkspaceTheme {
    static let void = Color(red: 0, green: 0, blue: 0)
    static let boneWhite = Color(red: 1, green: 1, blue: 1)
    static let ashGray = Color(red: 0.604, green: 0.604, blue: 0.604)
    static let silverMist = Color(red: 0.741, green: 0.741, blue: 0.741)
    static let electricIris = Color(red: 0.502, green: 0.322, blue: 1)
    static let saffronSpark = Color(red: 1, green: 0.722, blue: 0.161)
    static let deepVerdant = Color(red: 0.082, green: 0.518, blue: 0.431)

    /// 用于工作区功能面板的微弱黑色层次，不引入 Material 的模糊和高光。
    static let surface = Color(red: 0.035, green: 0.035, blue: 0.043)
    static let raisedSurface = Color(red: 0.067, green: 0.067, blue: 0.082)
    static let subtleBorder = Color.white.opacity(0.12)
}
