import LaileCore
import SwiftUI

/// Lele's little avatar: the 乐 of 莱乐.
public struct LeleAvatar: View {
    var size: CGFloat
    public init(size: CGFloat = 32) { self.size = size }

    public var body: some View {
        Text("乐")
            .font(.system(size: size * 0.55, weight: .heavy, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Theme.accent, in: Circle())
            .accessibilityLabel("Lele")
    }
}

/// One message in the conversation with Lele, with its answer buttons.
public struct LeleBubble: View {
    let message: LeleMessage
    let onAction: (LeleAction) -> Void

    public init(message: LeleMessage, onAction: @escaping (LeleAction) -> Void) {
        self.message = message
        self.onAction = onAction
    }

    private var isMine: Bool { message.author == .person }

    public var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if isMine { Spacer(minLength: 40) } else { avatar }
            VStack(alignment: isMine ? .trailing : .leading, spacing: 8) {
                Text(message.text)
                    .font(.subheadline)
                    .foregroundStyle(isMine ? .white : Theme.text)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(isMine ? Theme.accent : Theme.surface, in: RoundedRectangle(cornerRadius: 18))
                    .overlay(RoundedRectangle(cornerRadius: 18).stroke(isMine ? Color.clear : Theme.surface2, lineWidth: 1))
                if let answer = message.answer {
                    Label(answer, systemImage: "checkmark.circle.fill").font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
                } else if !message.actions.isEmpty {
                    ActionChips(actions: message.actions, onAction: onAction)
                }
            }
            if !isMine { Spacer(minLength: 40) }
        }
    }

    @ViewBuilder private var avatar: some View {
        if message.author == .clinician {
            Image(systemName: "stethoscope").frame(width: 32, height: 32).foregroundStyle(.white).background(Theme.reward, in: Circle())
        } else {
            LeleAvatar()
        }
    }
}

public struct ActionChips: View {
    let actions: [LeleAction]
    let onAction: (LeleAction) -> Void

    public init(actions: [LeleAction], onAction: @escaping (LeleAction) -> Void) {
        self.actions = actions
        self.onAction = onAction
    }

    public var body: some View {
        FlowRow(spacing: 8) {
            ForEach(actions) { action in
                Button { onAction(action) } label: {
                    Label(action.label, systemImage: icon(action.kind))
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(action.kind == .reply ? Theme.accentSoft : Theme.accent, in: Capsule())
                        .foregroundStyle(action.kind == .reply ? Theme.accent : .white)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func icon(_ kind: LeleAction.Kind) -> String {
        switch kind {
        case .reply: return "bubble.left"
        case .startSession: return "play.fill"
        case .joinProgram: return "plus"
        case .openChat: return "text.bubble"
        case .call: return "phone.fill"
        }
    }
}

/// Wraps its children onto new lines, like text.
public struct FlowRow: Layout {
    var spacing: CGFloat
    public init(spacing: CGFloat = 8) { self.spacing = spacing }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width + 0.5 { x = 0; y += row + spacing; row = 0 }
            x += size.width + spacing
            row = max(row, size.height)
            widest = max(widest, x - spacing)
        }
        // Take the full width offered, so placement (which wraps against the same width) matches.
        return CGSize(width: width.isFinite ? width : widest, height: y + row)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX + 0.5 { x = bounds.minX; y += row + spacing; row = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            row = max(row, size.height)
        }
    }
}
