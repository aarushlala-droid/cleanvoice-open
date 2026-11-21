"""Drive the JSON-lines worker the way the app does: ready -> models -> analyse -> preview -> preview(cached) -> export -> errors."""
import json, os, subprocess, sys, time
here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
clip, out = sys.argv[1], sys.argv[2]
p = subprocess.Popen([os.path.join(here, ".venv/bin/python"), "-I", os.path.join(here, "cleanvoice.py"), "serve"],
                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, bufsize=1)
def read_until(rid=None):
    events = []
    while True:
        m = json.loads(p.stdout.readline())
        if rid is None or m.get("id") == rid and "ok" in m:
            return m, events
        events.append(m)
def call(rid, **req):
    t = time.time(); p.stdin.write(json.dumps({"id": rid, **req}) + "\n"); p.stdin.flush()
    m, ev = read_until(rid); return m, ev, time.time() - t
t0 = time.time()
print("ready:", read_until()[0]["event"], f"{time.time()-t0:.1f}s")
print("loaded:", read_until()[0]["event"], f"{time.time()-t0:.1f}s")
m, _, dt = call(1, cmd="models"); print("models:", list(m["result"]["models"]))
m, _, dt = call(2, cmd="analyse", path=clip); print(f"analyse {dt:.2f}s", m["ok"], m["result"]["hum_harmonics"])
m, ev, dt = call(3, cmd="preview", path=clip, settings={}); r = m["result"]
print(f"preview(auto) {dt:.2f}s progress-events={len(ev)} model={r['stats']['model']} wav-exists={os.path.exists(r['wav'])}")
m, ev, dt = call(4, cmd="preview", path=clip, settings={"warmth": 1, "clarity": 4}); print(f"slider change {dt:.2f}s ok={m['ok']}")
m, ev, dt = call(5, cmd="preview", path=clip, settings={"warmth": 1, "clarity": 4}); print(f"same settings again (disk cache) {dt:.3f}s")
m, ev, dt = call(6, cmd="preview", path=clip, settings={"model": "spectral", "noise_reduction": 12}); print(f"model switch {dt:.2f}s {m['result']['stats']['model']}")
m, ev, dt = call(7, cmd="export", path=clip, settings={}, out_dir=out, root=os.path.dirname(clip)); print(f"export {dt:.2f}s", [os.path.basename(x) for x in m["result"]["outputs"]])
m, _, _ = call(8, cmd="preview", path="/nope.wav", settings={}); print("missing file ->", m)
m, _, _ = call(9, cmd="preview", path=clip, settings={"low_cut": "abc"}); print("bad setting ->", m)
m, _, _ = call(10, cmd="bogus"); print("bad cmd ->", m)
call(11, cmd="shutdown"); p.wait(5); print("exit code", p.returncode)
