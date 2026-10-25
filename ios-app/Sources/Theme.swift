import SwiftUI

/// 新版设计语言: 影院黑 + 流光金 (与设计原型一致)
enum Theme {
    static let bg = Color(red: 0.027, green: 0.027, blue: 0.031)
    static let surface = Color(red: 0.07, green: 0.07, blue: 0.078)
    static let surface2 = Color(red: 0.102, green: 0.102, blue: 0.118)
    static let line = Color(red: 0.149, green: 0.149, blue: 0.169)
    static let text = Color(red: 0.957, green: 0.945, blue: 0.918)
    static let sub = Color(red: 0.608, green: 0.588, blue: 0.541)
    static let gold = Color(red: 0.851, green: 0.671, blue: 0.306)
    static let gold2 = Color(red: 0.941, green: 0.804, blue: 0.522)
    static let cardRadius: CGFloat = 18

    static var goldGradient: LinearGradient {
        LinearGradient(colors: [gold2, gold], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// 栏目定义 (id 与网站 data-section / source_section 对应)
struct AppSection: Identifiable, Hashable {
    let id: String          // home/latest/trending/ranking/hsex 或 source_section 值
    let name: String
    let subtitle: String
    let isSource: Bool      // true = 按 source_section 过滤的来源栏目
}
