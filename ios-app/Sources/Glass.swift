import SwiftUI

/// 液态玻璃 (Liquid Glass) 质感组件 —— 性能策略:
/// - 静态玻璃 (默认): 半透明渐变填充 + 高光渐变描边, **不挂实时背景模糊**,
///   列表/网格里几十个卡片同屏也几乎零额外开销。
/// - 活玻璃 (live: true): ultraThinMaterial 实时模糊, 只用在悬浮元素
///   (刷视频按钮、撤销条、置顶栏等数量恒定的地方)。
/// - 阴影默认关, 只有悬浮层开一层柔和阴影, 避免同屏多重阴影的渲染开销。
extension View {
    func glassPanel(_ radius: CGFloat = Theme.cardRadius, live: Bool = false, shadow: Bool = false) -> some View {
        self
            .background(
                ZStack {
                    if live {
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .fill(.ultraThinMaterial)
                    }
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.white.opacity(live ? 0.13 : 0.075),
                                         Color.white.opacity(0.02)],
                                startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(0.38),
                                     Color.white.opacity(0.07),
                                     Color.white.opacity(0.16)],
                            startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .shadow(color: shadow ? Color.black.opacity(0.28) : .clear,
                    radius: shadow ? 14 : 0, y: shadow ? 6 : 0)
    }

    /// 圆形活玻璃按钮面 (刷视频右侧栏等悬浮在视频上的按钮)
    func glassCircle() -> some View {
        self
            .background(
                ZStack {
                    Circle().fill(.ultraThinMaterial)
                    Circle().fill(Color.white.opacity(0.10))
                }
            )
            .overlay(
                Circle().strokeBorder(
                    LinearGradient(colors: [Color.white.opacity(0.45), Color.white.opacity(0.10)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: 1)
            )
            .clipShape(Circle())
    }

    /// 胶囊玻璃 (搜索框、频道 chips、模式切换的底)
    func glassCapsule(live: Bool = false) -> some View {
        glassPanel(99, live: live)
    }
}
