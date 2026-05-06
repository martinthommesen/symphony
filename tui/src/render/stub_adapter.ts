/**
 * Headless adapter used by tests and the smoke runner. Records every painted
 * frame so assertions can compare them. Never imports `@opentui/core`.
 */

import type { Frame, KeyEvent, RenderAdapter } from "./adapter.ts";

export class StubAdapter implements RenderAdapter {
  public frames: Frame[] = [];
  private listeners: { key: ((k: KeyEvent) => void)[]; resize: ((s: { width: number; height: number }) => void)[] } =
    { key: [], resize: [] };
  private currentSize: { width: number; height: number };
  private started = false;

  constructor(width = 100, height = 30) {
    this.currentSize = { width, height };
  }

  async start(): Promise<void> {
    this.started = true;
  }

  paint(frame: Frame): void {
    if (!this.started) return;
    this.frames.push(frame);
  }

  resize(width: number, height: number): void {
    this.currentSize = { width, height };
    for (const l of this.listeners.resize) l({ width, height });
  }

  on(event: "key", listener: (k: KeyEvent) => void): void;
  on(event: "resize", listener: (s: { width: number; height: number }) => void): void;
  on(event: string, listener: any): void {
    if (event === "key" || event === "resize") {
      this.listeners[event].push(listener);
    }
  }

  pressKey(key: Partial<KeyEvent> & { name: string }): void {
    const event: KeyEvent = {
      name: key.name,
      ctrl: !!key.ctrl,
      shift: !!key.shift,
      meta: !!key.meta,
      raw: key.raw ?? key.name,
    };
    for (const l of this.listeners.key) l(event);
  }

  async stop(): Promise<void> {
    this.started = false;
  }

  size(): { width: number; height: number } {
    return this.currentSize;
  }

  lastFrame(): Frame | null {
    return this.frames[this.frames.length - 1] ?? null;
  }

  flatten(frame: Frame = this.lastFrame() ?? { width: 0, height: 0, rows: [] }): string {
    return frame.rows.map((row) => row.map((s) => s.text).join("")).join("\n");
  }
}
