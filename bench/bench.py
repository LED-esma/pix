#!/usr/bin/env python3
"""Pix token benchmark.

Runs the exact command lines Pix uses (from `Pix --print-args`), then reads each
session's transcripts and breaks every API call down to see where tokens go.

  python3 bench/bench.py baselines         fixed costs: setup, tools, image, Claude Code prompt
  python3 bench/bench.py lite [n]          Lite on research, math, and screen tasks, n runs each
  python3 bench/bench.py team              Standard and Deep (2 per role) on the research task
  python3 bench/bench.py report            summarize everything in results/
"""
import base64, datetime, glob, json, os, pathlib, subprocess, sys, time

HERE = pathlib.Path(__file__).resolve().parent
PIX = HERE.parent / "dist/Pix.app/Contents/MacOS/Pix"
PROJ = os.path.expanduser("~/.claude/projects/") + os.path.expanduser("~/Pix").replace("/", "-")  # Claude Code's folder for runs in ~/Pix
RESULTS = HERE / "results"
SCREEN = HERE / "screen.jpg"

RESEARCH = ("Compare the M5 MacBook Air and the M4 MacBook Air on current price and battery life, "
            "and recommend one for a college student")
MATH = "solve 2x² − 8x + 6 = 0 step by step"
WALK = "walk me through problem 3 step by step"


def pix_args(kind):
    d = json.loads(subprocess.check_output([str(PIX), "--print-args"]))
    a = list(d["solo" if kind == "solo" else "team"])
    if "--no-session-persistence" in a:  # keep transcripts so every call can be inspected
        a.remove("--no-session-persistence")
    return d["claude"], a


def set_flag(a, flag, value):
    a = list(a)
    a[a.index(flag) + 1] = value
    return a


# ---------------------------------------------------------------- running

def run(label, kind, prompt, image=None, tweak=None, env=None):
    claude, a = pix_args(kind)
    if tweak:
        a = tweak(a)
    t0 = time.time()
    p = subprocess.Popen([claude] + a, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=subprocess.DEVNULL, text=True, cwd=os.path.expanduser("~/Pix"),
                         env={**os.environ, **(env or {})})

    def send(o):
        p.stdin.write(json.dumps(o) + "\n")
        p.stdin.flush()

    send({"type": "control_request", "request_id": "init", "request": {"subtype": "initialize"}})
    content = prompt
    if image:
        content = [{"type": "image", "source": {"type": "base64", "media_type": "image/jpeg",
                                                 "data": base64.b64encode(image.read_bytes()).decode()}},
                   {"type": "text", "text": prompt}]
    send({"type": "user", "message": {"role": "user", "content": content}})

    session, result, asked, denied = None, None, [], []
    for line in p.stdout:
        d = json.loads(line)
        if d.get("type") == "system" and d.get("subtype") == "init":
            session = d.get("session_id")
        elif d.get("type") == "control_request":
            r = d.get("request", {})
            if r.get("subtype") != "can_use_tool":
                send({"type": "control_response", "response": {"subtype": "error", "request_id": d["request_id"],
                                                                "error": "unsupported"}})
                continue
            inp = dict(r.get("input", {}))
            if r.get("tool_name") == "AskUserQuestion":  # answer like a user taking the recommended option
                inp["answers"] = {q["question"]: q["options"][0]["label"] for q in inp.get("questions", [])}
                asked.append(list(inp["answers"].items()))
                resp = {"behavior": "allow", "updatedInput": inp}
            else:
                denied.append(r.get("tool_name"))
                resp = {"behavior": "deny", "message": "Not allowed in the benchmark."}
            send({"type": "control_response", "response": {"subtype": "success", "request_id": d["request_id"],
                                                            "response": resp}})
        elif d.get("type") == "result":
            result = d
            p.stdin.close()
            break
    p.wait()
    rec = {
        "label": label, "kind": kind, "session": session, "seconds": round(time.time() - t0, 1),
        "cost": result.get("total_cost_usd") if result else None,
        "turns": result.get("num_turns") if result else None,
        "is_error": result.get("is_error") if result else True,
        "modelUsage": result.get("modelUsage") if result else {},
        "asked": asked, "denied": denied,
        "calls": analyze(session) if session else {},
    }
    RESULTS.mkdir(exist_ok=True)
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    (RESULTS / f"{stamp}-{label}.json").write_text(json.dumps(rec, indent=1))
    print(f"{label:<22} {total(rec):>9,} tokens  ${rec['cost'] or 0:.3f}  {rec['seconds']}s  "
          f"turns={rec['turns']}  {'ERROR' if rec['is_error'] else ''}", flush=True)
    return rec


