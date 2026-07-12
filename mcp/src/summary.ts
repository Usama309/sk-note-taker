/**
 * Minimal YAML front-matter parser for summary.md.
 *
 * summary.md begins with a `---` fenced YAML block holding actionItems,
 * decisions, and remember (see DATA-MODEL.md). We intentionally parse only the
 * narrow subset of YAML the app emits — scalars, `key: value` maps, and `-`
 * lists (including lists of single-line maps) — to avoid pulling in a YAML dep.
 */

export interface ActionItem {
  owner?: string;
  text?: string;
}

export interface ParsedSummary {
  /** Structured fields lifted from front-matter. */
  frontMatter: {
    generatedAt?: string;
    actionItems: ActionItem[];
    decisions: string[];
    remember: string[];
    /** Any other scalar front-matter keys, preserved verbatim. */
    extra: Record<string, string>;
  };
  /** The markdown body after the front-matter fence. */
  body: string;
  /** True when a front-matter fence was present and parsed. */
  hasFrontMatter: boolean;
}

/** Split a summary.md into its raw front-matter text and body. */
function splitFrontMatter(
  content: string
): { yaml: string | null; body: string } {
  // Front-matter must be the very first thing in the file: `---\n ... \n---`.
  const normalized = content.replace(/^﻿/, "");
  const match = /^---\r?\n([\s\S]*?)\r?\n---\r?\n?/.exec(normalized);
  if (!match) {
    return { yaml: null, body: normalized };
  }
  return { yaml: match[1], body: normalized.slice(match[0].length) };
}

function stripQuotes(value: string): string {
  const trimmed = value.trim();
  if (
    (trimmed.startsWith('"') && trimmed.endsWith('"')) ||
    (trimmed.startsWith("'") && trimmed.endsWith("'"))
  ) {
    return trimmed.slice(1, -1);
  }
  return trimmed;
}

function indentOf(line: string): number {
  const m = /^(\s*)/.exec(line);
  return m ? m[1].length : 0;
}

/**
 * Parse the tiny YAML subset. Returns a structured object keyed by top-level
 * name; list items are either strings or single-line `key: value` maps.
 */
function parseYaml(yaml: string): Record<string, unknown> {
  const lines = yaml.split(/\r?\n/).filter((l) => l.trim().length > 0);
  const result: Record<string, unknown> = {};
  let i = 0;

  while (i < lines.length) {
    const line = lines[i];
    const baseIndent = indentOf(line);
    const keyMatch = /^(\s*)([^:\s][^:]*):\s*(.*)$/.exec(line);
    if (!keyMatch) {
      i += 1;
      continue;
    }
    const key = keyMatch[2].trim();
    const inlineValue = keyMatch[3];

    if (inlineValue.trim().length > 0) {
      // Scalar value on the same line.
      result[key] = stripQuotes(inlineValue);
      i += 1;
      continue;
    }

    // Value is a nested block: collect deeper-indented lines.
    const items: unknown[] = [];
    i += 1;
    while (i < lines.length && indentOf(lines[i]) > baseIndent) {
      const child = lines[i];
      const listMatch = /^(\s*)-\s*(.*)$/.exec(child);
      if (listMatch) {
        const itemBody = listMatch[2];
        const listItemIndent = indentOf(child);
        // Inline `- key: value` on the dash line.
        const inlineMap = /^([^:\s][^:]*):\s*(.*)$/.exec(itemBody);
        if (inlineMap && inlineMap[2].trim().length > 0) {
          const obj: Record<string, string> = {
            [inlineMap[1].trim()]: stripQuotes(inlineMap[2]),
          };
          // Absorb following deeper-indented `key: value` lines into this map.
          i += 1;
          while (
            i < lines.length &&
            indentOf(lines[i]) > listItemIndent &&
            !/^\s*-/.test(lines[i])
          ) {
            const kv = /^\s*([^:\s][^:]*):\s*(.*)$/.exec(lines[i]);
            if (kv) {
              obj[kv[1].trim()] = stripQuotes(kv[2]);
            }
            i += 1;
          }
          items.push(obj);
        } else {
          items.push(stripQuotes(itemBody));
          i += 1;
        }
      } else {
        // Unexpected shape; skip to avoid an infinite loop.
        i += 1;
      }
    }
    result[key] = items;
  }

  return result;
}

function toStringList(value: unknown): string[] {
  if (!Array.isArray(value)) {
    return [];
  }
  return value
    .map((v) => (typeof v === "string" ? v : undefined))
    .filter((v): v is string => v !== undefined);
}

function toActionItems(value: unknown): ActionItem[] {
  if (!Array.isArray(value)) {
    return [];
  }
  const items: ActionItem[] = [];
  for (const v of value) {
    if (typeof v === "string") {
      items.push({ text: v });
    } else if (v && typeof v === "object") {
      const rec = v as Record<string, unknown>;
      items.push({
        owner: typeof rec.owner === "string" ? rec.owner : undefined,
        text: typeof rec.text === "string" ? rec.text : undefined,
      });
    }
  }
  return items;
}

export function parseSummary(content: string): ParsedSummary {
  const { yaml, body } = splitFrontMatter(content);
  if (yaml === null) {
    return {
      frontMatter: {
        actionItems: [],
        decisions: [],
        remember: [],
        extra: {},
      },
      body: body.trim(),
      hasFrontMatter: false,
    };
  }

  const parsed = parseYaml(yaml);
  const extra: Record<string, string> = {};
  const known = new Set([
    "generatedAt",
    "actionItems",
    "decisions",
    "remember",
  ]);
  for (const [k, v] of Object.entries(parsed)) {
    if (!known.has(k) && typeof v === "string") {
      extra[k] = v;
    }
  }

  return {
    frontMatter: {
      generatedAt:
        typeof parsed.generatedAt === "string" ? parsed.generatedAt : undefined,
      actionItems: toActionItems(parsed.actionItems),
      decisions: toStringList(parsed.decisions),
      remember: toStringList(parsed.remember),
      extra,
    },
    body: body.trim(),
    hasFrontMatter: true,
  };
}
