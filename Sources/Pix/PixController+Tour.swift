import AppKit

/// The board and step-by-step tours that point at things.
extension PixController {
    func showBoard(_ visuals: [Visual]) {
        model.board = visuals
        model.boardIndex = 0
        guard !visuals.isEmpty else { board?.orderOut(nil); BoardFocus.canvas = nil; BoardFocus.graph = nil; return }
        let firstTime = board == nil && UserDefaults.standard.string(forKey: "NSWindow Frame PixBoard") == nil
        let panel = board ?? BoardPanel(model: model, controller: self)
        if board == nil {
            NotificationCenter.default.publisher(for: NSWindow.willCloseNotification, object: panel)
                .sink { [weak self] _ in
                    guard let self else { return }
                    if case .guide = self.model.phase { self.endGuide() } else { self.tearDownTour() }
                }
                .store(in: &bag)
        }
        board = panel
        // A saved size too small to see (or off every screen) starts over at the usual size and place.
        let reset = BoardPanel.needsReset(panel.frame, screens: NSScreen.screens.map(\.visibleFrame))
        if reset { panel.setContentSize(NSSize(width: 640, height: 460)) }
        if firstTime || reset {
            // Beside Pix's card (blob plus a card up to ~340 wide), toward the middle of the screen, never under it.
            let vf = dockScreen.visibleFrame
            let size = panel.frame.size
            let clear: CGFloat = BlobView.size.width + 360
            let x = dockRight ? vf.maxX - clear - size.width : vf.minX + clear
            panel.setFrameOrigin(CGPoint(x: max(vf.minX + 12, x), y: vf.midY - size.height / 2))
        }
        // Pop out of the blob: start small at Pix and grow into place.
        if !panel.isVisible {
            let target = panel.frame
            let c = CGPoint(x: buddy.frame.midX, y: buddy.frame.midY)
            panel.setFrame(NSRect(x: c.x - 40, y: c.y - 30, width: 80, height: 60), display: false)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.35
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.05)
                panel.animator().setFrame(target, display: true)
                panel.animator().alphaValue = 1
            }
        } else {
            panel.orderFrontRegardless()
        }
    }

    // MARK: - Show me tour

    func present(_ index: Int) {
        guard case .guide(var g) = model.phase else { return }
        g.index = index
        model.phase = .guide(g)
        guard index < g.steps.count else { explainHere(); return }
        let step = g.steps[index]
        if let v = step.visual, model.board.indices.contains(v) { model.boardIndex = v }
        if let rect = step.rect { point(at: rect); return }  // something on your screen
        guard !step.focus.isEmpty, board?.isVisible == true else { explainHere(); return }
        // Something on the board: give a freshly opened tool a moment to load, then fly to it.
        Task { @MainActor in
            var rect: NSRect?
            for _ in 0..<20 {
                rect = await BoardFocus.rect(for: step.focus)
                if rect != nil { break }
                try? await Task.sleep(for: .milliseconds(120))
            }
            guard case .guide(let now) = model.phase, now.index == index else { return }  // moved on meanwhile
            if let rect { point(at: rect) } else {
                Log.tour.notice("couldn't find \(step.focus, privacy: .public) on the board")
                explainHere()
            }
        }
    }

    /// No target for this step: explain from wherever Pix is.
    func explainHere() {
        overlay.hide()
        avoid = nil
        if roaming { bubbleOpen = true; layoutBubble() } else { openBubble() }
    }

    /// Glide beside `rect`, ring it, look at it, then show the step.
    func point(at rect: NSRect) {
        let screen = NSScreen.screens.first { $0.frame.intersects(rect) } ?? dockScreen
        roaming = true
        bubbleOpen = true
        bubble.orderOut(nil)
        avoid = rect
        overlay.show(rect, on: screen)
        let spot = Placement.buddySpot(beside: rect, buddy: BlobView.size, screen: screen.visibleFrame)
        glide(to: spot) { [weak self] in
            guard let self else { return }
            let c = CGPoint(x: self.buddy.frame.midX, y: self.buddy.frame.midY)
            let d = max(1, hypot(rect.midX - c.x, rect.midY - c.y))
            self.model.look = CGVector(dx: (rect.midX - c.x) / d, dy: -(rect.midY - c.y) / d)
            self.layoutBubble()
        }
    }

    func step(_ delta: Int) {
        guard case .guide(let g) = model.phase else { return }
        if delta > 0 && (g.isLast || g.steps.isEmpty) { endGuide(); return }
        present(max(0, g.index + delta))
    }

    func endGuide() {
        defer { runPending() }
        model.phase = .idle
        model.activity = .idle
        model.setTint(.base)
        bubbleOpen = false
        bubble.orderOut(nil)
        if roaming { tearDownTour() } else { tearDownTour(); slideHome() }
    }

    // MARK: - Sharing the board

    /// Saves what's on the board as an image next to the run, then opens the share menu (AirDrop, Messages, Save…).
    func shareBoard() {
        guard let panel = board, let content = panel.contentView, model.board.indices.contains(model.boardIndex) else { return }
        let base = lastRunPath.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? "pix-\(Solo.today())"
        let url = PixPaths.runs.appendingPathComponent("\(base)-board.png")
        let anchor = NSRect(x: content.bounds.maxX - 40, y: content.isFlipped ? 4 : content.bounds.maxY - 28, width: 28, height: 24)
        func share(_ rep: NSBitmapImageRep?) {
            guard let png = rep?.representation(using: .png, properties: [:]), (try? png.write(to: url)) != nil else { return }
            NSSharingServicePicker(items: [url]).show(relativeTo: anchor, of: content, preferredEdge: .minY)
        }
        if case .canvas = model.board[model.boardIndex], let web = BoardFocus.canvas, web.window === panel {
            web.takeSnapshot(with: nil) { image, _ in
                share(image?.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
            }
        } else {
            let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds)
            if let rep { content.cacheDisplay(in: content.bounds, to: rep) }
            share(rep)
        }
    }
}
