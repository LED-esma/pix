import AppKit
import SwiftUI

/// The board: a pop-up window holding whatever tools Pix chose for this answer.
final class BoardPanel: NSPanel {
    init(model: PixModel, controller: PixController) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 640, height: 460),
                   styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isMovableByWindowBackground = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        minSize = NSSize(width: 420, height: 300)
        // The window keeps the size you give it: an emptied board (on close) once shrank it to 0x48, and
        // that size was saved, so every later board opened invisible.
        let host = NSHostingView(rootView: BoardView(model: model, controller: controller))
        host.sizingOptions = []
        contentView = host
        setFrameAutosaveName("PixBoard")
    }
    override var canBecomeKey: Bool { true }

    /// A saved frame too small to see, or on no screen, starts over at the usual size and place.
    static func needsReset(_ frame: NSRect, screens: [NSRect]) -> Bool {
        frame.width < 420 || frame.height < 300 || !screens.contains { $0.intersects(frame) }
    }
    override func cancelOperation(_ sender: Any?) { close() }
}

struct BoardView: View {
    @ObservedObject var model: PixModel
    let controller: PixController

    var body: some View {
        VStack(spacing: 0) {
            if model.board.count > 1 {
                HStack(spacing: 4) {
                    ForEach(model.board.indices, id: \.self) { i in
                        Button { model.boardIndex = i } label: {
                            Label(model.board[i].title, systemImage: model.board[i].symbol)
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Capsule().fill(i == model.boardIndex ? Color.primary.opacity(0.1) : .clear))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 30)
                .padding(.bottom, 4)
            } else if let v = model.board.first {
                Text(v.title).font(.system(size: 13, weight: .semibold)).padding(.top, 8).padding(.bottom, 4)
            }
            if model.board.indices.contains(model.boardIndex) {
                tool(model.board[model.boardIndex])
                    .id(model.board[model.boardIndex].id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(.regularMaterial)
        .overlay(alignment: .topTrailing) {
            Button { controller.shareBoard() } label: {
                Image(systemName: "square.and.arrow.up").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                    .frame(width: 28, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
            .padding(.trailing, 8)
            .accessibilityLabel("Share")
        }
        .ignoresSafeArea()
    }

    @ViewBuilder private func tool(_ v: Visual) -> some View {
        switch v {
        case .graph(_, let fns, let pts, let xmin, let xmax):
            GraphTool(functions: fns, points: pts, xmin: xmin, xmax: xmax)
        case .diagram(_, let shapes):
            DiagramTool(shapes: shapes).padding(16)
        case .table(_, let cols, let rows):
            TableTool(columns: cols, rows: rows)
        case .checklist(_, let items):
            ChecklistTool(items: items)
        case .code(_, let lang, let text):
            CodeTool(language: lang, text: text)
        case .canvas(_, let html, let plugins):
            CanvasTool(html: html, plugins: plugins)
                .padding(.top, model.board.count > 1 ? 0 : 4)
        case .notes(_, let text):
            ScrollView {
                MathText(text: text, size: 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
        }
    }
}

// MARK: - Tools

/// Labeled shapes on a 100×100 canvas (y down), scaled to fit.
private struct DiagramTool: View {
    let shapes: [Visual.Shape]

    var body: some View {
        Canvas { g, size in
            let side = min(size.width, size.height)
            let k = side / 100
            let o = CGPoint(x: (size.width - side) / 2, y: (size.height - side) / 2)
            func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: o.x + x * k, y: o.y + y * k) }
            let stroke = Color(red: 0.39, green: 0.27, blue: 0.93)
            let fill = stroke.opacity(0.1)
            func label(_ s: String, at pt: CGPoint) {
                guard !s.isEmpty else { return }
                g.draw(Text(s).font(.system(size: 13, weight: .medium)), at: pt)
            }
            for s in shapes {
                switch s.type {
                case "rect":
                    let r = CGRect(origin: p(s.x, s.y), size: CGSize(width: s.w * k, height: s.h * k))
                    g.fill(Path(roundedRect: r, cornerRadius: 3), with: .color(fill))
                    g.stroke(Path(roundedRect: r, cornerRadius: 3), with: .color(stroke), lineWidth: 2)
                    label(s.label, at: CGPoint(x: r.midX, y: r.midY))
                case "circle":
                    let r = (s.w > 0 ? s.w : 10) / 2 * k
                    let c = p(s.x, s.y)
                    let e = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
                    g.fill(e, with: .color(fill))
                    g.stroke(e, with: .color(stroke), lineWidth: 2)
                    label(s.label, at: c)
                case "triangle":
                    var t = Path()
                    t.move(to: p(s.x, s.y)); t.addLine(to: p(s.x2, s.y2)); t.addLine(to: p(s.x3, s.y3)); t.closeSubpath()
                    g.fill(t, with: .color(fill))
                    g.stroke(t, with: .color(stroke), lineWidth: 2)
                    label(s.label, at: p((s.x + s.x2 + s.x3) / 3, (s.y + s.y2 + s.y3) / 3))
                case "line", "arrow":
                    let a = p(s.x, s.y), b = p(s.x2, s.y2)
                    var l = Path()
                    l.move(to: a); l.addLine(to: b)
                    if s.type == "arrow" {
                        let ang = atan2(b.y - a.y, b.x - a.x)
                        for d in [2.6, -2.6] {
                            l.move(to: b)
                            l.addLine(to: CGPoint(x: b.x + 11 * cos(ang + d), y: b.y + 11 * sin(ang + d)))
                        }
                    }
                    g.stroke(l, with: .color(stroke), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    // Label beside the middle, nudged off the line.
                    let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
                    let ang = atan2(b.y - a.y, b.x - a.x) - .pi / 2
                    label(s.label, at: CGPoint(x: mid.x + 14 * cos(ang), y: mid.y + 14 * sin(ang)))
                default:  // text
                    label(s.label, at: p(s.x, s.y))
                }
            }
        }
    }
}

private struct TableTool: View {
    let columns: [String]
    let rows: [[String]]

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
                if !columns.isEmpty {
                    GridRow { ForEach(columns.indices, id: \.self) { Text(columns[$0]).font(.system(size: 12.5, weight: .semibold)) } }
                    Divider()
                }
                ForEach(rows.indices, id: \.self) { r in
                    GridRow {
                        ForEach(rows[r].indices, id: \.self) { c in
                            Text(DoneView.markdown(rows[r][c])).font(.system(size: 13)).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: 260, alignment: .leading)
                        }
                    }
                }
            }
            .padding(20)
        }
    }
}

private struct ChecklistTool: View {
    let items: [String]
    @State private var done: Set<Int> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(items.indices, id: \.self) { i in
                    Button {
                        if done.contains(i) { done.remove(i) } else { done.insert(i) }
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: done.contains(i) ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 16))
                                .foregroundStyle(done.contains(i) ? Color.accentColor : .secondary)
                            Text(DoneView.markdown(items[i])).font(.system(size: 14))
                                .strikethrough(done.contains(i))
                                .foregroundStyle(done.contains(i) ? .secondary : .primary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(20)
        }
    }
}

private struct CodeTool: View {
    let language: String
    let text: String
    @State private var copied = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ScrollView([.vertical, .horizontal]) {
                Text(text).font(.system(size: 12.5, design: .monospaced)).textSelection(.enabled).padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color.primary.opacity(0.04))
            Button(copied ? "Copied" : "Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                copied = true
            }
            .controlSize(.small)
            .padding(10)
        }
    }
}
