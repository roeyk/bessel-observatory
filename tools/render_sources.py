#!/usr/bin/env python3
# Generate offline, syntax-highlighted source pages (requires Pygments).
import hashlib
import html
import json
from pathlib import Path

from pygments import highlight
from pygments.formatters import HtmlFormatter
from pygments.lexers import get_lexer_by_name
from catalog_lexers import OberonLexer, RpgLexer, PerligataLexer, FreeBasicLexer

ROOT = Path(__file__).resolve().parents[1]
manifest = json.loads((ROOT / "manifest.json").read_text())
target = ROOT / "code"
target.mkdir(exist_ok=True)
aliases = {"pascal": "pascal", "basic": "qbasic", "objc": "objective-c",
           "lisp": "common-lisp", "sql": "postgresql", "cobol": "cobolfree"}
formatter = HtmlFormatter(style="native", linenos="table", lineanchors="L",
                          anchorlinenos=True, cssclass="highlight")
css = '''
:root{color-scheme:dark}*{box-sizing:border-box}body{margin:0;background:#101519;color:#e6eeec;font:15px/1.6 system-ui,sans-serif}
header{padding:24px 4vw;border-bottom:1px solid #344047}nav{display:flex;gap:22px;flex-wrap:wrap}a{color:#9ae4bf;text-underline-offset:4px}
h1{font-size:30px;margin:18px 0 8px}p{color:#b9c5c5;max-width:1000px}code{font-family:ui-monospace,Consolas,monospace}
.actions{display:flex;align-items:center;gap:20px;flex-wrap:wrap}button{border:1px solid #54646a;background:#192126;color:#e6eeec;border-radius:5px;padding:8px 14px;cursor:pointer}
main{margin:24px 3vw;overflow:auto;border:1px solid #344047;border-radius:8px}.highlight{background:#202020!important}
.highlight table{border-collapse:collapse;width:100%}.highlight td{vertical-align:top;padding:0}.highlight pre{margin:0;padding:16px;font:13px/1.65 ui-monospace,SFMono-Regular,Consolas,monospace;tab-size:4}
.highlight .linenos{width:1%;user-select:none;background:#171c20}.linenos pre{padding-right:12px;text-align:right}.linenos a{color:#7e9698;text-decoration:none}
.code{width:99%}.wrap .code pre{white-space:pre-wrap;overflow-wrap:anywhere}.code a:target{background:#66572a}
footer{margin:20px 4vw 40px;color:#9bafaf;font-size:12px}button:focus-visible,a:focus-visible{outline:2px solid #9ae4bf;outline-offset:4px}
'''
(target / "code.css").write_text(css + formatter.get_style_defs(".highlight"))
languages = list(manifest["languages"])
program_count = len(languages)
for parent in manifest["languages"]:
    for source in parent.get("support", []):
        if source.endswith(".txt"):
            continue
        languages.append({"id": {".c":"c", ".sh":"bash", ".sql":"sql", ".pm":"perl"}[Path(source).suffix],
                          "name": parent["name"]+" support", "source": source,
                          "runtime": parent["runtime"], "idioms": "Support interface for "+parent["source"],
                          "support_page": True})
custom = {"oberon": OberonLexer, "rpg": RpgLexer, "perligata": PerligataLexer, "basic": FreeBasicLexer}
for i, item in enumerate(languages):
    source = (ROOT / item["source"]).read_text()
    lexer = (custom[item["id"]](stripnl=False, ensurenl=False) if item["id"] in custom else
             get_lexer_by_name(aliases.get(item["id"], item["id"]), stripnl=False, ensurenl=False))
    rendered = highlight(source, lexer, formatter)
    previous = languages[(i - 1) % len(languages)]
    following = languages[(i + 1) % len(languages)]
    e = html.escape
    digest = hashlib.sha256(source.encode()).hexdigest()
    memory = item.get("memory", "See the source for data references and process buffers.")
    strings = item.get("strings", "Input cleanup, parsing, and CSV formatting.")
    page = f'''<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><meta name="source-sha256" content="{digest}">
<title>{e(item['name'])} — {e(item['source'])} — Bessel Observatory</title><link rel="stylesheet" href="code.css"></head>
<body><header><nav><a href="../index.html#languages">← All {program_count} languages</a>
<a href="{previous['source'].replace('/', '_')}.html">← {e(previous['name'])}</a><a href="{following['source'].replace('/', '_')}.html">{e(following['name'])} →</a></nav>
<h1>{e(item['name'])} <code>{e(item['source'])}</code></h1>
<p>{e(item['runtime'])} · {e(item['idioms'])}</p>
<p><strong>Memory:</strong> {e(memory)}<br><strong>Strings:</strong> {e(strings)}</p>
<div class="actions"><a href="../{item['source']}">Open raw source</a>
<a href="../{item['source']}" download>Download source</a><button id="copy" type="button">Copy code</button>
<button id="wrap" type="button" aria-pressed="false">Wrap long lines</button><span id="notice" role="status"></span></div></header>
<main id="listing">{rendered}</main><textarea id="raw" hidden>{e(source)}</textarea>
<footer>Highlighted with Pygments using the {e(lexer.name)} lexer. All assets are local. <a href="../LICENSE">GPL-3.0-only</a>. SHA-256: <code>{digest}</code></footer>
<script>
document.querySelector('#wrap').addEventListener('click',event=>{{const on=document.querySelector('#listing').classList.toggle('wrap');event.currentTarget.setAttribute('aria-pressed',String(on));}});
document.querySelector('#copy').addEventListener('click',async()=>{{
const text=document.querySelector('#raw').value,notice=document.querySelector('#notice');
try{{await navigator.clipboard.writeText(text);notice.textContent='Copied.';}}
catch{{notice.textContent='Clipboard unavailable here; use Open raw source to select and copy.';}}
}});
</script></body></html>'''
    (target / (item["source"].replace("/", "_") + ".html")).write_text(page)
print(f"Rendered {len(languages)} highlighted source pages.")
