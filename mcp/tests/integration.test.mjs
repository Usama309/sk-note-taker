/**
 * Integration test for the sk-note-taker MCP server (Supabase-backed).
 *
 * Seeds the LIVE Supabase project with a small, disposable dataset (all titles
 * prefixed "__mcptest__<runId>__" so it can never collide with real rows),
 * spawns the built server (dist/server.js) over stdio, exercises every tool via
 * the MCP Client, asserts on the results, then DELETEs exactly the rows it
 * created. Run via `npm test` (which builds first).
 *
 * Credentials come from supabase/config.json (env SUPABASE_URL /
 * SUPABASE_ANON_KEY override), the same resolution the server uses.
 */
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { createClient } from "@supabase/supabase-js";
import { fileURLToPath } from "node:url";
import { readFileSync } from "node:fs";
import path from "node:path";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";

const here = path.dirname(fileURLToPath(import.meta.url));
const projectRoot = path.resolve(here, "..");
const serverPath = path.join(projectRoot, "dist", "server.js");
const configPath = path.resolve(projectRoot, "..", "supabase", "config.json");

// --- resolve Supabase creds (same precedence as the server) ----------------
function resolveConfig() {
  const envUrl = process.env.SUPABASE_URL?.trim();
  const envKey = process.env.SUPABASE_ANON_KEY?.trim();
  if (envUrl && envKey) return { url: envUrl, anonKey: envKey };
  const cfg = JSON.parse(readFileSync(configPath, "utf8"));
  return { url: envUrl || cfg.url, anonKey: envKey || cfg.anonKey };
}

const { url, anonKey } = resolveConfig();
const admin = createClient(url, anonKey, {
  auth: { persistSession: false, autoRefreshToken: false },
});

const runId = randomUUID().slice(0, 8);
const PREFIX = `__mcptest__${runId}__`;
const title = (name) => `${PREFIX}${name}`;

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

function payload(result) {
  if (result.structuredContent) return result.structuredContent;
  const textItem = result.content?.find((c) => c.type === "text");
  assert.ok(textItem, "tool result has text content");
  return JSON.parse(textItem.text);
}

// --- ids for the seeded rows ------------------------------------------------
const clientFolderId = randomUUID(); // "Patriot Holdings"
const projFolderId = randomUUID(); // "Website Redesign" (child)
const internalFolderId = randomUUID(); // "Internal" (has a meeting, no children)
const alphaId = randomUUID();
const betaId = randomUUID();
const gammaId = randomUUID();

// Timestamps chosen so alpha < beta < gamma and the "since" cutoff (2026-07-11)
// excludes only alpha (matches the original fixture behavior).
const T_ALPHA = "2026-07-10T10:00:00Z";
const T_BETA = "2026-07-11T10:00:00Z";
const T_GAMMA = "2026-07-12T10:00:00Z";

