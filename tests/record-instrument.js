// Records a tests\run-instrument.ps1 results file into the unit-test instrument through the
// page's own engine (toggleStep / setVerdict / setField / header inputs), confirms the dashboard
// tally, and prints the engine-built report to PDF. Headless Chrome is driven over the DevTools
// protocol so nothing has to be installed beyond Chrome and Node.
//
// Usage (repository root):
//   node --experimental-websocket tests\record-instrument.js [results.json] [report.pdf]
// The run state stays in the headless profile under %TEMP%\tpscli-uts-profile.
'use strict';
const fs = require('fs'), path = require('path'), os = require('os');
const { spawn } = require('child_process');

const root = path.resolve(__dirname, '..');
function localDate() { const d = new Date(), p = n => (n < 10 ? '0' : '') + n; return d.getFullYear() + '-' + p(d.getMonth() + 1) + '-' + p(d.getDate()); }
const resultsFile = path.resolve(root, process.argv[2] || 'docs\\Testing\\Tpscli-Unit-Test-Results.json');
const pdfFile = path.resolve(root, process.argv[3] || `docs\\Testing\\Tpscli-Unit-Test-Report-${localDate()}.pdf`);
const page = path.resolve(root, 'docs\\Testing\\Tpscli-Unit-Test-Cases.html');
const chrome = ['C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe',
                'C:\\Program Files (x86)\\Google\\Chrome\\Application\\chrome.exe',
                'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe'].find(fs.existsSync);
if (!chrome) { console.error('no Chrome or Edge found'); process.exit(2); }
if (typeof WebSocket === 'undefined') { console.error('run with: node --experimental-websocket'); process.exit(2); }

const results = JSON.parse(fs.readFileSync(resultsFile, 'utf8'));
// The page's evidence field is printed in the report, so it gets the command list with exit
// codes; the full captured output stays in the results JSON.
function evidenceSummary(text) {
  const out = []; let cmd = null;
  for (const line of text.split('\n')) {
    if (line.startsWith('> ')) { if (cmd) out.push(cmd); cmd = line.slice(2); if (cmd.length > 110) cmd = cmd.slice(0, 107) + '...'; }
    else if (cmd && /^  exit -?\d+$/.test(line)) { out.push(cmd + ' (' + line.trim() + ')'); cmd = null; }
  }
  if (cmd) out.push(cmd);
  return out.join('\n') + (out.length ? '\nFull output: ' + path.basename(resultsFile) : '');
}
const header = {
  tester: 'automated (tests\\run-instrument.ps1)', lead: '', date: results.started.slice(0, 10),
  build: results.build, env: results.env, component: 'tpscli.exe', ref: results.ref
};
const cases = results.cases.map(c => ({ id: c.id, steps: c.steps, verdict: c.verdict, notes: c.notes, evidence: evidenceSummary(c.evidence) }));

const profile = path.join(os.tmpdir(), 'tpscli-uts-profile');
const proc = spawn(chrome, ['--headless=new', '--disable-gpu', '--no-first-run', '--remote-debugging-port=0',
                            `--user-data-dir=${profile}`, 'file:///' + page.replace(/\\/g, '/')], { stdio: ['ignore', 'ignore', 'pipe'] });

function wsEndpoint() {
  return new Promise((resolve, reject) => {
    let buf = '';
    proc.stderr.on('data', d => { buf += d; const m = buf.match(/DevTools listening on (ws:\/\/[^\s]+)/); if (m) resolve(m[1]); });
    proc.on('exit', code => reject(new Error('chrome exited ' + code + '\n' + buf)));
    setTimeout(() => reject(new Error('no DevTools endpoint within 20 s\n' + buf)), 20000);
  });
}

