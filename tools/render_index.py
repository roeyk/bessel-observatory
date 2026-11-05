#!/usr/bin/env python3
# Render an offline catalogue from the manifest and recorded test results.
import html
import json
from pathlib import Path
import shlex

ROOT = Path(__file__).resolve().parents[1]
manifest = json.loads((ROOT / "manifest.json").read_text())
report_file = ROOT / "tests/report.json"
report = json.loads(report_file.read_text()) if report_file.exists() else {"results": []}
results = {row["id"]: row for row in report["results"]}
escape = html.escape
rows = []
# Keep the displayed language list alphabetical across catalogue rebuilds.
for item in sorted(manifest["languages"], key=lambda entry: entry["name"].casefold()):
    result = results.get(item["id"], {})
    status = result.get("status", "untested")
    detail = result.get("reason", f"{len(result.get('checks', []))} behavior checks passed.")
    commands = ["mkdir -p build build/pascal build/ada build/fortran build/haskell"]
    if item["build"]:
        commands.append(shlex.join(item["build"]))
    if item["id"] == "objc":
        commands.append('# macOS:\nclang -fobjc-exceptions bessel.m -framework Foundation -o build/bessel-objc')
        commands.append('# GNUstep (GNUstep development headers and Objective-C runtime required):\n'
                        'clang $(gnustep-config --objc-flags) bessel.m -o build/bessel-objc $(gnustep-config --base-libs)')
    if item["id"] == "sql":
        commands = ["psql -X -d observatory -v values='0,1,5,10' -v workers=2 -v output=results.csv -f bessel.sql"]
    elif item["id"] == "rpg":
        commands = ["See rpg_setup.txt for compilation and queue setup.", "CALL PGM(BESSELAB/BESSEL) PARM('/tmp/values.txt' '/tmp/results.csv' '2')"]
    else:
        commands.append(shlex.join(item["run"] + ["examples/values.txt", f"{item['id']}-results.csv", "2"]))
    support = ""
    for file in item.get("support", []):
        view = "" if file.endswith(".txt") else f' · <a href="code/{file.replace(chr(47), chr(95))}.html">highlighted</a>'
        support += f'<small><a href="{file}">{file}</a>{view}</small>'
    rows.append(f'''<tr data-search="{escape(' '.join([item['name'],item['runtime'],item['idioms'],item['multiprocessing']]).lower(), quote=True)}">
<th scope="row">{escape(item['name'])}<small>{escape(item['runtime'])}</small></th>
<td><a class="source" href="code/{item['source']}.html">View highlighted code →</a></td>
<td><a class="source" href="{item['source']}">{item['source']} ↗</a>{support}
<details><summary>Build &amp; run</summary><pre>{escape(chr(10).join(commands))}</pre></details></td>
<td>{escape(item['idioms'])}<small class="process">{escape(item['multiprocessing'])}</small><details><summary>Memory &amp; string features</summary><small>{escape(item.get('memory', ''))}</small><small>{escape(item.get('strings', ''))}</small></details></td>
<td><span class="badge {status}" title="{escape(detail, quote=True)}">{escape(status)}</span>
<small>{escape(detail)}</small></td></tr>''')
passed = sum(result.get("status") == "passed" for result in results.values())
source_links = ' · '.join(f'<a href="{s["url"]}">{escape(s["title"])}</a>' for s in manifest['sources'])
methodology = ''.join(f'<li>{escape(text)}</li>' for text in manifest['methodology'])
limitations = ''.join(f'<li>{escape(text)}</li>' for text in manifest['limitations'])
page = '''<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Bessel Observatory — __COUNT__ languages</title>
<style>
:root{color-scheme:dark;--bg:#101519;--panel:#192126;--line:#344047;--ink:#e6eeec;--muted:#a6b5b6;--accent:#9ae4bf}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font:16px/1.6 system-ui,sans-serif}
main{max-width:1380px;margin:auto;padding:44px 5vw 72px}a{color:var(--accent);text-underline-offset:4px}
nav{display:flex;flex-wrap:wrap;gap:24px;font-size:14px;border-bottom:1px solid var(--line);padding-bottom:18px}
.eyebrow{color:var(--accent);font-size:12px;font-weight:700;letter-spacing:.18em;text-transform:uppercase;margin-top:44px}
h1{font-size:clamp(36px,6vw,72px);font-weight:600;letter-spacing:-.05em;line-height:1.06;margin:14px 0 24px}
h2{font-size:28px;letter-spacing:-.02em;margin:50px 0 16px}h3{font-size:18px}p{max-width:840px}
.intro{font-size:20px;color:var(--muted);max-width:800px}.stats{display:flex;gap:34px;flex-wrap:wrap;margin:28px 0}
.stats b{font-size:26px;display:block}.stats span{font-size:13px;color:var(--muted)}
.plot{background:var(--panel);border:1px solid var(--line);border-radius:10px;padding:22px;margin:28px 0}
svg{display:block;width:100%;height:auto;max-height:260px}.plot label{display:block;font-size:14px}.plot input{width:min(560px,100%);accent-color:var(--accent)}
.plot output{display:inline-block;margin-left:16px;font-family:monospace}.muted,small{color:var(--muted)}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(320px,1fr));gap:20px}.card{padding:22px;background:var(--panel);border:1px solid var(--line);border-radius:8px}
.card h3{margin-top:0}code,pre{font:13px/1.6 ui-monospace,SFMono-Regular,Consolas,monospace}
pre{padding:14px;background:#0b1013;border:1px solid var(--line);border-radius:6px;overflow:auto;white-space:pre-wrap;overflow-wrap:anywhere}
.filter{width:100%;max-width:500px;background:var(--panel);border:1px solid var(--line);color:var(--ink);font:inherit;padding:10px 14px;border-radius:6px;margin:8px 0 22px}
.table-wrap{overflow-x:auto}table{width:100%;border-collapse:collapse;text-align:left;min-width:850px}th,td{padding:18px 12px;vertical-align:top;border-bottom:1px solid var(--line)}
thead th{text-transform:uppercase;letter-spacing:.12em;font-size:11px;color:var(--muted);background:var(--panel)}tbody th{width:16%;font-size:17px}td:nth-child(2){width:14%}td:nth-child(3){width:22%}td:nth-child(4){width:30%}td:nth-child(5){width:18%}
small{display:block;font-size:12px;line-height:1.6;font-weight:400;margin-top:7px}.process{border-left:2px solid #55746a;padding-left:10px;margin-top:12px}
.source{font-family:monospace;font-size:14px}summary{cursor:pointer;color:var(--muted);font-size:12px;margin-top:12px}.badge{display:inline-block;border:1px solid var(--line);border-radius:30px;font-size:11px;text-transform:uppercase;letter-spacing:.08em;padding:3px 10px}
.passed{background:#1b3e31;color:#a3ebc4}.untested{background:#3b3220;color:#e7c584}.failed{background:#4d2525;color:#ffbbbb}
li{margin-bottom:8px}footer{margin-top:50px;border-top:1px solid var(--line);padding-top:20px;font-size:12px;color:var(--muted)}
:focus-visible{outline:2px solid var(--accent);outline-offset:5px}[hidden]{display:none!important}
@media print{body{background:white;color:black}nav,.filter,.plot input{display:none}small{color:#555}a{color:#173f32}details{display:block}main{padding:0}.badge{background:white;color:black}}
</style></head><body><main>
<nav aria-label="Project navigation"><a href="#languages">Languages</a><a href="#contract">Shared behavior</a><a href="#method">Methodology</a><a href="#sql">SQL edition</a><a href="manifest.json">Manifest JSON</a><a href="tests/report.json">Test evidence</a></nav>
<div class="eyebrow">A comparative programming experiment</div>
<h1>Bessel Observatory<br><span style="color:var(--accent)">__COUNT__ languages. One wave.</span></h1>
<p class="intro">Read numbers. Launch worker processes. Compute an oscillating special function. Write a CSV. The same small experiment, expressed in the native style of each language.</p>
<div class="stats"><div><b>__COUNT__</b><span>independent implementations</span></div><div><b>16,384</b><span>quadrature samples per value</span></div><div><b>__PASSED__ / __COUNT__</b><span>editions passed execution checks</span></div></div>
<div class="plot"><svg id="wave" viewBox="0 0 1000 220" role="img" aria-labelledby="wave-title wave-desc">
<title id="wave-title">Bessel function J₀ from zero to thirty</title><desc id="wave-desc">The function starts at one, crosses zero near 2.4, and oscillates with a decreasing amplitude.</desc>
<path d="M40 135H975 M40 15V200" stroke="#546069" fill="none"/><path id="curve" stroke="#9ae4bf" stroke-width="2.5" fill="none"/>
<text x="18" y="30" fill="#a6b5b6" font-size="12">1</text><text x="18" y="140" fill="#a6b5b6" font-size="12">0</text><text x="950" y="215" fill="#a6b5b6" font-size="12">x = 30</text>
<circle id="dot" r="5" fill="#f2cf83"/></svg>
<label for="x">Explore the curve (browser preview)</label><input id="x" type="range" min="0" max="30" step="0.05" value="5"><output id="value" for="x"></output>
<small>The preview runs in the browser. The linked source programs perform the computation in separate OS processes.</small></div>
<div class="grid"><div class="card"><h3>Start with Python</h3><pre>python3 bessel.py examples/values.txt results.csv 2
python3 bessel.py - results.csv 4</pre><p>Run commands from this project directory. The second command prompts for one value per line. A blank line or EOF finishes.</p><a href="examples/values.txt">Sample values</a> · <a href="examples/mixed.txt">Invalid-input example</a></div>
<div class="card"><h3>The mathematical contract</h3><p><strong>J₀(x) = (1/π) ∫₀ᵖⁱ cos(x sin θ) dθ</strong></p><p>Every implementation approximates this integral at 16,384 equally spaced midpoints. Inputs are restricted to −1000 ≤ x ≤ 1000.</p><p><a href="https://dlmf.nist.gov/10.9#E1">NIST’s Bessel integral</a> supplies the common definition. This is a numerical demonstration, not a certified special-function library.</p></div></div>
<h2 id="languages">Explore the implementations</h2>
<p class="muted">Open a syntax-highlighted HTML view or the adjacent raw source file, and expand its build instructions. “Untested” means execution has not been verified here; it does not mean a stub. Each edition contains its numerical kernel and process orchestration. Bash embeds an awk kernel; Oberon and Perligata disclose their small OS/syntax adapters. RPG uses native IBM i jobs.</p>
<label for="filter">Filter by language, runtime, idiom, or process model</label><br><input id="filter" class="filter" type="search" placeholder="Try: pattern matching, POSIX, JVM…" autocomplete="off">
<div class="table-wrap"><table><thead><tr><th>Language / dialect</th><th>Highlighted code</th><th>Raw source &amp; commands</th><th>Language character / processes</th><th>Validation</th></tr></thead><tbody>__ROWS__</tbody></table></div>
<p id="empty" hidden>No languages match this filter.</p>
<h2 id="contract">Shared behavior</h2><div class="grid"><div class="card"><h3>Inputs &amp; arguments</h3><pre>PROGRAM [INPUT|- [OUTPUT [WORKERS]]]</pre><p>Defaults: standard input, <code>results.csv</code>, two workers. Workers must be an integer from 1 to 16. Files and interactive input accept one decimal real per line, ignore <code>#</code> comment lines, and end at the first blank line or EOF. At most 4,096 valid values are accepted.</p><p>Native numeric parsers may accept additional literal forms. Decimal and scientific <code>e</code> notation are the common interchange format.</p></div>
<div class="card"><h3>Outputs &amp; failures</h3><pre>x,j0,worker_pid
0,1,12345
1,0.7651976865579666,12346</pre><p>Rows preserve input order; the PID identifies the numerical worker. Invalid value lines are reported and skipped. Invalid arguments, empty input, I/O failures, and worker failures produce diagnostics and a nonzero exit. Output replaces the specified file after calculations complete.</p><p>Process IDs, decimal formatting, and final rounding vary by implementation. PIDs above are illustrative.</p></div></div>
<h2 id="method">Goals &amp; methodology</h2><p>The aim is to compare how languages express the same work: ownership in Rust, relations in Prolog, conditions and restarts in Lisp, records and streams in Java, file statuses in COBOL, and structural matching in Python. The <a href="manifest.json">manifest</a> records the full project description, goals, methodology, dependencies and constraints.</p><ol>__METHOD__</ol>
<h3>Reproduce the checks</h3><pre>python3 tests/verify.py
python3 tests/verify.py --only python,c,rust
python3 tools/render_sources.py  # requires Pygments to regenerate pages
python3 tools/render_index.py</pre><p>The runner builds available editions and checks reference values, CSV ordering, subprocess IDs, a single-worker run, malformed lines, stdin, argument errors, file failures, empty input and the input-size bound. Missing toolchains are recorded as untested. Reference values were generated with <code>mpmath.besselj</code> at 80 decimal digits; the absolute comparison tolerance is 10⁻¹⁰. See <a href="tests/reference.json">reference data</a> and <a href="tests/report.json">recorded results</a>.</p>
<h2 id="sql">SQL: a database-native edition</h2><p><code>bessel.sql</code> targets PostgreSQL with PL/pgSQL and <code>dblink</code>. Run it in a dedicated database. The script creates the extension if absent and temporary tables for the session. Each worker connection has a separate backend OS process; its numerical kernel is an aggregate over <code>generate_series</code>.</p>
<pre>psql -X -d observatory -v values='0,1,5,10' -v workers=2 -v output=results.csv -f bessel.sql
# Interactive comma-separated input:
psql -X -d observatory -f bessel.sql
# Server-side file input:
psql -X -d observatory -v input=/absolute/server/path/values.txt -f bessel.sql</pre>
<p>Connections must authenticate to the same database. An optional <code>-v conn='service=observatory'</code> selects a libpq service. File input uses <code>pg_read_file</code> on the database server and requires the corresponding permissions; CSV output is local to <code>psql</code>. Do not use <code>--single-transaction</code>, because worker connections must see the committed extension. PostgreSQL failures are reported by <code>psql</code> with <code>ON_ERROR_STOP</code>.</p>
<h2>Additional dialects</h2><p><a href="rpg_setup.txt">RPG setup and its IBM i interface</a> explains CALL parameters, IFS paths, queue concurrency and job-message errors. Oberon-2 uses Oxford OBC with the supplied C OS adapter. Install Perligata with <code>cpanm Lingua::Romana::Perligata</code>; its source marks the small Perl bridge explicitly. Bash uses the embedded awk loop for floating-point arithmetic.</p><h3>Comments</h3><p>Function contracts describe purpose, inputs, outputs and callers. Comments explain functional effects. Native block comments are used where available; Python uses #, RPG uses //, and Perligata uses ecce documentation blocks and adnota.</p><h3>Pointers, references, and strings</h3><p>The source files include explicit pointer arithmetic where the target supports it. Each unsafe example documents its bounds and allocation lifetime. Managed languages use checked buffer offsets or object references; SQL, Erlang, and Prolog expose different models. Expand “Memory &amp; string features” in the table or open a highlighted source page to see the precise mapping. String manipulation includes whitespace normalization, prefix and token checks, numeric conversion, and CSV construction.</p><h3>Comparison limits</h3><ul>__LIMITS__</ul>
<footer>Built as a local source catalogue. No CDN, web server, or network connection is needed to browse this page.<br>Primary references: __SOURCES__</footer>
</main><script>
const search=document.querySelector('#filter'), rows=[...document.querySelectorAll('tbody tr')];
search.addEventListener('input',()=>{const q=search.value.trim().toLowerCase();let n=0;for(const row of rows){row.hidden=!row.dataset.search.includes(q);if(!row.hidden)n++;}document.querySelector('#empty').hidden=n!==0;});
function j0(x){let sum=0;const n=2048;for(let k=0;k<n;k++)sum+=Math.cos(x*Math.sin(Math.PI*(k+.5)/n));return sum/n;}
const px=x=>40+x/30*935, py=y=>135-y*110;
document.querySelector('#curve').setAttribute('d',Array.from({length:601},(_,i)=>`${i?'L':'M'}${px(i/20).toFixed(2)} ${py(j0(i/20)).toFixed(2)}`).join(' '));
const slider=document.querySelector('#x');function update(){const x=Number(slider.value),y=j0(x);document.querySelector('#dot').setAttribute('cx',px(x));document.querySelector('#dot').setAttribute('cy',py(y));document.querySelector('#value').textContent=`x = ${x.toFixed(2)}   J₀(x) ≈ ${y.toFixed(8)}`;}slider.addEventListener('input',update);update();
</script></body></html>
'''
for marker, value in {"__COUNT__": str(len(manifest["languages"])), "__PASSED__": str(passed), "__ROWS__": "\n".join(rows),
                      "__METHOD__": methodology, "__LIMITS__": limitations,
                      "__SOURCES__": source_links}.items():
    page = page.replace(marker, value)
(ROOT / "index.html").write_text(page)
print(f"Rendered {len(rows)} source links; {passed} editions passed checks.")
