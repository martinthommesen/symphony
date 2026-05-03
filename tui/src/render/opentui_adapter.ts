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

// Local structural types for the subset of `@opentui/core` we touch.
// `@opentui/core` does not ship rich .d.ts at 0.2.2; defining the shape
// here keeps the rest of the file fully typed instead of leaking `any`
// through every renderer interaction.
interface OpenTuiRenderable {
  readonly children?: ReadonlyArray<OpenTuiRenderable>;
  add(child: OpenTuiRenderable): void;
  remove(child: OpenTuiRenderable): void;
  content?: string;
  visible?: boolean;
}

interface OpenTuiKeyInput {
  on?(
    event: "keypress",
    listener: (key: {
      name?: string;
      raw?: string;
      ctrl?: boolean;
      shift?: boolean;
      meta?: boolean;
    }) => void,
  ): void;
}

interface OpenTuiRenderer {
  readonly root: { add(child: OpenTuiRenderable): void };
  on?(event: "resize", listener: (size: { width?: number; height?: number }) => void): void;
  keyInput?: OpenTuiKeyInput;
  terminalWidth?: number;
  terminalHeight?: number;
  start(): Promise<void> | void;
  destroy?(): Promise<void> | void;
}

type OpenTuiModule = typeof import("@opentui/core");

export class OpenTuiAdapter implements RenderAdapter {
  private renderer: OpenTuiRenderer | null = null;
  private rootBox: OpenTuiRenderable | null = null;
  private contentBox: OpenTuiRenderable | null = null;
  private footerText: OpenTuiRenderable | null = null;
  private modalBox: OpenTuiRenderable | null = null;
  private modalText: OpenTuiRenderable | null = null;
  private currentSize = { width: 80, height: 24 };
  private keyListeners: Listener<KeyEvent>[] = [];
  private resizeListeners: Listener<{ width: number; height: number }>[] = [];
  private OpenTui: OpenTuiModule | null = null;
  // Monotonic counter so two paints in the same millisecond don't
  // collide on `frame-${Date.now()}` ids — OpenTUI silently swallows
  // duplicate child ids.
  private paintCounter = 0;

  async start(): Promise<void> {
    // Lazy import so the test bundle stays Bun-FFI-free.
    const mod = (await import("@opentui/core")) as OpenTuiModule;
    this.OpenTui = mod;

    // The `@opentui/core` shape is loose at 0.2.2. We restrict ourselves
    // to the subset declared in OpenTuiRenderer above; a `Renderer` cast
    // here keeps the boundary in one place rather than scattering
    // `as unknown as` throughout the file.
    const ModFactory = mod as unknown as {
      createCliRenderer: (opts: {
        targetFps: number;
        useAlternateScreen: boolean;
        consoleMode: string;
      }) => Promise<OpenTuiRenderer>;
      BoxRenderable: new (renderer: OpenTuiRenderer, opts: Record<string, unknown>) => OpenTuiRenderable;
      TextRenderable: new (renderer: OpenTuiRenderer, opts: Record<string, unknown>) => OpenTuiRenderable;
    };

    this.renderer = await ModFactory.createCliRenderer({
      targetFps: 30,
      useAlternateScreen: true,
      consoleMode: "console-overlay",
    });

    const renderer = this.renderer;
    const { BoxRenderable, TextRenderable } = ModFactory;

    this.rootBox = new BoxRenderable(renderer, {
      id: "symphony-root",
      flexGrow: 1,
      flexDirection: "column",
    });

    this.contentBox = new BoxRenderable(renderer, {
      id: "symphony-content",
      flexGrow: 1,
      flexDirection: "column",
    });

    this.footerText = new TextRenderable(renderer, {
      id: "symphony-footer",
      content: "",
    });

    this.modalBox = new BoxRenderable(renderer, {
      id: "symphony-modal",
      visible: false,
      borderStyle: "single",
      padding: 1,
    });

    this.modalText = new TextRenderable(renderer, {
      id: "symphony-modal-text",
      content: "",
    });

    this.modalBox.add(this.modalText);
    this.rootBox.add(this.contentBox);
    this.rootBox.add(this.footerText);
    this.rootBox.add(this.modalBox);
    renderer.root.add(this.rootBox);

    this.currentSize = {
      width: renderer.terminalWidth ?? 80,
      height: renderer.terminalHeight ?? 24,
    };

    renderer.on?.("resize", (size) => {
      const next = {
        width: size?.width ?? renderer.terminalWidth ?? 80,
        height: size?.height ?? renderer.terminalHeight ?? 24,
      };
      this.currentSize = next;
      for (const l of this.resizeListeners) l(next);
    });

    renderer.keyInput?.on?.("keypress", (key) => {
      const ev: KeyEvent = {
        name: key?.name ?? key?.raw ?? "",
        ctrl: !!key?.ctrl,
        shift: !!key?.shift,
        meta: !!key?.meta,
        raw: key?.raw ?? "",
      };
      for (const l of this.keyListeners) l(ev);
    });

    await renderer.start();
  }

  paint(frame: Frame): void {
    if (!this.contentBox || !this.OpenTui || !this.renderer) return;
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

    const TextRenderable = (this.OpenTui as unknown as {
      TextRenderable: new (renderer: OpenTuiRenderer, opts: Record<string, unknown>) => OpenTuiRenderable;
    }).TextRenderable;

    if (TextRenderable) {
      this.paintCounter += 1;
      const text = new TextRenderable(this.renderer, {
        id: `frame-${this.paintCounter}`,
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
  on(
    event: "key" | "resize",
    listener: Listener<KeyEvent> | Listener<{ width: number; height: number }>,
  ): void {
    if (event === "key") this.keyListeners.push(listener as Listener<KeyEvent>);
    else if (event === "resize") {
      this.resizeListeners.push(listener as Listener<{ width: number; height: number }>);
    }
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
