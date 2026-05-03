/**
 * OpenTUI-backed render adapter. We use the imperative core API
 * (`createCliRenderer` + `BoxRenderable`/`TextRenderable`) rather than the
 * React reconciler so we control the redraw pacing precisely.
 *
 * NOTE: this module imports `@opentui/core` lazily inside `start()` so the
 * test bundle does not pull in Bun-FFI at import time. Tests use
 * `StubAdapter` instead.
 */

import type { Frame, KeyEvent, RenderAdapter } from "./adapter.ts";

type Listener<E> = (event: E) => void;

export class OpenTuiAdapter implements RenderAdapter {
  private renderer: any = null;
  private rootBox: any = null;
  private contentBox: any = null;
  private footerText: any = null;
  private modalBox: any = null;
  private modalText: any = null;
  private currentSize = { width: 80, height: 24 };
  private keyListeners: Listener<KeyEvent>[] = [];
  private resizeListeners: Listener<{ width: number; height: number }>[] = [];
  private OpenTui: any;

  async start(): Promise<void> {
    // Lazy import so the test bundle stays Bun-FFI-free.
    this.OpenTui = await import("@opentui/core");

    this.renderer = await this.OpenTui.createCliRenderer({
      targetFps: 30,
      useAlternateScreen: true,
      consoleMode: "console-overlay",
    });

    const { BoxRenderable, TextRenderable } = this.OpenTui;

    this.rootBox = new BoxRenderable(this.renderer, {
      id: "symphony-root",
      flexGrow: 1,
      flexDirection: "column",
    });

    this.contentBox = new BoxRenderable(this.renderer, {
      id: "symphony-content",
      flexGrow: 1,
      flexDirection: "column",
    });

    this.footerText = new TextRenderable(this.renderer, {
      id: "symphony-footer",
      content: "",
    });

    this.modalBox = new BoxRenderable(this.renderer, {
      id: "symphony-modal",
      visible: false,
      borderStyle: "single",
      padding: 1,
    });

    this.modalText = new TextRenderable(this.renderer, {
      id: "symphony-modal-text",
      content: "",
    });

    this.modalBox.add(this.modalText);
    this.rootBox.add(this.contentBox);
    this.rootBox.add(this.footerText);
    this.rootBox.add(this.modalBox);
    this.renderer.root.add(this.rootBox);

    this.currentSize = {
      width: this.renderer.terminalWidth ?? 80,
      height: this.renderer.terminalHeight ?? 24,
    };

    this.renderer.on?.("resize", (size: any) => {
      const next = {
        width: size?.width ?? this.renderer.terminalWidth ?? 80,
        height: size?.height ?? this.renderer.terminalHeight ?? 24,
      };
      this.currentSize = next;
      for (const l of this.resizeListeners) l(next);
    });

    this.renderer.keyInput?.on?.("keypress", (key: any) => {
      const ev: KeyEvent = {
        name: key?.name ?? key?.raw ?? "",
        ctrl: !!key?.ctrl,
        shift: !!key?.shift,
        meta: !!key?.meta,
        raw: key?.raw ?? "",
      };
      for (const l of this.keyListeners) l(ev);
    });

    await this.renderer.start();
  }

  paint(frame: Frame): void {
    if (!this.contentBox) return;
    const flat = frame.rows
      .map((row) => row.map((span) => span.text).join(""))
      .join("\n");

    if (this.contentBox.children) {
      // Clear previous content children and re-add a fresh TextRenderable to
      // keep the imperative API simple. For high redraw rates this should
      // be replaced with an OptimizedBuffer write; this is sufficient for
      // ~30 FPS dashboards.
      for (const child of [...this.contentBox.children]) {
        this.contentBox.remove(child);
      }
    }

    if (this.OpenTui && this.OpenTui.TextRenderable) {
      const text = new this.OpenTui.TextRenderable(this.renderer, {
        id: `frame-${Date.now()}`,
        content: flat,
      });
      this.contentBox.add(text);
    }

    if (this.footerText) {
      this.footerText.content = frame.footer ?? "";
    }

    if (this.modalBox) {
      this.modalBox.visible = !!frame.modal;
      if (this.modalText && frame.modal) {
        this.modalText.content = frame.modal;
      }
    }
  }

  resize(width: number, height: number): void {
    this.currentSize = { width, height };
    // Match `StubAdapter.resize()` and the `RenderAdapter` contract:
    // listeners must observe explicit resize() calls just like real
    // terminal resize events.
    for (const listener of this.resizeListeners) listener({ width, height });
  }

  on(event: "key", listener: Listener<KeyEvent>): void;
  on(event: "resize", listener: Listener<{ width: number; height: number }>): void;
  on(event: string, listener: Listener<any>): void {
    if (event === "key") this.keyListeners.push(listener);
    else if (event === "resize") this.resizeListeners.push(listener);
  }

  async stop(): Promise<void> {
    if (this.renderer && typeof this.renderer.destroy === "function") {
      await this.renderer.destroy();
    }
    this.renderer = null;
  }

  size(): { width: number; height: number } {
    return this.currentSize;
  }
}
