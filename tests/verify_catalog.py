#!/usr/bin/env python3
# Verify that the offline source catalogue faithfully represents its source files.
import hashlib
import json
from functools import lru_cache
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import unquote, urlsplit

ROOT = Path(__file__).resolve().parents[1]


# Collect links, table rows, raw text and source hashes without rendering a page.
# Inputs: HTML supplied to feed. Outputs: parsed attributes on this instance.
# Used by: the checks below to validate every generated page using only stdlib.
class Page(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.links = []
        self.ids = set()
        self.rows = 0
        self.digest = None
        self.raw = ''
        self.reading_raw = False
        self.search = {}
        self.adaptations = {}
        self.current_edition = None
        self.current_adaptation = None

    # Capture navigation and source-integrity metadata; input is one start tag.
    # Output: updated page fields. Called by HTMLParser while consuming HTML.
    def handle_starttag(self, tag, attributes):
        attrs = dict(attributes)
        if 'id' in attrs:
            self.ids.add(attrs['id'])
        if tag == 'tr' and 'data-search' in attrs:
            self.rows += 1
            self.current_edition = attrs['id'].removeprefix('language-')
            assert self.current_edition not in self.search, 'duplicate language row'
            self.search[self.current_edition] = attrs['data-search']
        if tag == 'details' and attrs.get('class') == 'adaptations':
            edition = attrs['data-edition']
            assert edition == self.current_edition, 'adaptations in the wrong row'
            assert edition not in self.adaptations, 'duplicate adaptation panel'
            self.current_adaptation = edition
            self.adaptations[edition] = {'status': attrs['data-evidence'], 'count': 0, 'text': ''}
        if tag == 'div' and attrs.get('class') == 'adaptation-note':
            assert self.current_adaptation, 'adaptation outside an edition panel'
            self.adaptations[self.current_adaptation]['count'] += 1
        if tag in ('a', 'link', 'script'):
            self.links.append(attrs.get('href', attrs.get('src', '')))
        if tag == 'meta' and attrs.get('name') == 'source-sha256':
            self.digest = attrs['content']
        if tag == 'textarea' and attrs.get('id') == 'raw':
            self.reading_raw = True

    # Stop raw-source capture at its container boundary.
    # Input: closing tag. Output: capture flag. Called by HTMLParser.
    def handle_endtag(self, tag):
        if tag == 'textarea':
            self.reading_raw = False
        if tag == 'details':
            self.current_adaptation = None
        if tag == 'tr':
            self.current_edition = None

    # Retain exact raw text, including whitespace and decoded HTML entities.
    # Input: text node. Output: accumulated source. Called by HTMLParser.
    def handle_data(self, data):
        if self.reading_raw:
            self.raw += data
        if self.current_adaptation:
            self.adaptations[self.current_adaptation]['text'] += data


# Parse a local HTML document for the integrity checks.
# Input: path. Output: populated Page. Used by the catalogue and per-source loops.
@lru_cache(maxsize=None)
def read_page(path):
    page = Page()
    page.feed(path.read_text())
    return page


manifest = json.loads((ROOT / 'manifest.json').read_text())
report = json.loads((ROOT / 'tests/report.json').read_text())
entries = manifest['languages']
assert len(entries) == manifest['language_count']
assert len({entry['id'] for entry in entries}) == len(entries)
index = read_page(ROOT / 'index.html')
assert index.rows == len(entries)
evidence = {result['id']: result for result in report['results']}
assert set(evidence) == {entry['id'] for entry in entries}
assert set(index.adaptations) == set(evidence), 'missing or extra adaptation panels'
sources = []
for entry in entries:
    source = entry['source']
    assert source in index.links and entry['highlighted'] in index.links
    digest = hashlib.sha256((ROOT / source).read_bytes()).hexdigest()
    assert evidence[entry['id']]['source_sha256'] == digest, f'stale evidence: {source}'
    # A changed bridge invalidates a pass even when the Latin listing is unchanged.
    dependencies = {
        path: hashlib.sha256((ROOT / path).read_bytes()).hexdigest()
        for path in entry.get('validation_dependencies', [])
    }
    assert evidence[entry['id']].get('dependency_sha256', {}) == dependencies, \
        f'stale dependency evidence: {source}'
    # Every declared note must be visible, searchable and tied to actual evidence.
    notes = entry['adaptations']
    panel = index.adaptations[entry['id']]
    assert notes and panel['count'] == len(notes), f'missing adaptation notes: {source}'
    assert panel['status'] == evidence[entry['id']]['status'], f'stale adaptation status: {source}'
    for note in notes:
        assert note['kind'] in {'workaround', 'platform', 'native'} and note['references']
        for field in ('objective', 'constraint', 'approach', 'tradeoff'):
            assert note[field] in panel['text'], f'missing adaptation {field}: {source}'
            assert note[field].lower() in index.search[entry['id']], f'unsearchable note: {source}'
    sources.append(source)
    sources.extend(file for file in entry.get('support', []) if not file.endswith('.txt'))

# Raw text inside the highlighted page must be an exact copy of the source.
for source in sources:
    page = read_page(ROOT / 'code' / (source.replace('/', '_') + '.html'))
    assert page.raw == (ROOT / source).read_text(), f'text mismatch: {source}'
    assert page.digest == hashlib.sha256(page.raw.encode()).hexdigest()

# Resolve every local navigation, stylesheet and download path offline.
for file in [ROOT / 'index.html', *sorted((ROOT / 'code').glob('*.html'))]:
    page = read_page(file)
    for link in page.links:
        url = urlsplit(link)
        if url.scheme or url.netloc:
            continue
        target = (file.parent / unquote(url.path)).resolve() if url.path else file
        assert target.is_relative_to(ROOT), f'escaped catalogue: {file}: {link}'
        assert target.is_file(), f'broken local link: {file}: {link}'
        if url.fragment and target.suffix == '.html':
            assert url.fragment in read_page(target).ids, f'missing anchor: {link}'
print(f'Catalog passed: {len(entries)} languages, {len(sources)} exact source views, '
      f'{sum(len(entry["adaptations"]) for entry in entries)} adaptation notes, all local links valid.')