# ---------------------------------------------------------------- transcripts → calls

def calls_in(path):
    """Every API call in a transcript, in order, with what came back between calls."""
    order, by_id, tool_names, results_after = [], {}, {}, {}
    last = None
    with open(path) as f:
        for line in f:
            try:
                d = json.loads(line)
            except ValueError:
                continue
            m = d.get("message") or {}
            if d.get("type") == "assistant" and "usage" in m:
                mid = m.get("id")
                if mid not in by_id:
                    order.append(mid)
                    by_id[mid] = {"model": m.get("model"), "tools": [], "text_chars": 0}
                c = by_id[mid]
                c["usage"] = m["usage"]
                for b in m.get("content") or []:
                    if b.get("type") == "tool_use":
                        c["tools"].append(b["name"])
                        tool_names[b["id"]] = b["name"] if b["name"] != "Agent" else \
                            "Agent:" + (b.get("input", {}).get("subagent_type") or "?")
                    elif b.get("type") == "text":
                        c["text_chars"] += len(b.get("text", ""))
                last = mid
            elif d.get("type") == "user" and last:
                for b in (m.get("content") if isinstance(m.get("content"), list) else []):
                    if b.get("type") == "tool_result":
                        body = b.get("content")
                        size = len(json.dumps(body)) if not isinstance(body, str) else len(body)
                        name = tool_names.get(b.get("tool_use_id"), "?")
                        results_after.setdefault(last, []).append((name, size))
    out = []
    for mid in order:
        u = by_id[mid]["usage"]
        out.append({
            "model": by_id[mid]["model"],
            "fresh": u.get("input_tokens", 0),
            "write": u.get("cache_creation_input_tokens", 0),
            "read": u.get("cache_read_input_tokens", 0),
            "out": u.get("output_tokens", 0),
            "think": (u.get("output_tokens_details") or {}).get("thinking_tokens", 0),
            "tools": by_id[mid]["tools"],
            "results": results_after.get(mid, []),
        })
    return out


def analyze(session):
    main = glob.glob(f"{PROJ}/{session}.jsonl")
    agents = {"main": calls_in(main[0]) if main else []}
    for path in sorted(glob.glob(f"{PROJ}/{session}/subagents/*.jsonl")):
        kind = "subagent"
        try:
            kind = json.load(open(path[:-6] + ".meta.json")).get("agentType", kind)
        except (OSError, ValueError):
            pass
        agents.setdefault(kind, [])
        agents[kind].append(calls_in(path))
    # main is one list of calls; subagent types are lists of lists (one per spawn)
    return agents


# ---------------------------------------------------------------- attribution

def breakdown(calls):
    """Split one agent's tokens into where they went.

    setup:    the first call's context (system prompt, tools, memory, request, image),
              paid once and then re-read by every later call
    replies:  the agent's own earlier messages, re-read by later calls
    <tool>:   tool results (web search pages, subagent summaries…), re-read by later calls
    output / thinking: tokens generated
    """
    b = {}
    def add(k, v):
        if v > 0:
            b[k] = b.get(k, 0) + v
    if not calls:
        return b
    ctx = [c["fresh"] + c["write"] + c["read"] for c in calls]
    n = len(calls)
    add("setup", ctx[0] * n)
    for j in range(n - 1):
        grew = max(0, ctx[j + 1] - ctx[j])
        later = n - 1 - j
        mine = min(grew, max(0, calls[j]["out"] - calls[j]["think"]))
        add("replies", mine * later)
        rest = grew - mine
        res = calls[j]["results"]
        chars = sum(s for _, s in res)
        for name, size in res:
            add(tool_label(name), rest * (size / chars) * later if chars else 0)
        if not chars:
            add("replies", rest * later)
    for c in calls:
        add("thinking", c["think"])
        add("output", c["out"] - c["think"])
    return {k: round(v) for k, v in b.items()}


