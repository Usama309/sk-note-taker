/**
 * Case-insensitive full-text search across a meeting's title, notes,
 * transcript, and summary. Produces a snippet centered on the first hit.
 */

export type SearchField = "title" | "notes" | "transcript" | "summary";

export interface SearchHit {
  field: SearchField;
  snippet: string;
}

const SNIPPET_RADIUS = 60;

/** Collapse whitespace so snippets read cleanly on one line. */
function normalizeWhitespace(text: string): string {
  return text.replace(/\s+/g, " ").trim();
}

/**
 * Build a snippet around the first case-insensitive occurrence of `query`.
 * Returns undefined when the query does not appear in `text`.
 */
export function snippetFor(
  text: string,
  query: string
): string | undefined {
  if (!text || !query) {
    return undefined;
  }
  const haystack = text.toLowerCase();
  const needle = query.toLowerCase();
  const idx = haystack.indexOf(needle);
  if (idx === -1) {
    return undefined;
  }
  const start = Math.max(0, idx - SNIPPET_RADIUS);
  const end = Math.min(text.length, idx + query.length + SNIPPET_RADIUS);
  let snippet = normalizeWhitespace(text.slice(start, end));
  if (start > 0) {
    snippet = `…${snippet}`;
  }
  if (end < text.length) {
    snippet = `${snippet}…`;
  }
  return snippet;
}

/** Return the first matching field/snippet across the provided sources. */
export function findFirstHit(
  query: string,
  sources: Array<{ field: SearchField; text: string | undefined }>
): SearchHit | undefined {
  for (const src of sources) {
    if (!src.text) {
      continue;
    }
    const snippet = snippetFor(src.text, query);
    if (snippet) {
      return { field: src.field, snippet };
    }
  }
  return undefined;
}