async function seed() {
  // Folders: Patriot Holdings > Website Redesign ; Internal.
  let r = await admin.from("folders").insert([
    { id: clientFolderId, name: title("Patriot Holdings"), kind: "client", parent_id: null },
    { id: projFolderId, name: title("Website Redesign"), kind: "project", parent_id: clientFolderId },
    { id: internalFolderId, name: title("Internal"), kind: "client", parent_id: null },
  ]);
  if (r.error) throw new Error(`seed folders: ${r.error.message}`);

  // Meetings.
  r = await admin.from("meetings").insert([
    {
      id: alphaId,
      title: title("Weekly sync with Kainat"),
      created_at: T_ALPHA,
      folder_id: projFolderId,
      state: "complete",
      speakers: {
        S1: { label: "Speaker 1", name: "Kainat", source: "system" },
        S2: { label: "Speaker 2", name: "Saqib", source: "mic" },
      },
      has_recording: true,
      duration_sec: 2530,
      notes: "Reviewed launch checklist. Talked about the revised proposal.",
    },
    {
      id: betaId,
      title: title("Engineering Standup"),
      created_at: T_BETA,
      folder_id: internalFolderId,
      state: "complete",
      speakers: {
        // S1 has a name; S2 has only a label; S3 is absent from the map entirely.
        S1: { label: "Speaker 1", name: "Alex", source: "mic" },
        S2: { label: "Speaker 2", source: "system" },
      },
      has_recording: false,
      duration_sec: 600,
      notes: "Discussed the xyzzy migration and a flaky test.",
    },
    {
      id: gammaId,
      title: title("Uncategorized brain dump"),
      created_at: T_GAMMA,
      folder_id: null,
      state: "recording",
      speakers: {},
      has_recording: false,
      duration_sec: 0,
      notes: "",
    },
  ]);
  if (r.error) throw new Error(`seed meetings: ${r.error.message}`);

  // Transcript for alpha (S1=Kainat, S2=Saqib) and beta (S1, S2, S3).
  r = await admin.from("transcript_segments").insert([
    { meeting_id: alphaId, idx: 0, speaker: "S1", source: "system", start_sec: 12, end_sec: 15, text: "Let's review the checklist." },
    { meeting_id: alphaId, idx: 1, speaker: "S2", source: "mic", start_sec: 16, end_sec: 20, text: "I'll send the revised proposal by Friday." },
    { meeting_id: alphaId, idx: 2, speaker: "S1", source: "system", start_sec: 21, end_sec: 24, text: "Great, thanks." },
    { meeting_id: alphaId, idx: 3, speaker: "S2", source: "mic", start_sec: 25, end_sec: 28, text: "Talk Friday." },
    { meeting_id: betaId, idx: 0, speaker: "S1", source: "mic", start_sec: 1, end_sec: 3, text: "Morning everyone." },
    { meeting_id: betaId, idx: 1, speaker: "S2", source: "system", start_sec: 4, end_sec: 6, text: "We hit a flaky test in CI." },
    { meeting_id: betaId, idx: 2, speaker: "S3", source: "mic", start_sec: 7, end_sec: 9, text: "I'll take a look this afternoon." },
  ]);
  if (r.error) throw new Error(`seed transcript: ${r.error.message}`);

  // Summary for alpha only.
  r = await admin.from("summaries").insert([
    {
      meeting_id: alphaId,
      generated_at: "2026-07-10T18:45:00Z",
      body: "# Meeting Summary\n\nThe team reviewed the launch checklist for the Website Redesign. Decided to ship v1 without SSO.",
      action_items: [
        { owner: "Kainat", text: "Send the revised proposal by Friday" },
        { owner: "Saqib", text: "Update the launch checklist in Notion" },
      ],
      decisions: ["Ship v1 without SSO"],
      remember: ["Client prefers weekly Friday check-ins"],
    },
  ]);
  if (r.error) throw new Error(`seed summary: ${r.error.message}`);

  // A chat message for alpha so hasChat is true.
  r = await admin.from("chat_messages").insert([
    { meeting_id: alphaId, role: "user", text: "What did we decide about SSO?" },
  ]);
  if (r.error) throw new Error(`seed chat: ${r.error.message}`);
}

async function cleanup() {
  // Delete children first (FKs are ON DELETE CASCADE from meetings, but be explicit
  // and only touch our prefixed rows). Meetings deletion cascades transcript/summary/chat.
  const meetingIds = [alphaId, betaId, gammaId];
  await admin.from("chat_messages").delete().in("meeting_id", meetingIds);
  await admin.from("summaries").delete().in("meeting_id", meetingIds);
  await admin.from("transcript_segments").delete().in("meeting_id", meetingIds);
  await admin.from("meetings").delete().in("id", meetingIds);
  await admin.from("folders").delete().in("id", [projFolderId, clientFolderId, internalFolderId]);

  // Safety net: purge anything else carrying our prefix (in case an id changed).
  await admin.from("meetings").delete().like("title", `${PREFIX}%`);
  await admin.from("folders").delete().like("name", `${PREFIX}%`);
}

