//
//  DisclosureLogContainerView.swift
//  swiftpy-llm
//

import SwiftUI
import SwiftPyViews

struct DisclosureLogContainerView<Label: View, Content: View>: View {
    let tint: Color
    private let label: Label
    private let content: Content
    @State private var isExpanded = false
    @Environment(\.isInWindow) private var isInWindow

    init(
        tint: Color,
        @ViewBuilder content: () -> Content,
        @ViewBuilder label: () -> Label
    ) {
        self.tint = tint
        self.content = content()
        self.label = label()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Capsule()
                .fill(tint.gradient)
                .frame(width: 4)

            VStack(alignment: .leading, spacing: 4) {
                Button {
                    withAnimation {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 8) {
                        label

                        Spacer(minLength: 0)

                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption.bold())
                            .contentTransition(.symbolEffect(.replace))
                            .accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if isExpanded {
                    content
                }
            }
        }
        .padding(8)
        .modifier(Background(tint: tint, isInWindow: isInWindow))
    }
}

// Edge to edge in a card's output, out through the padding the card gives it;
// in a window, rounded to follow the corners around it.
private struct Background: ViewModifier {
    let tint: Color
    let isInWindow: Bool

    func body(content: Content) -> some View {
        if isInWindow {
            content.background(
                tint.opacity(0.1),
                in: ConcentricRectangle(corners: .concentric(minimum: .fixed(8)), isUniform: true)
            )
        } else {
            content
                .background(tint.opacity(0.1))
                .padding(-8)
        }
    }
}
