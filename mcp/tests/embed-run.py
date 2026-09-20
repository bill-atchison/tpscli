"""Embeds the run that tests\\record-instrument.cjs just recorded into the unit-test instrument.

    python tests\\embed-run.py [state.json]

Replaces the `var SEED_STATE = ...;` line of ..\\docs\\Testing\\TpscliMcp-Unit-Test-Cases.html with
the exact state the page's engine saved (default %TEMP%\\tpscli-mcp-uts-state.json), so the
document opens showing that run wherever it is copied. Line endings stay CRLF; nothing else in
the file changes. Run it from mcp\\ after record-instrument.cjs.
"""
import json, os, sys, tempfile

here = os.path.dirname(os.path.abspath(__file__))
page = os.path.join(here, '..', '..', 'docs', 'Testing', 'TpscliMcp-Unit-Test-Cases.html')
state_file = sys.argv[1] if len(sys.argv) > 1 else os.path.join(tempfile.gettempdir(), 'tpscli-mcp-uts-state.json')

state = json.load(open(state_file, encoding='utf-8'))
state['resumed'] = False
verdicts = [c.get('verdict') for c in state['cases'].values()]
seed = json.dumps(state, separators=(',', ':'), ensure_ascii=False).encode('utf-8')

data = open(page, 'rb').read()
lines = data.split(b'\r\n')
idx = [i for i, l in enumerate(lines) if l.startswith(b'var SEED_STATE = ')]
if len(idx) != 1:
    sys.exit(f'expected exactly one "var SEED_STATE = " line in {page}, found {len(idx)}')
lines[idx[0]] = b'var SEED_STATE = ' + seed + b';'
out = b'\r\n'.join(lines)
open(page, 'wb').write(out)
crlf = out.count(b'\r\n')
print(f"embedded {state['header'].get('date')} build {state['header'].get('build')}: "
      f"{len(verdicts)} cases, PASS {verdicts.count('PASS')} FAIL {verdicts.count('FAIL')} BLOCKED {verdicts.count('BLOCKED')}; "
      f"CRLF {crlf} lone-LF {out.count(b'\n') - crlf}")
