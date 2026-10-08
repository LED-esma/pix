#!/usr/bin/env python3
"""Pix full benchmark: tokens, cost, and time for every mode and the canvas.

  python3 bench/suite.py run       runs everything (~$2–3, ~10 min), saves bench/suite/*.json
  python3 bench/suite.py report    summarizes bench/suite/ and points out bottlenecks

Uses the exact code paths the app runs (`Pix --ask`, `Pix --time-canvas`).
"""
import json, pathlib, statistics, subprocess, sys, time

HERE = pathlib.Path(__file__).resolve().parent
PIX = str(HERE.parent / "dist/Pix.app/Contents/MacOS/Pix")
OUT = HERE / "suite"

RESEARCH = ("Compare the M5 MacBook Air and the M4 MacBook Air on current price and battery life, "
            "and recommend one for a college student")
CASES = [  # name, goal, members, extra args
    ("lite-math", "solve 2x² − 8x + 6 = 0 step by step", 0, []),
    ("lite-concept", "explain what a derivative actually means", 0, []),
    ("lite-research", RESEARCH, 0, []),
    ("lite-screen", "walk me through problem 3 step by step", 0, ["--image", str(HERE / "screen.jpg")]),
    ("lite-semester", "what's due this week?", 0, ["--use", "semester"]),
    ("standard", RESEARCH, 1, []),
    ("deep-2", RESEARCH, 2, []),
]
REPEATS = {"lite-math": 2, "lite-concept": 2, "lite-research": 2, "lite-screen": 2, "lite-semester": 1, "standard": 1, "deep-2": 1}
CANVAS = ["math", "plot", "plot3d", "physics", "chart", "flow", "circuit", "python"]


def run():
    OUT.mkdir(exist_ok=True)
    for name, goal, members, extra in CASES:
        for i in range(1, REPEATS[name] + 1):
            path = OUT / f"{name}-{i}.json"
            t = time.time()
            p = subprocess.run([PIX, "--ask", goal, str(path), str(members)] + extra, capture_output=True, text=True)
            print(f"{name}-{i:<3} {time.time() - t:6.1f}s  {p.stdout.strip().splitlines()[-1] if p.stdout.strip() else p.stderr[-200:]}", flush=True)
    timings = {}
    for c in CANVAS:
        runs = []
        for _ in range(3):  # first load is cold
            p = subprocess.run([PIX, "--time-canvas", str(HERE / "canvas" / f"{c}.html")], capture_output=True, text=True)
            try:
                runs.append(json.loads(p.stdout.strip().splitlines()[-1]))
            except (ValueError, IndexError):
                runs.append({"load": -1, "ready": -1})
        timings[c] = runs
        print(f"canvas {c:<8} " + "  ".join(f"load {r['load']:.2f}s ready {r['ready']:.2f}s" for r in runs), flush=True)
    (OUT / "canvas.json").write_text(json.dumps(timings, indent=1))


def tokens(d):
    return sum(u["total"] for u in d.get("usage", []))


def cost(d):
    return sum(u["cost"] for u in d.get("usage", []))


def report():
    rows = {}
    for p in sorted(OUT.glob("*-[0-9].json")):
        d = json.loads(p.read_text())
        rows.setdefault(p.stem.rsplit("-", 1)[0], []).append(d)

    print("\n## Runs (median of repeats)\n")
    print("| Run | Tokens | Cost | Time | Startup | First reply | Model time | Searches | Visuals |")
    print("|---|---:|---:|---:|---:|---:|---:|---:|---|")
    for name, ds in rows.items():
        ok = [d for d in ds if "error" not in d]
        if not ok:
            print(f"| {name} | error: {ds[0].get('error', '')[:60]} |"); continue
        med = lambda f: statistics.median(f(d) for d in ok)
        t = lambda d: d.get("timing", {})
        tl = lambda d: d.get("timeline", [])
        searches = med(lambda d: t(d).get("searches", sum(c.get("searches", 0) for c in tl(d))))
        startup = med(lambda d: t(d).get("startup", statistics.mean([c["startup"] for c in tl(d)]) if tl(d) else 0))
        first = med(lambda d: t(d).get("firstReply", 0)) if not tl(ok[0]) else None
        api = med(lambda d: t(d).get("apiSeconds", sum(c["apiSeconds"] for c in tl(d))))
        vis = ", ".join(v["kind"] for v in (ok[0].get("output") or {}).get("visuals", [])) or "none"
        print(f"| {name} | {med(tokens):,.0f} | ${med(cost):.3f} | {med(lambda d: d['seconds']):.1f}s | {startup:.1f}s"
              f" | {'—' if first is None else f'{first:.1f}s'} | {api:.1f}s | {searches:.0f} | {vis} |")

    for name in ("standard", "deep-2"):
        if name not in rows or "timeline" not in rows[name][0]:
            continue
        print(f"\n## {name}: where the time and tokens go\n")
        print("| Call | Model | Time | Startup | Model time | Searches | Tokens | Output |")
        print("|---|---|---:|---:|---:|---:|---:|---:|")
        for c in rows[name][0]["timeline"]:
            print(f"| {c['call']} | {c['model']} | {c['seconds']}s | {c['startup']}s | {c['apiSeconds']}s | {c['searches']} | {c['tokens']:,} | {c['output']:,} |")

    cv = OUT / "canvas.json"
    if cv.exists():
        print("\n## Canvas (cold → warm)\n")
        print("| Plugin | Load (cold) | Ready (cold) | Ready (warm) |")
        print("|---|---:|---:|---:|")
        for k, runs in json.loads(cv.read_text()).items():
            print(f"| {k} | {runs[0]['load']:.2f}s | {runs[0]['ready']:.2f}s | {min(r['ready'] for r in runs[1:]):.2f}s |")


if __name__ == "__main__":
    {"run": run, "report": report}[sys.argv[1] if len(sys.argv) > 1 else "report"]()
