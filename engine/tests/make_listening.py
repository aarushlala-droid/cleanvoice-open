"""Level-matched A/B files: original vs cleaned (default) vs fully cleaned, plus an HTML page to play them."""
import html, json, os, sys
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import cleanvoice as cv

out = sys.argv[1]
clips = sys.argv[2:]
TARGET = -20.0
rows = []
for i, path in enumerate(clips, 1):
    clip = cv.Clip(path)
    name = os.path.splitext(os.path.basename(path))[0]
    orig = clip.work if clip.linked else clip.work
    orig = orig.copy()
    orig *= np.float32(10 ** ((TARGET - cv.integrated_lufs(orig)) / 20))
    orig = cv.limit(orig, -1.0)
    files = {"Original": f"{i:02d}_{name}_1_original.wav"}
    cv.write_wav(os.path.join(out, files["Original"]), orig)
    info = {}
    for label, extra in (("Cleaned", {}), ("Fully cleaned", {"full": True})):
        y, st = cv.render(clip, {"loudness": TARGET, **extra})
        if clip.linked and y.shape[0] > 1:
            y = y[:1]
        f = f"{i:02d}_{name}_{2 if label == 'Cleaned' else 3}_{label.lower().replace(' ', '_')}.wav"
        cv.write_wav(os.path.join(out, f), y)
        files[label] = f
        info[label] = st
    a = info["Cleaned"].get("auto") or {}
    rows.append({"name": name, "files": files, "model": info["Cleaned"]["model_label"],
                 "scores": a.get("scores", {}), "hum": clip.hum, "before": clip.noise_floor_db,
                 "after": info["Cleaned"]["noise_floor_db"], "after_full": info["Fully cleaned"]["noise_floor_db"],
                 "warnings": info["Cleaned"]["warnings"]})
    print("done", name, flush=True)

def score(r, k):
    v = r["scores"].get(k)
    return f"{v['ovrl']:.2f}" if v else "–"

cards = []
for r in rows:
    hum = f"{r['hum']['base']} Hz hum removed" if r["hum"]["base"] else "No mains hum found"
    players = "".join(
        f'<div class="p"><div class="lbl">{html.escape(k)}</div><audio controls preload="none" src="{html.escape(v)}"></audio></div>'
        for k, v in r["files"].items())
    sc = " · ".join(f"{m}: {score(r, m)}" for m in ["original", *cv.MODELS] if m in r["scores"])
    warn = "".join(f'<div class="warn">{html.escape(w)}</div>' for w in r["warnings"])
    cards.append(f'''<section><h2>{html.escape(r["name"])}</h2>
<p class="meta">Model chosen: <b>{html.escape(r["model"])}</b> · {hum} · background {r["before"]:.1f} dB → {r["after"]} dB (cleaned) → {r["after_full"]} dB (fully cleaned)</p>
<div class="row">{players}</div><p class="scores">Quality score (DNSMOS, 1–5): {sc}</p>{warn}</section>''')

page = f'''<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>CleanVoice listening test</title><style>
:root{{--bg:#f6f6f4;--card:#fff;--text:#1d1d1f;--muted:#6e6e73;--line:#e3e3e0;--accent:#2f6fde;--warn:#a15c00}}
@media (prefers-color-scheme:dark){{:root{{--bg:#161617;--card:#1f1f21;--text:#f2f2f2;--muted:#a1a1a6;--line:#333;--accent:#6ea0ff;--warn:#f0b35a}}}}
body{{margin:0;background:var(--bg);color:var(--text);font:15px/1.45 -apple-system,BlinkMacSystemFont,"Helvetica Neue",sans-serif}}
main{{max-width:1000px;margin:0 auto;padding:28px 16px 60px}} h1{{font-size:24px;margin:0 0 6px}}
.intro{{color:var(--muted);margin:0 0 22px}} section{{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:16px 18px;margin:0 0 14px}}
h2{{font-size:16px;margin:0 0 4px}} .meta,.scores{{color:var(--muted);font-size:13px;margin:4px 0}}
.row{{display:grid;grid-template-columns:repeat(auto-fit,minmax(260px,1fr));gap:12px;margin:10px 0}}
.lbl{{font-size:12px;font-weight:600;text-transform:uppercase;letter-spacing:.04em;color:var(--accent);margin-bottom:4px}}
audio{{width:100%}} .warn{{color:var(--warn);font-size:13px}}</style></head><body><main>
<h1>CleanVoice listening test</h1>
<p class="intro">All three versions of each clip are matched to the same loudness (-20 LUFS), so you're comparing cleanliness, not volume. Headphones help. <b>Cleaned</b> is the default (faint room tone kept); <b>Fully cleaned</b> removes all background. Clips 2-6 are deliberately bad samples built from DeepFilterNet's public test audio (real speech, real street noise, a real room echo, added mains hum).</p>
{"".join(cards)}</main>
<script>document.querySelectorAll("audio").forEach(a=>a.addEventListener("play",()=>document.querySelectorAll("audio").forEach(b=>{{if(b!==a)b.pause()}})));</script>
</body></html>'''
open(os.path.join(out, "index.html"), "w").write(page)
json.dump(rows, open(os.path.join(out, "results.json"), "w"), indent=1)
print("page written")
