// Stand-in for tpscli.exe in the runner tests. The runner launches it as
//   node test/fake-tpscli.js <mode> [anything]
// so the mode arrives as the first "argument" the runner was given. Output goes through
// process.exitCode, never process.exit(): on Windows a pipe write is asynchronous and exit()
// would truncate it.
const mode = process.argv[2];
const out = s => process.stdout.write(s);

switch (mode) {
  case 'ok':
    out('{ "ok": true, "op": "select", "columns": [], "rows": [], "row_count": 0, "truncated": false, "complete": true }\n');
    break;
  case 'err3':
    out('{ "ok": false, "op": "update", "error": { "code": "RECORD_HELD", "message": "held" }, "outcome": "rolled_back", "complete": true }\n');
    process.exitCode = 3;
    break;
  case 'ok-exit1':          // ok:true but exit 1: the object disagrees with the exit code
    out('{ "ok": true, "op": "select", "complete": true }\n');
    process.exitCode = 1;
    break;
  case 'notcomplete':
    out('{ "ok": true, "op": "select", "complete": false }\n');
    break;
  case 'incomplete':        // cut off mid-object, as a crash would leave it
    out('{ "ok": true, "op": "select", "rows": [[1');
    break;
  case 'table':
    out('ID  NAME \n--  -----\n 1  Able \n(1 rows)\n');
    break;
  case 'garbage':
    out('not json at all\n');
    process.stderr.write('boom\n');
    process.exitCode = 3;
    break;
  case 'empty':
    break;
  case 'exit9':
    process.exitCode = 9;
    break;
  case 'flood': {           // 200 MiB, honouring backpressure, so the runner's ceiling is what stops it
    const chunk = 'x'.repeat(1024 * 1024);
    let n = 0;
    const pump = () => {
      while (n < 200 && process.stdout.write(chunk)) n++;
      if (n < 200) process.stdout.once('drain', pump);
    };
    pump();
    break;
  }
  case 'hang':              // prints its pid so the test can prove it was killed
    out(`${process.pid}\n`);
    setInterval(() => {}, 1000);
    break;
  default:
    process.stderr.write(`fake-tpscli: unknown mode ${mode}\n`);
    process.exitCode = 99;
}
