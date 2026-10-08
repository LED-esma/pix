#!/usr/bin/env python3
"""Pix token counter. Reads Claude Code session transcripts.

  tokens.py mark   <session_id> <workdir>
  tokens.py report <session_id> <workdir> <mode> <runfile>

`mark` records where the run starts so `report` only counts this run,
even when /pix is used inside a longer session. Counts go to ~/Pix/runs/ledger.csv only,
never into the run file.
"""
import csv, datetime, glob, json, os, sys

PROJECTS = os.path.expanduser("~/.claude/projects")
LEDGER = os.path.expanduser("~/Pix/runs/ledger.csv")


def transcript(session):
    hits = glob.glob(os.path.join(PROJECTS, "*", session + ".jsonl"))
    return hits[0] if hits else None


def subagent_files(session):
    return sorted(glob.glob(os.path.join(PROJECTS, "*", session, "subagents", "*.jsonl")))


def usage(path, since=""):
    """Sum usage per model, deduping repeated lines for the same message."""
    by_id = {}
    if not path:
        return {}
    with open(path) as f:
        for i, line in enumerate(f):
            try:
                d = json.loads(line)
            except ValueError:
                continue
            if d.get("timestamp", "") < since:
                continue
            m = d.get("message") or {}
            if d.get("type") != "assistant" or "usage" not in m:
                continue
            by_id[m.get("id") or i] = (m.get("model", "?"), m["usage"])
    out = {}
    for model, u in by_id.values():
        t = out.setdefault(model, [0, 0, 0])
        t[0] += u.get("input_tokens", 0) + u.get("cache_creation_input_tokens", 0)
        t[1] += u.get("cache_read_input_tokens", 0)
        t[2] += u.get("output_tokens", 0)
    return out


def short(model):
    for name in ("fable", "opus", "sonnet", "haiku"):
        if name in model:
            return name.capitalize()
    return model


def k(n):
    return f"{n / 1000:.1f}k" if n >= 1000 else str(n)


def mark(session, workdir):
    os.makedirs(workdir, exist_ok=True)
    now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S")
    with open(os.path.join(workdir, ".mark.json"), "w") as f:
        json.dump({"since": now, "subagents": subagent_files(session)}, f)


def report(session, workdir, mode, runfile):
    with open(os.path.join(workdir, ".mark.json")) as f:
        m = json.load(f)

    rows = {}  # label -> {model: [input, cached, output]}, count

    def add(label, per_model):
        r = rows.setdefault(label, [{}, 0])
        r[1] += 1
        for model, t in per_model.items():
            acc = r[0].setdefault(model, [0, 0, 0])
            for i in range(3):
                acc[i] += t[i]

    add("Orchestrator", usage(transcript(session), m.get("since", "")))
    for path in subagent_files(session):
        if path in m["subagents"]:
            continue
        label = "subagent"
        try:
            with open(path[:-len(".jsonl")] + ".meta.json") as f:
                label = json.load(f).get("agentType", label)
        except (OSError, ValueError):
            pass
        add(label.replace("pix-", "").capitalize(), usage(path))

    lines = ["| Agent | Model | New input | Cached input | Output | Total |",
             "|---|---|---:|---:|---:|---:|"]
    tot = [0, 0, 0]
    for label, (per_model, count) in rows.items():
        for model, t in per_model.items():
            name = f"{label} ×{count}" if count > 1 else label
            lines.append(f"| {name} | {short(model)} | {k(t[0])} | {k(t[1])} | {k(t[2])} | {k(sum(t))} |")
            for i in range(3):
                tot[i] += t[i]
    total = sum(tot)
    if not total:
        print("Token count unavailable: this session's transcript isn't on disk yet.")
        return
    lines.append(f"| **All** | | {k(tot[0])} | {k(tot[1])} | {k(tot[2])} | **{k(total)}** |")
    table = "\n".join(lines)

    new = not os.path.exists(LEDGER)
    with open(LEDGER, "a", newline="") as f:
        w = csv.writer(f)
        if new:
            w.writerow(["date", "mode", "run", "total", "new_input", "cached_input", "output"])
        w.writerow([datetime.date.today().isoformat(), mode, os.path.basename(runfile),
                    total, tot[0], tot[1], tot[2]])

    print(f"Logged {k(total)} tokens to the ledger.")


if __name__ == "__main__":
    if len(sys.argv) == 4 and sys.argv[1] == "mark":
        mark(sys.argv[2], sys.argv[3])
    elif len(sys.argv) == 6 and sys.argv[1] == "report":
        report(*sys.argv[2:])
    else:
        sys.exit(__doc__)
