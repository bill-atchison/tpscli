// One MCP tool call from the command line, for the test instrument and for support staff.
//
//   '<json arguments>' | node tools\call.js <tool> [server flags...]
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
  console.error("usage: '<json arguments>' | node tools\\call.js <tool> [server flags...]");
  process.exit(2);
}

let text = '';
if (!process.stdin.isTTY) for await (const chunk of process.stdin) text += chunk;
let args;
try {
  args = text.trim() ? JSON.parse(text) : {};
} catch (e) {
  console.error(`arguments are not JSON: ${e.message}`);
  process.exit(2);
}

const serverJs = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', 'dist', 'server.js');
const client = new Client({ name: 'tpscli-mcp-call', version: '0' });
try {
  // env is passed explicitly: the SDK's default is a short allowlist that drops TPSCLI_OWNER and TPSCLI_EXE.
  await client.connect(new StdioClientTransport({ command: process.execPath, args: [serverJs, ...serverArgs], env: { ...process.env }, stderr: 'inherit' }));
  const r = await client.callTool({ name: tool, arguments: args });
  console.log(r.structuredContent ? JSON.stringify(r.structuredContent, null, 2) : r.content.map(c => c.text).join('\n'));
  await client.close();
  process.exit(r.isError ? 1 : 0);
} catch (e) {
  console.error(e.message);
  process.exit(2);
}
