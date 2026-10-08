import AppKit
import ApplicationServices
import ServiceManagement

/// The card beside the blob, and the right-click menu.
extension PixController {
    func menu() -> NSMenu {
        let m = NSMenu()
        let combo = HotKey.Combo.saved
        let call = m.addItem(withTitle: "Call Pix", action: #selector(MenuTarget.call), keyEquivalent: combo.menuKey)
        call.keyEquivalentModifierMask = combo.menuMods
        let recent = History.recent()
        if !recent.isEmpty {
            let item = m.addItem(withTitle: "Recent", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            let when = RelativeDateTimeFormatter()
            for r in recent {
                let entry = sub.addItem(withTitle: "\(r.title) · \(when.localizedString(for: r.date, relativeTo: Date()))",
                                        action: #selector(MenuTarget.reopen(_:)), keyEquivalent: "")
                entry.representedObject = r.path
                entry.target = MenuTarget.shared
            }
            sub.addItem(.separator())
            sub.addItem(withTitle: "Show All in Finder", action: #selector(MenuTarget.openRuns), keyEquivalent: "").target = MenuTarget.shared
            item.submenu = sub
        }
        let tools = Forge.built()
        if !tools.isEmpty {
            let item = m.addItem(withTitle: "Board Tools", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for name in tools {
                let t = sub.addItem(withTitle: name, action: nil, keyEquivalent: "")
                let actions = NSMenu()
                let undo = actions.addItem(withTitle: "Undo Last Change", action: #selector(MenuTarget.undoTool(_:)), keyEquivalent: "")
                undo.representedObject = name
                undo.isEnabled = Forge.canUndo(name)
                let remove = actions.addItem(withTitle: "Remove", action: #selector(MenuTarget.removeTool(_:)), keyEquivalent: "")
                remove.representedObject = name
                for a in actions.items { a.target = MenuTarget.shared }
                t.submenu = actions
            }
            item.submenu = sub
        }
        let routines = Routines.all()
        if !routines.isEmpty {
            let item = m.addItem(withTitle: "Tools", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for r in routines {
                let row = sub.addItem(withTitle: r.name, action: #selector(MenuTarget.runRoutine(_:)), keyEquivalent: "")
                row.representedObject = r.name
                row.target = MenuTarget.shared
                row.toolTip = r.steps
                let actions = NSMenu()
                let run = actions.addItem(withTitle: "Run", action: #selector(MenuTarget.runRoutine(_:)), keyEquivalent: "")
                run.representedObject = r.name
                run.target = MenuTarget.shared
                let remove = actions.addItem(withTitle: "Remove", action: #selector(MenuTarget.removeRoutine(_:)), keyEquivalent: "")
                remove.representedObject = r.name
                remove.target = MenuTarget.shared
                row.submenu = actions
            }
            item.submenu = sub
        }
        let runs = Schedules.all().filter { $0.kind == "run" }
        if !runs.isEmpty {
            let item = m.addItem(withTitle: "Scheduled", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for e in runs {
                let row = sub.addItem(withTitle: e.summary.count > 70 ? String(e.summary.prefix(67)) + "…" : e.summary, action: nil, keyEquivalent: "")
                let actions = NSMenu()
                let cancel = actions.addItem(withTitle: "Cancel", action: #selector(MenuTarget.cancelSchedule(_:)), keyEquivalent: "")
                cancel.representedObject = e.id
                cancel.target = MenuTarget.shared
                row.submenu = actions
            }
            item.submenu = sub
        }
        let facts = Memory.all()
        if !facts.isEmpty || !Memory.forgotten.isEmpty {
            let item = m.addItem(withTitle: "Memory", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for fact in facts.reversed() {  // newest first
                let f = sub.addItem(withTitle: fact.count > 60 ? String(fact.prefix(57)) + "…" : fact, action: nil, keyEquivalent: "")
                f.toolTip = fact
                let actions = NSMenu()
                let forget = actions.addItem(withTitle: "Forget", action: #selector(MenuTarget.forgetFact(_:)), keyEquivalent: "")
                forget.representedObject = fact
                forget.target = MenuTarget.shared
                f.submenu = actions
            }
            if !facts.isEmpty { sub.addItem(.separator()) }
            if !Memory.forgotten.isEmpty {
                sub.addItem(withTitle: "Undo Forget", action: #selector(MenuTarget.undoForget), keyEquivalent: "").target = MenuTarget.shared
            }
            if !facts.isEmpty {
                sub.addItem(withTitle: "Forget Everything", action: #selector(MenuTarget.forgetAll), keyEquivalent: "").target = MenuTarget.shared
            }
            item.submenu = sub
        }
        let hiding = m.addItem(withTitle: "Hiding", action: nil, keyEquivalent: "")
        let hm = NSMenu()
        for style in HideStyle.allCases {
            let row = hm.addItem(withTitle: style.title, action: #selector(MenuTarget.setHideStyle(_:)), keyEquivalent: "")
            row.representedObject = style.rawValue
            row.state = style == hideStyle ? .on : .off
            row.target = MenuTarget.shared
        }
        hm.addItem(.separator())
        for (title, on, action) in [("Sleep When Idle", Hiding.sleepWhenIdle, #selector(MenuTarget.toggleSleep)),
                                    ("Vanish When Presenting", Hiding.vanishWhenPresenting, #selector(MenuTarget.togglePresenting)),
                                    ("Peek on Approach", Hiding.peekOnApproach, #selector(MenuTarget.toggleApproach))] {
            let row = hm.addItem(withTitle: title, action: action, keyEquivalent: "")
            row.state = on ? .on : .off
            row.target = MenuTarget.shared
        }
        hiding.submenu = hm
        if let u = model.update {
            let title = model.updating ? "Getting Pix \(u.version) Ready…" : model.updateReady != nil ? "Restart to Update to Pix \(u.version)" : "Update to Pix \(u.version)"
            m.addItem(withTitle: title, action: #selector(MenuTarget.update), keyEquivalent: "")
        }
        let auto = m.addItem(withTitle: "Auto Mode", action: #selector(MenuTarget.toggleAuto), keyEquivalent: "")
        auto.state = Auto.on ? .on : .off
        m.addItem(withTitle: "Settings…", action: #selector(MenuTarget.settings), keyEquivalent: ",")
        if Feedback.available { m.addItem(withTitle: "Send Feedback…", action: #selector(MenuTarget.feedback), keyEquivalent: "") }
        m.addItem(.separator())
        m.addItem(withTitle: "Quit Pix", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        for item in m.items where item.action != #selector(NSApplication.terminate(_:)) {
            item.target = MenuTarget.shared
        }
        MenuTarget.shared.controller = self
        return m
    }

    /// Once, after the first answer is put away: the blob peeks out with the keys that call it back.
    func teachSummon() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: "taughtSummon") else { return }
        d.set(true, forKey: "taughtSummon")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, case .idle = self.model.phase, !self.bubbleOpen, !self.roaming else { return }
            self.model.keysHint = true
            self.openBubble()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
                guard let self, self.model.keysHint else { return }
                self.closeBubble()
            }
        }
    }

    /// Back to the question field.
    func closePermissions() {
        model.permissions = false
        if bubbleOpen { bubble.makeKey(); model.focusTick += 1 }
    }

    func hide() {
        if case .guide = model.phase { endGuide() }
        tearDownTour()
        bubbleOpen = false
        bubble.orderOut(nil)
        board?.orderOut(nil)
        buddy.orderOut(nil)
    }

    // MARK: - Card

    func openBubble() {
        bubbleOpen = true
        refreshProviders()
        let focus = { [weak self] in
            guard let self, self.bubbleOpen else { return }
            self.layoutBubble()  // in case the card wasn't ready to draw yet
            switch self.model.phase {
            case .idle where self.model.keysHint:
                break  // just showing the keys: don't take the keyboard
            case .idle, .question:
                self.bubble.makeKey()
                self.model.focusTick += 1
            default:
                break
            }
        }
        if roaming {
            focus()
        } else {
            // The card fades in where the blob is headed while it slides out, instead of waiting for it;
            // it takes the keyboard once the blob has landed (taking it mid-click lost it again at once).
            let target = dockOrigin(.out)
            slide(.out, then: focus)
            layoutBubble(anchor: NSRect(origin: target, size: BlobView.size))
        }
    }

    func closeBubble() {
        bubbleOpen = false
        model.permissions = false
        model.keysHint = false
        hideCard()
        slideHome()
    }

    func escape() {
        if model.listening {
            Voice.shared.cancel(); model.listening = false; model.setTint(.base); closeBubble()
            if wakeRun { wakeRun = false; WakeWord.shared.renew() } else { startWakeWord() }
            return
        }
        if model.adding { model.adding = false; model.addProblem = nil; return }
        if model.permissions { closePermissions(); return }
        if model.welcome { closeWelcome(); return }
        switch model.phase {
        case .setup: closeBubble()
        case .guide: endGuide()
        case .done, .failed: reset()
        default: closeBubble()
        }
    }

    /// Places the card beside the blob (or beside `anchor`, where the blob is headed). It fades in,
    /// glides to a new size or spot, and fades out, rather than popping.
    func layoutBubble(anchor target: NSRect? = nil) {
        guard bubbleOpen, !dragging, buddy.isVisible else { hideCard(); return }
        if model.moving && target == nil {
            if roaming { hideCard() }  // gliding across the screen: the card catches up when it lands
            return                     // sliding in the bezel: it's already where the blob is going
        }
        let size = bubble.host.fittingSize
        guard size.width > 0, size.height > 0 else {
            // Not laid out yet (right after launch): try again on the next pass rather than never showing.
            DispatchQueue.main.async { [weak self] in if self?.bubbleOpen == true, self?.bubble.isVisible == false { self?.layoutBubble(anchor: target) } }
            return
        }
        let screen = (buddy.screen ?? dockScreen).visibleFrame
        let anchor = (target ?? buddy.frame).insetBy(dx: (BlobView.size.width - 2 * BlobView.radius) / 2,
                                                     dy: (BlobView.size.height - 2 * BlobView.radius) / 2)
        let frame = NSRect(origin: Placement.card(size: size, anchor: anchor, screen: screen, avoid: avoid), size: size)
        if !bubble.isVisible || cardFading {
            showCard(at: frame, from: anchor)
        } else if bubble.frame != frame {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                ctx.timingFunction = Motion.smooth
                bubble.animator().setFrame(frame, display: true)
            }
            bubble.invalidateShadow()  // only when it changes: recomputing every pass cost ~2% CPU at rest
        }
    }

    /// Fades the card in, drifting a few points away from the blob as it appears.
    func showCard(at frame: NSRect, from anchor: NSRect) {
        cardToken += 1
        cardFading = false
        let drift: CGFloat = anchor.midX > frame.midX ? 10 : -10
        bubble.setFrame(frame.offsetBy(dx: drift, dy: 0), display: false)
        bubble.alphaValue = 0
        bubble.orderFrontRegardless()
        bubble.invalidateShadow()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.24
            ctx.timingFunction = Motion.smooth
            bubble.animator().setFrame(frame, display: true)
            bubble.animator().alphaValue = 1
        }
    }

    func hideCard() {
        guard bubble.isVisible, !cardFading else { return }
        cardToken += 1
        let token = cardToken
        cardFading = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.14
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            bubble.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, token == self.cardToken else { return }  // shown again meanwhile
                self.bubble.orderOut(nil)
                self.bubble.alphaValue = 1
                self.cardFading = false
            }
        })
    }
}
