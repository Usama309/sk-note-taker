// Cross-component interop check: the MCP server reading REAL data produced by the Swift
// pipeline (SKNOTE_PIPELINE_OUT=/tmp/sknote-interop from the app's integration test).
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";

const transport = new StdioClientTransport({
  command: "node",
  args: ["dist/server.js"],
  env: { ...process.env, SKNOTE_DATA_DIR: "/tmp/sknote-interop" },
});
const client = new Client({ name: "interop-test", version: "1.0.0" });
await client.connect(transport);

const payload = JSON.parse((await client.callTool({ name: "list_meetings", arguments: {} })).content[0].text);
const meetings = payload.meetings ?? payload;
console.log("meetings:", meetings.length, "-", meetings[0]?.title,
            "duration:", meetings[0]?.durationSec);
if (meetings.length !== 1) { console.error("FAIL: expected 1 meeting"); process.exit(1); }
if (!(meetings[0].durationSec > 15)) { console.error("FAIL: durationSec missing/zero"); process.exit(1); }

const id = meetings[0].id;
const transcript = (await client.callTool({ name: "get_transcript", arguments: { id } })).content[0].text;
console.log("transcript preview:", transcript.slice(0, 200).replace(/\n/g, " | "));
if (!/Kainat:/.test(transcript)) { console.error("FAIL: renamed speaker missing"); process.exit(1); }

const searchPayload = JSON.parse((await client.callTool({ name: "search_meetings", arguments: { query: "checklist" } })).content[0].text);
const results = searchPayload.results ?? searchPayload.matches ?? searchPayload;
if (!results.length) { console.error("FAIL: search found nothing"); process.exit(1); }
console.log("search hit:", JSON.stringify(results[0]).slice(0, 120));

await client.close();
console.log("INTEROP MCP: ALL OK");