async function main() {
  const browserWs = await wsEndpoint();
  const port = new URL(browserWs).port;
  let targets;
  for (let i = 0; i < 50; i++) {
    targets = await (await fetch(`http://127.0.0.1:${port}/json`)).json();
    if (targets.some(t => t.type === 'page' && t.url.startsWith('file:'))) break;
    await new Promise(r => setTimeout(r, 200));
  }
  const target = targets.find(t => t.type === 'page' && t.url.startsWith('file:'));
  if (!target) throw new Error('instrument page target not found');

  const ws = new WebSocket(target.webSocketDebuggerUrl);
  await new Promise((res, rej) => { ws.onopen = res; ws.onerror = rej; });
  let seq = 0; const pending = new Map();
  ws.onmessage = ev => { const m = JSON.parse(ev.data); if (m.id && pending.has(m.id)) { pending.get(m.id)(m); pending.delete(m.id); } };
  const send = (method, params = {}) => new Promise(res => { const id = ++seq; pending.set(id, res); ws.send(JSON.stringify({ id, method, params })); });
  const evaluate = async expr => {
    const r = await send('Runtime.evaluate', { expression: expr, awaitPromise: true, returnByValue: true });
    if (r.error || (r.result && r.result.exceptionDetails)) throw new Error(JSON.stringify(r.error || r.result.exceptionDetails));
    return r.result.result.value;
  };

  await send('Page.enable');
  // Fresh run in this profile, then reload so the engine starts from freshState().
  await evaluate('localStorage.removeItem(STORAGE_KEY); "cleared"');
  await send('Page.reload');
  await new Promise(r => setTimeout(r, 1500));
  await evaluate('typeof CASES !== "undefined" && CASES.length');

  const summary = await evaluate(`(function(){
    var header = ${JSON.stringify(header)}, cases = ${JSON.stringify(cases)};
    Object.keys(header).forEach(function(k){
      var el = document.getElementById("h_" + k); el.value = header[k]; el.dispatchEvent(new Event("input", {bubbles:true}));
    });
    cases.forEach(function(c){
      c.steps.forEach(function(b, i){ toggleStep(c.id, i, !!b); });
      setVerdict(c.id, c.verdict);
      setField(c.id, "notes", c.notes);
      setField(c.id, "evidence", c.evidence);
    });
    flushState(); renderAll();
    var t = tally();
    var ticked = document.querySelectorAll("#cases input[type=checkbox]:checked").length;
    var saved = JSON.parse(localStorage.getItem(STORAGE_KEY));
    var mismatches = cases.filter(function(c){ return saved.cases[c.id].verdict !== c.verdict; }).map(function(c){ return c.id; });
    return { tally: t, passRate: passRate(t), completion: completion(t), tickedCheckboxes: ticked,
             savedHeader: saved.header, verdictMismatches: mismatches, cleared: clearedToMerge() };
  })()`);
  console.log('dashboard: ' + JSON.stringify(summary));
  const expected = results.tally;
  if (summary.tally.PASS !== expected.PASS || summary.tally.FAIL !== expected.FAIL || summary.tally.BLOCKED !== expected.BLOCKED || summary.verdictMismatches.length) {
    throw new Error('dashboard tally does not match the results file: ' + JSON.stringify(expected));
  }
  const expectedTicks = cases.reduce((n, c) => n + c.steps.filter(Boolean).length, 0);
  if (summary.tickedCheckboxes !== expectedTicks) throw new Error(`ticked ${summary.tickedCheckboxes} checkboxes, expected ${expectedTicks}`);

  await evaluate('flushState(); buildReport(); "built"');
  const pdf = await send('Page.printToPDF', { printBackground: true, preferCSSPageSize: true });
  if (!pdf.result || !pdf.result.data) throw new Error('printToPDF failed: ' + JSON.stringify(pdf));
  fs.writeFileSync(pdfFile, Buffer.from(pdf.result.data, 'base64'));
  console.log(`report: ${path.relative(root, pdfFile)} (${fs.statSync(pdfFile).size} bytes)`);
  console.log(`state saved under ${results.storage_key} in profile ${profile}`);
  ws.close();
}
main().then(() => { proc.kill(); process.exit(0); },
            err => { console.error(err.stack || err); proc.kill(); process.exit(1); });
