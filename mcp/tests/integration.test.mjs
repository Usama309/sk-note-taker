/**
 * Integration test for the sk-note-taker MCP server.
 *
 * Spawns the built server (dist/server.js) over stdio with SKNOTE_DATA_DIR
 * pointed at tests/fixtures, then exercises every registered tool and asserts
 * on the results. Run via `npm test` (which builds first).
 */
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { fileURLToPath } from "node:url";
import path from "node:path";
import assert from "node:assert/strict";

const here = path.dirname(fileURLToPath(import.meta.url));
const projectRoot = path.resolve(here, "..");
const serverPath = path.join(projectRoot, "dist", "server.js");
const fixturesDir = path.join(here, "fixtures");

let passed = 0;
let failed = 0;

function check(name, fn) {
  try {
    fn();
    passed += 1;
    console.log(`  ✓ ${name}`);
  } catch (err) {
    failed += 1;
    console.error(`  ✗ ${name}`);
    console.error(`      ${err.message}`);
  }
}

/** Parse the structured JSON payload from a tool result. */
function payload(result) {
  if (result.structuredContent) {
    return result.structuredContent;
  }
  const textItem = result.content?.find((c) => c.type === "text");
  assert.ok(textItem, "tool result has text content");
  return JSON.parse(textItem.text);
}

