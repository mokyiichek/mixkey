import AppKit
import MixKeyCore

/// A small floating bar of rounded "chips" just under the cursor.
/// The chip for the word that will be typed is filled with the theme colour.
final class CandidatePanel: NSPanel {
    private let view = CandidateView()
    var onSelect: ((Int) -> Void)? {
        get { view.onSelect }
        set { view.onSelect = newValue }
    }

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 200, height: 34),
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
        /// Chip the user moved to with Tab/arrows; -1 = none.
        var highlighted: Int
        var hint: String
        /// Choice 1 is the word shown in the text (so it gets the colour by default).
        var firstIsCurrent: Bool = true
    }

    func show(_ model: Model, cursorRect: NSRect) {
        view.model = model
        let size = view.measure()
        var origin = NSPoint(x: cursorRect.minX - 6, y: cursorRect.minY - size.height - 4)
        let screen = NSScreen.screens.first { $0.frame.contains(cursorRect.origin) } ?? NSScreen.main
        if let vf = screen?.visibleFrame {
            if origin.y < vf.minY { origin.y = cursorRect.maxY + 4 }
            origin.x = min(max(origin.x, vf.minX + 2), vf.maxX - size.width - 2)
        }
        setFrame(NSRect(origin: origin, size: size), display: true)
        view.needsDisplay = true
        invalidateShadow()
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
    private var chipRects: [NSRect] = []
    private let outer: CGFloat = 5
    private let gap: CGFloat = 5
    private let chipPadX: CGFloat = 9
    private let chipPadY: CGFloat = 4

    override var isFlipped: Bool { true }

    private var theme: Theme { Theme.current }
    private var fontSize: CGFloat { max(12, Settings.shared.fontSize) }
    private var itemFont: NSFont { .systemFont(ofSize: fontSize, weight: .medium) }
    private var numberFont: NSFont { .monospacedDigitSystemFont(ofSize: max(9, fontSize * 0.58), weight: .bold) }
    private var smallFont: NSFont { .systemFont(ofSize: max(9, fontSize * 0.55), weight: .semibold) }

    private var active: Int {
        if model.highlighted >= 0 { return model.highlighted }
        return model.firstIsCurrent ? 0 : -1
    }

    private func layoutChip(_ item: Item) -> (width: CGFloat, height: CGFloat) {
        var w = (item.text as NSString).size(withAttributes: [.font: itemFont]).width
        if item.number > 0 { w += ("\(item.number)" as NSString).size(withAttributes: [.font: numberFont]).width + 5 }
        if let b = item.badge { w += (b as NSString).size(withAttributes: [.font: smallFont]).width + 5 }
        var h = ceil(itemFont.ascender - itemFont.descender)
        if let r = item.reading {
            w = max(w, (r as NSString).size(withAttributes: [.font: smallFont]).width)
            h += ceil(smallFont.ascender - smallFont.descender) - 2
        }
        return (ceil(w) + 2 * chipPadX, h + 2 * chipPadY)
    }

    /// Lays the chips out in one row; returns the size the bar should be.
    func measure() -> NSSize {
        chipRects.removeAll()
        let sizes = model.items.map(layoutChip)
        let rowH = sizes.map(\.height).max() ?? 24
        var x = outer
        for s in sizes {
            chipRects.append(NSRect(x: x, y: outer, width: s.width, height: rowH))
            x += s.width + gap
        }
        if !model.hint.isEmpty {
            x += (model.hint as NSString).size(withAttributes: [.font: smallFont]).width + 6
        } else {
            x -= gap
        }
        return NSSize(width: ceil(x + outer), height: ceil(rowH + 2 * outer))
    }

    override func draw(_ dirtyRect: NSRect) {
        let t = theme
        let radius = min(14, bounds.height / 2)
        let bg = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        NSGradient(starting: t.backgroundTop, ending: t.backgroundBottom)?.draw(in: bg, angle: -90)
        t.border.setStroke()
        bg.lineWidth = 1
        bg.stroke()

        for (i, item) in model.items.enumerated() where i < chipRects.count {
            let r = chipRects[i]
            let on = i == active
            let chip = NSBezierPath(roundedRect: r, xRadius: min(10, r.height / 2), yRadius: min(10, r.height / 2))
            (on ? t.accent : t.chip).setFill()
            chip.fill()

            let textColor = on ? t.accentText : t.text
            let subColor = on ? t.accentText.withAlphaComponent(0.75) : t.subtext
            var x = r.minX + chipPadX
            let y = r.minY + chipPadY
            if item.number > 0 {
                let n = NSAttributedString(string: "\(item.number)", attributes: [.font: numberFont, .foregroundColor: subColor])
                n.draw(at: NSPoint(x: x, y: y + (itemFont.ascender - numberFont.ascender) - 0.5))
                x += n.size().width + 5
            }
            let textX = x
            let text = NSAttributedString(string: item.text, attributes: [.font: itemFont, .foregroundColor: textColor])
            text.draw(at: NSPoint(x: x, y: y))
            x += text.size().width + 5
            if let badge = item.badge {
                let b = NSAttributedString(string: badge, attributes: [.font: smallFont, .foregroundColor: subColor])
                b.draw(at: NSPoint(x: x, y: y + (itemFont.ascender - smallFont.ascender)))
            }
            if let reading = item.reading {
                let rd = NSAttributedString(string: reading, attributes: [.font: smallFont, .foregroundColor: subColor])
                rd.draw(at: NSPoint(x: textX, y: y + ceil(itemFont.ascender - itemFont.descender) - 2))
            }
        }
        if !model.hint.isEmpty {
            let h = NSAttributedString(string: model.hint, attributes: [.font: smallFont, .foregroundColor: t.subtext])
            h.draw(at: NSPoint(x: bounds.width - outer - 4 - h.size().width, y: (bounds.height - h.size().height) / 2))
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let i = chipRects.firstIndex(where: { $0.contains(p) }) { onSelect?(i) }
    }
}