async function main() {
  console.log(`\nSeeding Supabase (${url}) with prefix ${PREFIX} …`);
  await seed();

  const transport = new StdioClientTransport({
    command: process.execPath,
    args: [serverPath],
    env: { ...process.env, SUPABASE_URL: url, SUPABASE_ANON_KEY: anonKey },
    stderr: "inherit",
  });

  const client = new Client({ name: "sknote-mcp-test", version: "0.1.0" });
  await client.connect(transport);

  const call = async (name, args) =>
    payload(await client.callTool({ name, arguments: args ?? {} }));

  try {
    // --- tool discovery ----------------------------------------------------
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

    // Helper: pull only our seeded meetings out of a list result (real rows may exist).
    const mine = (list) => list.meetings.filter((m) => m.title.startsWith(PREFIX));

    // --- list_meetings -----------------------------------------------------
    console.log("\nlist_meetings:");
    const all = await call("list_meetings", {});
    const ours = mine(all);
    check("returns the 3 seeded meetings", () => {
      assert.equal(ours.length, 3);
    });
    check("sorted newest-first by createdAt", () => {
      // Within our seeded set: gamma (newest) … alpha (oldest).
      const ids = ours.map((m) => m.id);
      assert.equal(ids[0], gammaId);
      assert.equal(ids[ids.length - 1], alphaId);
    });
    check("summary shape includes resolved folderPath and speakerNames", () => {
      const alpha = ours.find((m) => m.id === alphaId);
      assert.equal(alpha.title, title("Weekly sync with Kainat"));
      assert.equal(alpha.durationSec, 2530);
      assert.equal(
        alpha.folderPath,
        `${title("Patriot Holdings")} / ${title("Website Redesign")}`
      );
      assert.deepEqual(alpha.speakerNames, ["Kainat", "Saqib"]);
      assert.equal(alpha.hasSummary, true);
    });
    check("meeting without summary reports hasSummary false", () => {
      const beta = ours.find((m) => m.id === betaId);
      assert.equal(beta.hasSummary, false);
    });

    const byFolder = await call("list_meetings", { folderId: projFolderId });
    check("filters by folderId", () => {
      assert.equal(byFolder.count, 1);
      assert.equal(byFolder.meetings[0].id, alphaId);
    });

    const sinceRes = await call("list_meetings", { since: "2026-07-11T00:00:00Z" });
    check("filters by since timestamp", () => {
      const ids = mine(sinceRes)
        .map((m) => m.id)
        .sort();
      assert.deepEqual(ids, [betaId, gammaId].sort());
    });

    const limited = await call("list_meetings", { limit: 1 });
    check("respects limit", () => {
      assert.equal(limited.count, 1);
    });

    // --- get_meeting -------------------------------------------------------
    console.log("\nget_meeting:");
    const alphaMeeting = await call("get_meeting", { id: alphaId });
    check("returns full meeting + notes + artifact flags", () => {
      assert.equal(alphaMeeting.meeting.title, title("Weekly sync with Kainat"));
      assert.ok(alphaMeeting.notes.includes("Reviewed launch checklist"));
      assert.equal(alphaMeeting.hasTranscript, true);
      assert.equal(alphaMeeting.hasSummary, true);
      assert.equal(alphaMeeting.hasChat, true);
      assert.equal(alphaMeeting.hasRecording, true);
      assert.equal(
        alphaMeeting.folderPath,
        `${title("Patriot Holdings")} / ${title("Website Redesign")}`
      );
    });
    const gammaMeeting = await call("get_meeting", { id: gammaId });
    check("reports missing artifacts as false", () => {
      assert.equal(gammaMeeting.hasTranscript, false);
      assert.equal(gammaMeeting.hasSummary, false);
      assert.equal(gammaMeeting.hasChat, false);
      assert.equal(gammaMeeting.folderPath, null);
    });
    const missingMeeting = await call("get_meeting", { id: randomUUID() });
    check("unknown id returns an error, not a crash", () => {
      assert.ok(missingMeeting.error.includes("not found"));
    });

    // --- get_transcript ----------------------------------------------------
    console.log("\nget_transcript:");
    const alphaTx = await call("get_transcript", { id: alphaId });
    check("resolves speaker names by default and renders readable lines", () => {
      assert.equal(alphaTx.resolvedNames, true);
      assert.equal(alphaTx.segmentCount, 4);
      assert.equal(alphaTx.segments[0].speakerName, "Kainat");
      assert.equal(alphaTx.segments[1].speakerName, "Saqib");
      assert.ok(alphaTx.text.includes("[00:12] Kainat:"));
      assert.ok(alphaTx.text.includes("[00:16] Saqib:"));
    });
    const betaTx = await call("get_transcript", { id: betaId });
    check("falls back to 'Speaker N' for keys missing a name/label", () => {
      // S2 has a label only -> "Speaker 2". S3 not in map -> "Speaker 3".
      const s2 = betaTx.segments.find((s) => s.speaker === "S2");
      const s3 = betaTx.segments.find((s) => s.speaker === "S3");
      assert.equal(s2.speakerName, "Speaker 2");
      assert.equal(s3.speakerName, "Speaker 3");
    });
    const rawTx = await call("get_transcript", { id: betaId, resolveNames: false });
    check("resolveNames=false keeps raw speaker keys", () => {
      assert.equal(rawTx.resolvedNames, false);
      assert.equal(rawTx.segments[0].speakerName, "S1");
    });
    const noTx = await call("get_transcript", { id: gammaId });
    check("meeting without a transcript returns empty, not a crash", () => {
      assert.deepEqual(noTx.segments, []);
      assert.ok(noTx.error);
    });

    // --- get_summary -------------------------------------------------------
    console.log("\nget_summary:");
    const summary = await call("get_summary", { id: alphaId });
    check("returns structured summary fields", () => {
      assert.equal(summary.hasSummary, true);
      // Postgres round-trips timestamptz as +00:00 rather than the "Z" we sent;
      // compare by instant, not by literal string.
      assert.equal(Date.parse(summary.generatedAt), Date.parse("2026-07-10T18:45:00Z"));
      assert.equal(summary.actionItems.length, 2);
      assert.deepEqual(summary.actionItems[0], {
        owner: "Kainat",
        text: "Send the revised proposal by Friday",
      });
      assert.deepEqual(summary.decisions, ["Ship v1 without SSO"]);
      assert.deepEqual(summary.remember, ["Client prefers weekly Friday check-ins"]);
    });
    check("returns the markdown body", () => {
      assert.ok(summary.body.startsWith("# Meeting Summary"));
      assert.ok(summary.body.includes("without SSO"));
    });
    const noSummary = await call("get_summary", { id: betaId });
    check("meeting without a summary reports hasSummary false", () => {
      assert.equal(noSummary.hasSummary, false);
      assert.ok(noSummary.error);
    });

    // --- search_meetings ---------------------------------------------------
    console.log("\nsearch_meetings:");
    const searchProposal = await call("search_meetings", { query: "proposal" });
    check("finds a hit and returns a snippet with the term", () => {
      const hit = searchProposal.matches.find((m) => m.id === alphaId);
      assert.ok(hit, "alpha meeting matched 'proposal'");
      assert.ok(hit.snippet.toLowerCase().includes("proposal"));
    });
    const searchUnique = await call("search_meetings", { query: "xyzzy" });
    check("case-insensitive search reaches notes text", () => {
      const hit = searchUnique.matches.find((m) => m.id === betaId);
      assert.ok(hit);
      assert.equal(hit.field, "notes");
    });
    const searchTranscript = await call("search_meetings", { query: "flaky test" });
    check("search reaches transcript text", () => {
      const hit = searchTranscript.matches.find((m) => m.id === betaId);
      assert.ok(hit);
      // notes for beta also contain "flaky test", and notes has higher priority.
      assert.ok(["notes", "transcript"].includes(hit.field));
    });
    const searchTitle = await call("search_meetings", { query: title("Engineering Standup") });
    check("search reaches titles", () => {
      const hit = searchTitle.matches.find((m) => m.id === betaId);
      assert.ok(hit);
      assert.equal(hit.field, "title");
    });
    const searchSSO = await call("search_meetings", { query: "without SSO" });
    check("search reaches summary text", () => {
      const hit = searchSSO.matches.find((m) => m.id === alphaId);
      assert.ok(hit);
      // "without SSO" appears in the summary body only.
      assert.equal(hit.field, "summary");
    });
    const searchNone = await call("search_meetings", { query: `nope-${runId}-zzzz` });
    check("no matches returns an empty list, not a crash", () => {
      assert.equal(searchNone.count, 0);
    });

    // --- list_folders ------------------------------------------------------
    console.log("\nlist_folders:");
    const folders = await call("list_folders", {});
    const myFolders = folders.folders.filter((f) => (f.name ?? "").startsWith(PREFIX));
    check("returns the folder tree with paths and meeting counts", () => {
      assert.equal(myFolders.length, 3);
      const redesign = myFolders.find((f) => f.id === projFolderId);
      assert.equal(
        redesign.path,
        `${title("Patriot Holdings")} / ${title("Website Redesign")}`
      );
      assert.equal(redesign.meetingCount, 1);
      const internal = myFolders.find((f) => f.id === internalFolderId);
      assert.equal(internal.meetingCount, 1);
      const patriot = myFolders.find((f) => f.id === clientFolderId);
      assert.equal(patriot.meetingCount, 0);
    });
    check("reports uncategorized meeting count (>= our 1)", () => {
      assert.ok(folders.uncategorizedMeetings >= 1);
    });
  } finally {
    await client.close();
    console.log("\nCleaning up seeded rows …");
    await cleanup();
  }

  console.log(`\n${passed} passed, ${failed} failed`);
  if (failed > 0) process.exit(1);
}

main().catch(async (err) => {
  console.error("Test harness crashed:", err);
  try {
    await cleanup();
    console.error("(cleanup ran after crash)");
  } catch (e) {
    console.error("cleanup after crash failed:", e.message);
  }
  process.exit(1);
});