async function main() {
  const transport = new StdioClientTransport({
    command: process.execPath,
    args: [serverPath],
    env: { ...process.env, SKNOTE_DATA_DIR: fixturesDir },
    stderr: "inherit",
  });

  const client = new Client({ name: "sknote-mcp-test", version: "0.1.0" });
  await client.connect(transport);

  // --- tool discovery ------------------------------------------------------
  const { tools } = await client.listTools();
  const toolNames = tools.map((t) => t.name).sort();
  console.log("\nDiscovered tools:", toolNames.join(", "));
  check("all six tools are registered", () => {
    assert.deepEqual(toolNames, [
      "get_meeting",
      "get_summary",
      "get_transcript",
      "list_folders",
      "list_meetings",
      "search_meetings",
    ]);
  });

  const call = async (name, args) =>
    payload(await client.callTool({ name, arguments: args ?? {} }));

  // --- list_meetings -------------------------------------------------------
  console.log("\nlist_meetings:");
  const all = await call("list_meetings", {});
  check("returns the 3 well-formed meetings (broken one skipped)", () => {
    assert.equal(all.count, 3);
    assert.equal(all.meetings.length, 3);
  });
  check("sorted newest-first by createdAt", () => {
    assert.equal(all.meetings[0].id, "m-0003-gamma");
    assert.equal(all.meetings[2].id, "m-0001-alpha");
  });
  check("summary shape includes resolved folderPath and speakerNames", () => {
    const alpha = all.meetings.find((m) => m.id === "m-0001-alpha");
    assert.equal(alpha.title, "Weekly sync with Kainat");
    assert.equal(alpha.durationSec, 2530);
    assert.equal(alpha.folderPath, "Patriot Holdings / Website Redesign");
    assert.deepEqual(alpha.speakerNames, ["Saqib", "Kainat"]);
    assert.equal(alpha.hasSummary, true);
  });
  check("meeting without summary reports hasSummary false", () => {
    const beta = all.meetings.find((m) => m.id === "m-0002-beta");
    assert.equal(beta.hasSummary, false);
  });

  const byFolder = await call("list_meetings", { folderId: "f-proj-redesign" });
  check("filters by folderId", () => {
    assert.equal(byFolder.count, 1);
    assert.equal(byFolder.meetings[0].id, "m-0001-alpha");
  });

  const limited = await call("list_meetings", { limit: 1 });
  check("respects limit", () => {
    assert.equal(limited.count, 1);
  });

  const sinceRes = await call("list_meetings", {
    since: "2026-07-11T00:00:00Z",
  });
  check("filters by since timestamp", () => {
    assert.equal(sinceRes.count, 2);
    const ids = sinceRes.meetings.map((m) => m.id).sort();
    assert.deepEqual(ids, ["m-0002-beta", "m-0003-gamma"]);
  });

  // --- get_meeting ---------------------------------------------------------
  console.log("\nget_meeting:");
  const alphaMeeting = await call("get_meeting", { id: "m-0001-alpha" });
  check("returns full meeting.json + notes + artifact flags", () => {
    assert.equal(alphaMeeting.meeting.title, "Weekly sync with Kainat");
    assert.ok(alphaMeeting.notes.includes("Reviewed launch checklist"));
    assert.equal(alphaMeeting.hasTranscript, true);
    assert.equal(alphaMeeting.hasSummary, true);
    assert.equal(alphaMeeting.hasChat, true);
    assert.equal(alphaMeeting.folderPath, "Patriot Holdings / Website Redesign");
  });
  const gammaMeeting = await call("get_meeting", { id: "m-0003-gamma" });
  check("reports missing artifacts as false", () => {
    assert.equal(gammaMeeting.hasTranscript, false);
    assert.equal(gammaMeeting.hasSummary, false);
    assert.equal(gammaMeeting.hasChat, false);
    assert.equal(gammaMeeting.folderPath, null);
  });
  const missingMeeting = await call("get_meeting", { id: "does-not-exist" });
  check("unknown id returns an error, not a crash", () => {
    assert.ok(missingMeeting.error.includes("not found"));
  });

  // --- get_transcript ------------------------------------------------------
  console.log("\nget_transcript:");
  const alphaTx = await call("get_transcript", { id: "m-0001-alpha" });
  check("resolves speaker names by default and renders readable lines", () => {
    assert.equal(alphaTx.resolvedNames, true);
    assert.equal(alphaTx.segmentCount, 4);
    assert.equal(alphaTx.segments[0].speakerName, "Kainat");
    assert.equal(alphaTx.segments[1].speakerName, "Saqib");
    assert.ok(alphaTx.text.includes("[00:12] Kainat:"));
    assert.ok(alphaTx.text.includes("[00:16] Saqib:"));
  });
  const betaTx = await call("get_transcript", { id: "m-0002-beta" });
  check("falls back to 'Speaker N' for keys missing a name/label", () => {
    // S2 has a label but no name -> label. S3 not in map -> "Speaker 3".
    const s2 = betaTx.segments.find((s) => s.speaker === "S2");
    const s3 = betaTx.segments.find((s) => s.speaker === "S3");
    assert.equal(s2.speakerName, "Speaker 2");
    assert.equal(s3.speakerName, "Speaker 3");
  });
  const rawTx = await call("get_transcript", {
    id: "m-0002-beta",
    resolveNames: false,
  });
  check("resolveNames=false keeps raw speaker keys", () => {
    assert.equal(rawTx.resolvedNames, false);
    assert.equal(rawTx.segments[0].speakerName, "S1");
  });
  const noTx = await call("get_transcript", { id: "m-0003-gamma" });
  check("meeting without a transcript returns empty, not a crash", () => {
    assert.deepEqual(noTx.segments, []);
    assert.ok(noTx.error);
  });

  // --- get_summary ---------------------------------------------------------
  console.log("\nget_summary:");
  const summary = await call("get_summary", { id: "m-0001-alpha" });
  check("parses YAML front-matter into structured fields", () => {
    assert.equal(summary.hasFrontMatter, true);
    assert.equal(summary.generatedAt, "2026-07-10T18:45:00Z");
    assert.equal(summary.actionItems.length, 2);
    assert.deepEqual(summary.actionItems[0], {
      owner: "Kainat",
      text: "Send the revised proposal by Friday",
    });
    assert.deepEqual(summary.decisions, ["Ship v1 without SSO"]);
    assert.deepEqual(summary.remember, [
      "Client prefers weekly Friday check-ins",
    ]);
  });
  check("returns the markdown body after the front-matter", () => {
    assert.ok(summary.body.startsWith("# Meeting Summary"));
    assert.ok(summary.body.includes("without SSO"));
  });
  const noSummary = await call("get_summary", { id: "m-0002-beta" });
  check("meeting without a summary reports hasSummary false", () => {
    assert.equal(noSummary.hasSummary, false);
    assert.ok(noSummary.error);
  });

  // --- search_meetings -----------------------------------------------------
  console.log("\nsearch_meetings:");
  const searchProposal = await call("search_meetings", { query: "proposal" });
  check("finds a hit and returns a snippet with the term", () => {
    assert.ok(searchProposal.count >= 1);
    const hit = searchProposal.matches.find((m) => m.id === "m-0001-alpha");
    assert.ok(hit, "alpha meeting matched 'proposal'");
    assert.ok(hit.snippet.toLowerCase().includes("proposal"));
  });
  const searchUnique = await call("search_meetings", {
    query: "xyzzy",
  });
  check("case-insensitive search reaches notes text", () => {
    assert.equal(searchUnique.count, 1);
    assert.equal(searchUnique.matches[0].id, "m-0002-beta");
    assert.equal(searchUnique.matches[0].field, "notes");
  });
  const searchTranscript = await call("search_meetings", {
    query: "flaky test",
  });
  check("search reaches transcript text", () => {
    const hit = searchTranscript.matches.find((m) => m.id === "m-0002-beta");
    assert.ok(hit);
    assert.equal(hit.field, "transcript");
  });
  const searchTitle = await call("search_meetings", { query: "Standup" });
  check("search reaches titles", () => {
    const hit = searchTitle.matches.find((m) => m.id === "m-0002-beta");
    assert.ok(hit);
    assert.equal(hit.field, "title");
  });
  const searchNone = await call("search_meetings", {
    query: "nonexistent-term-zzzz",
  });
  check("no matches returns an empty list, not a crash", () => {
    assert.equal(searchNone.count, 0);
  });
  const searchLimited = await call("search_meetings", {
    query: "the",
    limit: 1,
  });
  check("respects search limit", () => {
    assert.ok(searchLimited.count <= 1);
  });

  // --- list_folders --------------------------------------------------------
  console.log("\nlist_folders:");
  const folders = await call("list_folders", {});
  check("returns the folder tree with paths and meeting counts", () => {
    assert.equal(folders.count, 3);
    const redesign = folders.folders.find((f) => f.id === "f-proj-redesign");
    assert.equal(redesign.path, "Patriot Holdings / Website Redesign");
    assert.equal(redesign.meetingCount, 1);
    const internal = folders.folders.find((f) => f.id === "f-client-internal");
    assert.equal(internal.meetingCount, 1);
    const patriot = folders.folders.find((f) => f.id === "f-client-patriot");
    assert.equal(patriot.meetingCount, 0);
  });
  check("reports uncategorized meeting count", () => {
    assert.equal(folders.uncategorizedMeetings, 1);
  });

  await client.close();

  console.log(`\n${passed} passed, ${failed} failed`);
  if (failed > 0) {
    process.exit(1);
  }
}

main().catch((err) => {
  console.error("Test harness crashed:", err);
  process.exit(1);
});
