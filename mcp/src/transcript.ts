/**
 * Transcript helpers: render diarized segments into readable lines and expose a
 * structured shape with optional speaker-name resolution.
 */
import type { Speaker, TranscriptSegment } from "./store.js";
import { resolveSpeakerName } from "./store.js";

export interface RenderedSegment {
  id?: number;
  speaker?: string;
  speakerName: string;
  start?: number;
  end?: number;
  text: string;
}

/** Format seconds as MM:SS (or HH:MM:SS when an hour or longer). */
export function formatTimestamp(seconds: number | undefined): string {
  if (seconds === undefined || !Number.isFinite(seconds) || seconds < 0) {
    return "00:00";
  }
  const total = Math.floor(seconds);
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s = total % 60;
  const pad = (n: number) => String(n).padStart(2, "0");
  return h > 0 ? `${pad(h)}:${pad(m)}:${pad(s)}` : `${pad(m)}:${pad(s)}`;
}

export function renderSegments(
  segments: TranscriptSegment[],
  speakers: Record<string, Speaker> | undefined,
  resolveNames: boolean
): RenderedSegment[] {
  return segments.map((seg) => {
    const speakerName = resolveNames
      ? resolveSpeakerName(speakers, seg.speaker)
      : seg.speaker ?? "Unknown";
    return {
      id: seg.id,
      speaker: seg.speaker,
      speakerName,
      start: seg.start,
      end: seg.end,
      text: seg.text ?? "",
    };
  });
}

/** Render "[MM:SS] Name: text" transcript lines. */
export function renderTranscriptText(segments: RenderedSegment[]): string {
  return segments
    .map((seg) => `[${formatTimestamp(seg.start)}] ${seg.speakerName}: ${seg.text}`)
    .join("\n");
}
