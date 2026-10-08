import AppKit

/// Timers and scheduled runs: Pix's tools write them to ~/Pix/schedules.json; the app fires them.
extension PixController {
    func startSchedules() {
        refreshSchedules()
        schedulePoll?.invalidate()
        // A light check now and then also picks up anything added while a run was going,
        // and runs a scheduled question that had to wait for you to finish.
        schedulePoll = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshSchedules(); self?.runPending() }
        }
    }

    /// Re-reads timers and schedules and arms the next one. Missed ones (Pix was closed or asleep)
    /// fire now if they're recent: timers within an hour, runs within 12 hours.
    func refreshSchedules() {
        let all = Schedules.all()
        let timers = all.filter { $0.kind == "timer" }
        if timers != model.timers { model.timers = timers }
        scheduleTimer?.invalidate()
        guard let next = all.first else { return }
        scheduleTimer = Timer.scheduledTimer(withTimeInterval: max(0.2, next.at.timeIntervalSinceNow), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.fireDue() }
        }
    }

    func fireDue() {
        let now = Date()
        for e in Schedules.all() where e.at <= now.addingTimeInterval(0.5) {
            if let next = Schedules.next(after: now, from: e) {
                var n = e
                n.at = next
                Schedules.add(n)
            } else {
                Schedules.remove(e.id)
            }
            let late = now.timeIntervalSince(e.at)
            if e.kind == "timer" { if late < 3600 { timerDone(e) } }
            else if late < 12 * 3600 { pendingRuns.append(e) }
        }
        refreshSchedules()
        runPending()
    }

    /// A timer ended: a sound and a tap from the blob, or just the sound while Pix is busy with you.
    func timerDone(_ e: Schedules.Entry) {
        Log.app.notice("timer done")
        NSSound(named: "Hero")?.play()
        switch model.phase {
        case .working, .question, .permission, .guide:
            model.activity = .alert
        default:
            tearDownTour()
            model.note = nil
            model.answeredBy = nil
            model.actions = []
            model.phase = .done(Done(gist: e.text.isEmpty ? "**Time's up.**" : "**Time's up:** \(e.text)", path: nil))
            needsYou()
        }
    }

    /// Asks a scheduled question once Pix is free (never in the middle of something you're doing).
    func runPending() {
        guard let e = pendingRuns.first else { return }
        switch model.phase {
        case .idle, .done, .failed: break
        default: return
        }
        if bubble.isKeyWindow && !model.goal.isEmpty { return }  // you're typing
        pendingRuns.removeFirst()
        Log.app.notice("scheduled run")
        lastRequest = (e.text, .lite)
        retried = false
        runProject = nil
        let prompt = PixModel.withMemory(Routines.match(e.text)?.steps ?? e.text)  // "morning brief" at 8 runs the routine
        lastPrompt = prompt
        startSolo(e.text, prompt: prompt, screen: false)
        model.note = .init(text: e.repeats == .none ? "You scheduled this" : "Scheduled · " + e.summary.components(separatedBy: ":").first!,
                           symbol: "clock.arrow.circlepath")
    }

    /// Takes back one change Pix's tools made.
    func undo(_ a: Actions.Action) {
        if Actions.undo(a) {
            model.undone.insert(a.id)
        } else {
            model.note = .init(text: "Couldn't undo that one; it may already be gone", symbol: "exclamationmark.triangle")
        }
        refreshSchedules()
    }

    /// Keeps the question you just asked as a tool (the card's Save as Tool).
    func saveRoutine(_ r: (name: String, steps: String)) {
        let name = Routines.save(name: r.name, steps: r.steps)
        Actions.log("routine_save", "Saved tool “\(name)”", undo: ["type": "routine_remove", "name": name], run: runToken)
        model.actions = Actions.forRun(runToken)
        if case .done(var d) = model.phase { d.routine = nil; model.phase = .done(d) }
    }

    func runRoutine(_ name: String) {
        guard Routines.match(name) != nil else { return }
        if case .working = model.phase { return }
        tearDownTour()
        model.phase = .idle
        model.goal = name
        model.followUp = false
        go()
    }

    func cancelSchedule(_ id: String) {
        Schedules.remove(id)
        refreshSchedules()
    }
}
