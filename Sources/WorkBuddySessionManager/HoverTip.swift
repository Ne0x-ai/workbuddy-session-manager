import SwiftUI

/// 自绘的悬浮提示。
///
/// 系统那个走 AppKit 的 NSToolTip：显示要等，鼠标移开后还要赖一会儿才消失，
/// 这两段时机都调不准。这里自己管——悬停一小会儿就出现，一挪走立刻没。
struct HoverTip: ViewModifier {
    let text: String
    /// 出现前的等待。留一小段，免得鼠标扫过工具栏时弹出一排提示。
    let delay: Duration
    @State private var visible = false
    @State private var showTask: Task<Void, Never>?

    init(_ text: String, delay: Duration = .milliseconds(120)) {
        self.text = text
        self.delay = delay
    }

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                if inside {
                    showTask?.cancel()
                    showTask = Task {
                        try? await Task.sleep(for: delay)
                        guard !Task.isCancelled else { return }
                        visible = true
                    }
                } else {
                    showTask?.cancel()
                    visible = false
                }
            }
            .overlay(alignment: .bottom) {
                if visible { bubble.offset(y: 8) }
            }
    }

    private var bubble: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator, lineWidth: 0.5))
            .fixedSize()
            .allowsHitTesting(false)
    }
}

extension View {
    func hoverTip(_ text: String, delay: Duration = .milliseconds(120)) -> some View {
        modifier(HoverTip(text, delay: delay))
    }
}
