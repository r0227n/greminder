#!/usr/bin/env python3
"""Check language coverage and printf argument compatibility without third-party tools."""
import json
import re
from pathlib import Path

root = Path(__file__).resolve().parents[1]
literal = r'"(?:[^"\\]|\\.)*"'
entry = re.compile(rf'^({literal})\s*=\s*({literal});$', re.MULTILINE)

def read(language):
    path = root / f'Greminder/Localizations/{language}.lproj/Localizable.strings'
    pairs = [(json.loads(k), json.loads(v)) for k, v in entry.findall(path.read_text())]
    assert len(dict(pairs)) == len(pairs), f'Duplicate keys: {language}'
    assert all(value for _, value in pairs), f'Empty translation: {language}'
    return dict(pairs)

def arguments(value):
    tokens = re.findall(r'%(?:(\d+)\$)?@', value)
    return sorted(int(index) if index else i + 1 for i, index in enumerate(tokens))

ja, en = read('ja'), read('en')
assert ja.keys() == en.keys(), 'Japanese and English keys differ'
for key in ja:
    assert arguments(ja[key]) == arguments(en[key]), f'Argument mismatch: {key}'
for path in (root / 'Greminder').rglob('*.swift'):
    for key in re.findall(rf'L10n\.tr\(\s*({literal})', path.read_text()):
        assert json.loads(key) in en, f'Missing key in {path}: {key}'
print(f'Localization check passed: {len(en)} keys in Japanese and English.')

# The extension ships a lightweight resource bundle, independent of GreminderKit.
def read_share(language):
    path = root / f'ShareSupport/Localizations/{language}.lproj/Localizable.strings'
    pairs = [(json.loads(k), json.loads(v)) for k, v in entry.findall(path.read_text())]
    assert len(dict(pairs)) == len(pairs), f'Duplicate share keys: {language}'
    assert all(value for _, value in pairs), f'Empty share translation: {language}'
    return dict(pairs)
share_ja, share_en = read_share('ja'), read_share('en')
assert share_ja.keys() == share_en.keys(), 'Share extension language keys differ'
for folder in ['ShareSupport', 'ShareExtension']:
    for path in (root / folder).rglob('*.swift'):
        for key in re.findall(rf'strings\(\s*({literal})', path.read_text()):
            assert json.loads(key) in share_en, f'Missing share key in {path}: {key}'
print(f'Share localization check passed: {len(share_en)} keys in Japanese and English.')