def tool_label(name):
    return {"WebSearch": "web search results", "WebFetch": "web page reads",
            "Agent:pix-researcher": "researcher summaries", "Agent:pix-scout": "scout summaries",
            "Agent:pix-builder": "builder summaries", "Agent:pix-synth": "synth reply",
            "Skill": "skill instructions", "Bash": "command output", "AskUserQuestion": "your answers",
            "Read": "file reads", "Write": "file writes", "Edit": "file writes",
            "StructuredOutput": "final answer"}.get(name, name)


def flat(rec):
    """(agent label, calls) for every agent in a run."""
    out = [("main", rec["calls"].get("main", []))]
    for kind, spawns in rec["calls"].items():
        if kind != "main":
            out += [(kind, c) for c in spawns]
    return out


def total(rec):
    return sum(c["fresh"] + c["write"] + c["read"] + c["out"] for _, calls in flat(rec) for c in calls)


# ---------------------------------------------------------------- suites

def screen_image():
    if SCREEN.exists():
        return SCREEN
    src = HERE / "screen.swift"
    subprocess.check_call(["swift", str(src), str(SCREEN)])
    return SCREEN


def baselines():
    ok = "Reply with the single word OK."
    run("base-solo", "solo", ok)
    run("base-solo-notools", "solo", ok, tweak=lambda a: set_flag(a, "--tools", ""))
    run("base-solo-tinyprompt", "solo", ok, tweak=lambda a: set_flag(a, "--system-prompt", "You are Pix."))
    run("base-solo-noclaudemd", "solo", ok, env={"CLAUDE_CODE_DISABLE_CLAUDE_MDS": "1"})
    run("base-solo-image", "solo", "Screenshot: 1512x982 pixels.\n\n" + ok, image=screen_image())
    run("base-team", "team", ok)


def lite(n):
    for i in range(1, n + 1):
        run(f"lite-research-{i}", "solo", RESEARCH)
        run(f"lite-math-{i}", "solo", MATH)
        run(f"lite-screen-{i}", "solo", "Screenshot: 1512x982 pixels. Frontmost app: Preview.\n\n" + WALK,
            image=screen_image())


def team():
    run("standard", "team", "/pix standard " + RESEARCH)
    run("deep-2", "team", "/pix deep:2 " + RESEARCH)


def report():
    recs = [json.loads(p.read_text()) for p in sorted(RESULTS.glob("*.json"))]
    latest = {}
    for r in recs:
        latest.setdefault(r["label"], []).append(r)
    print(f"\n{'run':<22}{'tokens':>10}{'fresh in':>10}{'cache wr':>10}{'cache rd':>10}{'output':>9}"
          f"{'calls':>7}{'cost':>8}")
    for label, rs in latest.items():
        for r in rs:
            cs = [c for _, calls in flat(r) for c in calls]
            print(f"{label:<22}{total(r):>10,}{sum(c['fresh'] for c in cs):>10,}{sum(c['write'] for c in cs):>10,}"
                  f"{sum(c['read'] for c in cs):>10,}{sum(c['out'] for c in cs):>9,}{len(cs):>7}"
                  f"{'$%.3f' % (r['cost'] or 0):>8}")
    print("\nWhere the tokens went (summed over each run's agents):")
    for label, rs in latest.items():
        r = rs[-1]
        agg, per_agent = {}, {}
        for who, calls in flat(r):
            for k, v in breakdown(calls).items():
                agg[k] = agg.get(k, 0) + v
            per_agent[who] = per_agent.get(who, 0) + sum(c["fresh"] + c["write"] + c["read"] + c["out"] for c in calls)
        t = sum(agg.values()) or 1
        parts = ", ".join(f"{k} {v / t:.0%}" for k, v in sorted(agg.items(), key=lambda kv: -kv[1]))
        print(f"  {label}: {parts}")
        if len(per_agent) > 1:
            print("     by agent: " + ", ".join(f"{k} {v:,}" for k, v in sorted(per_agent.items(), key=lambda kv: -kv[1])))
        firsts = [(who, calls[0]["fresh"] + calls[0]["write"] + calls[0]["read"]) for who, calls in flat(r) if calls]
        print("     setup per call: " + ", ".join(f"{w} {s:,}" for w, s in firsts[:6]))


if __name__ == "__main__":
    what = sys.argv[1] if len(sys.argv) > 1 else "report"
    {"baselines": baselines, "lite": lambda: lite(int(sys.argv[2]) if len(sys.argv) > 2 else 2),
     "team": team, "report": report}[what]()
