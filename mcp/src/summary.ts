/**
 * Map a Supabase summaries row into the structured shape the MCP get_summary
 * tool returns. Previously this parsed YAML front-matter out of summary.md; the
 * cloud store keeps the same fields as typed columns (action_items/decisions/
 * remember jsonb + body text), so we just normalize them defensively.
 */
import type { SummaryRow } from "./store.js";

export interface ActionItem {
  owner?: string;
  text?: string;
}

export interface MappedSummary {
  generatedAt?: string;
  actionItems: ActionItem[];
  decisions: string[];
  remember: string[];
  body: string;
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

export function mapSummary(row: SummaryRow): MappedSummary {
  return {
    generatedAt: row.generated_at ?? undefined,
    actionItems: toActionItems(row.action_items),
    decisions: toStringList(row.decisions),
    remember: toStringList(row.remember),
    body: (row.body ?? "").trim(),
  };
}
