/**
 * Thin wrapper around `@opentui/core` so the rest of the TUI is decoupled
 * from the rendering library. We render text frames into a model first,
 * then ask the adapter to paint them. The model is plain data, which makes
 * it trivial to assert in tests without instantiating a real terminal.
 */

import type { Severity } from "../api/types.ts";

export interface CellSpan {
  text: string;
  fg?: string;
  bg?: string;
  bold?: boolean;
  dim?: boolean;
  underline?: boolean;
}

export interface Frame {
  width: number;
  height: number;
  rows: CellSpan[][];
  /** Footer hint shown beneath the main content. */
  footer?: string;
  /** Modal text that overlays the frame. */
  modal?: string | null;
}

export interface RenderAdapter {
  start(): Promise<void>;
  paint(frame: Frame): void;
  resize(width: number, height: number): void;
  on(event: "key", listener: (key: KeyEvent) => void): void;
  on(event: "resize", listener: (size: { width: number; height: number }) => void): void;
  stop(): Promise<void>;
  size(): { width: number; height: number };
}

export interface KeyEvent {
  name: string;
  ctrl: boolean;
  shift: boolean;
  meta: boolean;
  raw: string;
}

export interface SeverityTheme {
  fg: string;
  bg?: string;
  bold?: boolean;
}

export interface Theme {
  background: string;
  foreground: string;
  muted: string;
  primary: string;
  success: string;
  warning: string;
  danger: string;
  info: string;
  badgeFg: string;
  state: Record<string, SeverityTheme>;
  severity: Record<Severity, SeverityTheme>;
}

export const DEFAULT_THEME: Theme = {
  background: "",
  foreground: "#e8eef9",
  muted: "#7d8aa3",
  primary: "#5fa8ff",
  success: "#54d28a",
  warning: "#ffc36b",
  danger: "#ff7b7b",
  info: "#9ec3ff",
  badgeFg: "#0a0e16",
  state: {
    running: { fg: "#9ec3ff", bold: true },
    retrying: { fg: "#ffc36b", bold: true },
    review: { fg: "#ffd866", bold: true },
    failed: { fg: "#ff7b7b", bold: true },
    blocked: { fg: "#a8aab2", bold: true },
    done: { fg: "#54d28a", bold: true },
    closed: { fg: "#7d8aa3" },
    open: { fg: "#e8eef9" },
    paused: { fg: "#ffc36b", bold: true },
  },
  severity: {
    debug: { fg: "#7d8aa3" },
    info: { fg: "#9ec3ff" },
    warning: { fg: "#ffc36b", bold: true },
    error: { fg: "#ff7b7b", bold: true },
  },
};

export const NO_COLOR_THEME: Theme = {
  background: "",
  foreground: "",
  muted: "",
  primary: "",
  success: "",
  warning: "",
  danger: "",
  info: "",
  badgeFg: "",
  state: Object.fromEntries(
    Object.entries(DEFAULT_THEME.state).map(([k, _]) => [k, { fg: "", bold: false }]),
  ) as Theme["state"],
  severity: Object.fromEntries(
    Object.entries(DEFAULT_THEME.severity).map(([k, _]) => [k, { fg: "" }]),
  ) as Theme["severity"],
};

/** Builds a frame from a list of rows of spans. Pads to width and truncates. */
export function buildFrame(rows: CellSpan[][], width: number, height: number, options: { footer?: string; modal?: string | null } = {}): Frame {
  const padded = rows.slice(0, height).map((row) => trimRow(row, width));
  while (padded.length < height) padded.push([]);
  return { width, height, rows: padded, footer: options.footer, modal: options.modal ?? null };
}

function trimRow(row: CellSpan[], width: number): CellSpan[] {
  let used = 0;
  const out: CellSpan[] = [];
  for (const span of row) {
    const remaining = width - used;
    if (remaining <= 0) break;
    if (span.text.length <= remaining) {
      out.push(span);
      used += span.text.length;
    } else {
      out.push({ ...span, text: span.text.slice(0, remaining) });
      used = width;
      break;
    }
  }
  return out;
}

export function spansToText(spans: CellSpan[]): string {
  return spans.map((s) => s.text).join("");
}
