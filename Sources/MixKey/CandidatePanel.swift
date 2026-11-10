import AppKit
import MixKeyCore

/// A large, easy-to-read candidate window.
///  - Top line: what will be typed (the full sentence), big.
///  - Below: numbered choices, with pinyin under Chinese words.
final class CandidatePanel: NSPanel {
    private let view = CandidateView()
    var onSelect: ((Int) -> Void)? {
        get { view.onSelect }
        set { view.onSelect = newValue }
    }

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
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
        var preview: String
        var items: [CandidateView.Item]
        var highlighted: Int
        var status: String
    }

    func show(_ model: Model, cursorRect: NSRect) {
        view.model = model
        let size = view.measure()
        var origin = NSPoint(x: cursorRect.minX, y: cursorRect.minY - size.height - 6)
        let screen = NSScreen.screens.first { $0.frame.contains(cursorRect.origin) } ?? NSScreen.main
        if let vf = screen?.visibleFrame {
            if origin.y < vf.minY { origin.y = cursorRect.maxY + 6 }
            origin.x = min(max(origin.x, vf.minX + 4), vf.maxX - size.width - 4)
            origin.y = min(origin.y, vf.maxY - size.height)
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

    var model = CandidatePanel.Model(preview: "", items: [], highlighted: 0, status: "")
    var onSelect: ((Int) -> Void)?
    private var rowRects: [NSRect] = []
    private let pad: CGFloat = 12

    override var isFlipped: Bool { true }

    private var fontSize: CGFloat { Settings.shared.fontSize }
    private var previewFont: NSFont { .systemFont(ofSize: fontSize + 2, weight: .semibold) }
    private var itemFont: NSFont { .systemFont(ofSize: fontSize) }
    private var numberFont: NSFont { .monospacedDigitSystemFont(ofSize: fontSize * 0.75, weight: .bold) }
    private var readingFont: NSFont { .systemFont(ofSize: max(11, fontSize * 0.55)) }
    private var statusFont: NSFont { .systemFont(ofSize: 11, weight: .medium) }

    /// Computes row positions; returns the size the panel should be.
    func measure() -> NSSize {
        rowRects.removeAll()
        let maxWidth: CGFloat = 640
        var y = pad
        var width: CGFloat = 220
        let preview = NSAttributedString(string: model.preview, attributes: [.font: previewFont])
        let pSize = preview.boundingRect(with: NSSize(width: maxWidth - 2 * pad, height: 200),
                                         options: [.usesLineFragmentOrigin]).size
        width = max(width, min(maxWidth, ceil(pSize.width) + 2 * pad))
        y += ceil(pSize.height) + 8
        y += 1 + 6 // divider
        for item in model.items {
            let t = NSAttributedString(string: item.text, attributes: [.font: itemFont]).size()
            var rowH = ceil(t.height) + 4
            var rowW = 32 + t.width + (item.badge != nil ? 34 : 0)
            if Settings.shared.showPinyin, let r = item.reading {
                let rs = NSAttributedString(string: r, attributes: [.font: readingFont]).size()
                rowH += ceil(rs.height)
                rowW = max(rowW, 32 + rs.width)
            }
            width = max(width, min(maxWidth, rowW + 2 * pad))
            rowRects.append(NSRect(x: 6, y: y, width: 0, height: rowH))
            y += rowH + 2
        }
        y += 4
        y += NSAttributedString(string: "Ag", attributes: [.font: statusFont]).size().height + pad - 4
        for i in rowRects.indices { rowRects[i].size.width = width - 12 }
        return NSSize(width: ceil(width), height: ceil(y))
    }

    override func draw(_ dirtyRect: NSRect) {
        let bg = NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12)
        NSColor.windowBackgroundColor.withAlphaComponent(0.97).setFill()
        bg.fill()
        NSColor.separatorColor.setStroke()
        bg.lineWidth = 1
        bg.stroke()

        var y = pad
        let preview = NSAttributedString(string: model.preview, attributes: [.font: previewFont, .foregroundColor: NSColor.labelColor])
        let pRect = NSRect(x: pad, y: y, width: bounds.width - 2 * pad, height: 400)
        preview.draw(with: pRect, options: [.usesLineFragmentOrigin])
        y += ceil(preview.boundingRect(with: pRect.size, options: [.usesLineFragmentOrigin]).height) + 8
        NSColor.separatorColor.setFill()
        NSRect(x: pad, y: y, width: bounds.width - 2 * pad, height: 1).fill()

        for (i, item) in model.items.enumerated() where i < rowRects.count {
            let r = rowRects[i]
            let selected = i == model.highlighted
            if selected {
                NSColor.controlAccentColor.withAlphaComponent(0.22).setFill()
                NSBezierPath(roundedRect: r, xRadius: 7, yRadius: 7).fill()
            }
            let num = NSAttributedString(string: "\(item.number)", attributes: [
                .font: numberFont,
                .foregroundColor: selected ? NSColor.controlAccentColor : NSColor.secondaryLabelColor,
            ])
            num.draw(at: NSPoint(x: r.minX + 8, y: r.minY + 2 + (itemFont.pointSize - numberFont.pointSize) / 2 + 2))
            let text = NSAttributedString(string: item.text, attributes: [.font: itemFont, .foregroundColor: NSColor.labelColor])
            text.draw(at: NSPoint(x: r.minX + 30, y: r.minY + 2))
            var x = r.minX + 30 + text.size().width + 8
            if let badge = item.badge {
                let b = NSAttributedString(string: badge, attributes: [.font: statusFont, .foregroundColor: NSColor.systemPurple])
                b.draw(at: NSPoint(x: x, y: r.minY + 2 + (itemFont.pointSize - 11) / 2 + 2))
                x += b.size().width
            }
            if Settings.shared.showPinyin, let reading = item.reading {
                let rd = NSAttributedString(string: reading, attributes: [.font: readingFont, .foregroundColor: NSColor.secondaryLabelColor])
                rd.draw(at: NSPoint(x: r.minX + 30, y: r.minY + 2 + text.size().height - 2))
            }
        }
        let status = NSAttributedString(string: model.status, attributes: [.font: statusFont, .foregroundColor: NSColor.tertiaryLabelColor])
        status.draw(at: NSPoint(x: pad, y: bounds.height - pad - status.size().height + 4))
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let i = rowRects.firstIndex(where: { $0.contains(p) }) { onSelect?(i) }
    }
}
