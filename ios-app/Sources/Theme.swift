import SwiftUI

/// 设计语言 v2 (抖音式简约): 纯黑底 + 白字 + 单一红 accent, 无多余装饰
enum Theme {
    static let bg = Color.black
    static let surface = Color(red: 0.07, green: 0.07, blue: 0.07)
    static let surface2 = Color(red: 0.13, green: 0.13, blue: 0.13)
    static let line = Color(red: 0.16, green: 0.16, blue: 0.16)
    static let text = Color(red: 0.98, green: 0.98, blue: 0.98)
    static let sub = Color(red: 0.55, green: 0.55, blue: 0.57)
    // 历史命名沿用 (gold/gold2), 值已换成 accent 红, 全 App 自动统一
    static let gold = Color(red: 0.996, green: 0.173, blue: 0.333)   // #FE2C55
    static let gold2 = Color(red: 1.0, green: 0.42, blue: 0.55)
    static let cardRadius: CGFloat = 12

    static var goldGradient: LinearGradient {
        LinearGradient(colors: [gold, gold], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// 栏目定义 (id 与网站 data-section / source_section 对应)
struct AppSection: Identifiable, Hashable {
    let id: String          // home/latest/trending/ranking/hsex 或 source_section 值
    let name: String
    let subtitle: String
    let isSource: Bool      // true = 按 source_section 过滤的来源栏目
}
