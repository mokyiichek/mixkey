import AppKit
import MixKeyCore

/// A small, one-line bar of numbered choices shown just under the cursor.
final class CandidatePanel: NSPanel {
    private let view = CandidateView()
    var onSelect: ((Int) -> Void)? {
        get { view.onSelect }
        set { view.onSelect = newValue }
    }

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 200, height: 30),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.cursorWindow)) - 1)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        contentView = view
    }

    struct Model {
        var items: [CandidateView.Item]
        /// -1 = nothing highlighted (the inline text is what will be sent)
        var highlighted: Int
        var hint: String
    }

    func show(_ model: Model, cursorRect: NSRect) {
        view.model = model
        let size = view.measure()
        var origin = NSPoint(x: cursorRect.minX - 6, y: cursorRect.minY - size.height - 3)
        let screen = NSScreen.screens.first { $0.frame.contains(cursorRect.origin) } ?? NSScreen.main
        if let vf = screen?.visibleFrame {
            if origin.y < vf.minY { origin.y = cursorRect.maxY + 3 }
            origin.x = min(max(origin.x, vf.minX + 2), vf.maxX - size.width - 2)
        }
        setFrame(NSRect(origin: origin, size: size), display: true)
        view.needsDisplay = true
        orderFrontRegardless()
    }

    func hide() { orderOut(nil) }
}

final class CandidateView: NSView {
    struct Item {
        var number: Int
        var text: String
        var reading: String?
        var badge: String?
    }

    var model = CandidatePanel.Model(items: [], highlighted: -1, hint: "")
    var onSelect: ((Int) -> Void)?
    private var itemRects: [NSRect] = []
    private let padX: CGFloat = 8
    private let padY: CGFloat = 5
    private let gap: CGFloat = 14

    override var isFlipped: Bool { true }

    private var fontSize: CGFloat { max(12, Settings.shared.fontSize) }
    private var itemFont: NSFont { .systemFont(ofSize: fontSize) }
    private var numberFont: NSFont { .monospacedDigitSystemFont(ofSize: fontSize * 0.62, weight: .semibold) }
    private var smallFont: NSFont { .systemFont(ofSize: max(10, fontSize * 0.55)) }

    private func parts(_ item: Item) -> (num: NSAttributedString?, text: NSAttributedString, badge: NSAttributedString?, reading: NSAttributedString?) {
        let num = item.number > 0 ? NSAttributedString(string: "\(item.number)", attributes: [.font: numberFont, .foregroundColor: NSColor.secondaryLabelColor]) : nil
        let text = NSAttributedString(string: item.text, attributes: [.font: itemFont, .foregroundColor: NSColor.labelColor])
        let badge = item.badge.map { NSAttributedString(string: $0, attributes: [.font: smallFont, .foregroundColor: NSColor.systemPurple]) }
        let reading = item.reading.map { NSAttributedString(string: $0, attributes: [.font: smallFont, .foregroundColor: NSColor.secondaryLabelColor]) }
        return (num, text, badge, reading)
    }

    /// Lays the items out in one row; returns the size the bar should be.
    func measure() -> NSSize {
        itemRects.removeAll()
        let hasReading = model.items.contains { $0.reading != nil }
        let lineH = ceil(itemFont.ascender - itemFont.descender + itemFont.leading)
        let rowH = lineH + (hasReading ? ceil(smallFont.ascender - smallFont.descender) : 0)
        var x = padX
        for item in model.items {
            let p = parts(item)
            var w = p.text.size().width
            if let n = p.num { w += n.size().width + 4 }
            if let b = p.badge { w += b.size().width + 3 }
            if let r = p.reading { w = max(w, r.size().width + (p.num.map { $0.size().width + 4 } ?? 0)) }
            itemRects.append(NSRect(x: x - 4, y: padY - 2, width: ceil(w) + 8, height: rowH + 4))
            x += ceil(w) + gap
        }
        if !model.hint.isEmpty {
            x += NSAttributedString(string: model.hint, attributes: [.font: smallFont]).size().width
        } else {
            x -= gap
        }
        return NSSize(width: ceil(x + padX), height: ceil(rowH + 2 * padY))
    }

    override func draw(_ dirtyRect: NSRect) {
        let bg = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        NSColor.windowBackgroundColor.withAlphaComponent(0.98).setFill()
        bg.fill()
        NSColor.separatorColor.setStroke()
        bg.lineWidth = 1
        bg.stroke()

        for (i, item) in model.items.enumerated() where i < itemRects.count {
            let r = itemRects[i]
            if i == model.highlighted {
                NSColor.controlAccentColor.withAlphaComponent(0.25).setFill()
                NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5).fill()
            }
            let p = parts(item)
            var x = r.minX + 4
            let y = r.minY + 2
            if let n = p.num {
                n.draw(at: NSPoint(x: x, y: y + (itemFont.capHeight - numberFont.capHeight) + 1))
                x += n.size().width + 4
            }
            let textX = x
            p.text.draw(at: NSPoint(x: x, y: y))
            x += p.text.size().width + 3
            if let b = p.badge { b.draw(at: NSPoint(x: x, y: y + (itemFont.capHeight - smallFont.capHeight))) }
            if let rd = p.reading { rd.draw(at: NSPoint(x: textX, y: y + p.text.size().height - 3)) }
        }
        if !model.hint.isEmpty {
            let h = NSAttributedString(string: model.hint, attributes: [.font: smallFont, .foregroundColor: NSColor.tertiaryLabelColor])
            h.draw(at: NSPoint(x: bounds.width - padX - h.size().width, y: (bounds.height - h.size().height) / 2))
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let i = itemRects.firstIndex(where: { $0.contains(p) }) { onSelect?(i) }
    }
}
