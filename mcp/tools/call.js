// One MCP tool call from the command line, for the test instrument and for support staff.
//
//   '<json arguments>' | node tools\call.js <tool> [server flags...]
//   '[<args>, <args>, ...]' | node tools\call.js <tool>,<tool>,... [server flags...]
//
// The second form calls several tools in order on ONE server process (tps_set_roots and then
// tps_list_files, say) and prints a JSON array of results; exit 1 when any result is an error.
//
// Starts dist\server.js with the given flags (--root, --allow-writes, --owner, --timeout, --exe),
// calls one tool with the JSON object read from stdin (empty stdin means {}), prints the result
// (structuredContent as JSON, else the text content) and exits 0 when the tool result is not an
// error, 1 when it is, 2 when the server could not start or the call could not be made.
// The server's own stderr (ready line, one line per call) passes through.
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';

const [tool, ...serverArgs] = process.argv.slice(2);
if (!tool) {
  console.error("usage: '<json arguments>' | node tools\\call.js <tool>[,<tool>...] [server flags...]");
  process.exit(2);
}
const tools = tool.split(',');

let text = '';
if (!process.stdin.isTTY) for await (const chunk of process.stdin) text += chunk;
let args;
try {
  args = text.trim() ? JSON.parse(text) : (tools.length > 1 ? tools.map(() => ({})) : {});
} catch (e) {
  console.error(`arguments are not JSON: ${e.message}`);
  process.exit(2);
}
if (tools.length > 1 && (!Array.isArray(args) || args.length !== tools.length)) {
  console.error(`expected a JSON array of ${tools.length} argument objects, one per tool`);
  process.exit(2);
}

const serverJs = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', 'dist', 'server.js');
const client = new Client({ name: 'tpscli-mcp-call', version: '0' });
const show = r => r.structuredContent ? JSON.stringify(r.structuredContent, null, 2) : r.content.map(c => c.text).join('\n');
try {
  // env is passed explicitly: the SDK's default is a short allowlist that drops TPSCLI_OWNER and TPSCLI_EXE.
  await client.connect(new StdioClientTransport({ command: process.execPath, args: [serverJs, ...serverArgs], env: { ...process.env }, stderr: 'inherit' }));
  const results = [];
  for (const [i, name] of tools.entries()) results.push(await client.callTool({ name, arguments: tools.length > 1 ? args[i] : args }));
  if (tools.length === 1) console.log(show(results[0]));
  else console.log(JSON.stringify(results.map(r => r.structuredContent ?? r.content.map(c => c.text).join('\n')), null, 2));
  await client.close();
  process.exit(results.some(r => r.isError) ? 1 : 0);
} catch (e) {
  console.error(e.message);
  process.exit(2);
}
