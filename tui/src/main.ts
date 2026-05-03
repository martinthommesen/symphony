/**
 * TUI entrypoint. Loads runtime config, builds an OpenTUI-backed adapter,
 * wires up the API/SSE clients, and starts the app.
 *
 * If the OpenTUI runtime cannot start (no TTY, missing FFI, etc.), we fall
 * back to a one-shot read-only printout so users get a clear error
 * instead of a hung process.
 */

import { ApiClient } from "./api/client.ts";
import { SseClient } from "./api/sse.ts";
import { App } from "./app.ts";
import { loadConfig } from "./config.ts";
import { OpenTuiAdapter } from "./render/opentui_adapter.ts";

async function main(): Promise<void> {
  const config = loadConfig();
  const client = new ApiClient({ baseUrl: config.apiUrl, controlToken: config.controlToken });

  if (!process.stdout.isTTY) {
    await runHeadlessFallback(client);
    return;
  }

  const adapter = new OpenTuiAdapter();

  // The SSE client's callbacks reference `app`, so declare `app` first
  // and feed the constructed SseClient into it afterwards. This avoids
  // a TDZ / use-before-declaration error when the SSE callbacks fire.
  let app!: App;

  const sse = new SseClient({
    baseUrl: config.apiUrl,
    controlToken: config.controlToken,
    onEvent: (event) => app?.ingestEvent(event),
    onStatus: (status, info) => app?.setSseStatus(status, info),
  });

  app = new App({ client, sse, adapter, config });

  process.on("SIGINT", () => void app.stop().then(() => process.exit(0)));
  process.on("SIGTERM", () => void app.stop().then(() => process.exit(0)));

  try {
    await app.start();
  } catch (err) {
    process.stderr.write(`\n[symphony-tui] failed to start renderer: ${(err as Error).message}\n`);
    process.stderr.write(`Hint: ensure Bun is installed and a TTY is attached.\n`);
    process.stderr.write(`      You can also run \`bun test\` to verify the TUI logic without a renderer.\n`);
    await app.stop().catch(() => {});
    process.exit(1);
  }
}

async function runHeadlessFallback(client: ApiClient): Promise<void> {
  process.stderr.write(
    "[symphony-tui] no TTY detected; printing one-shot read-only status. " +
      "Run inside a terminal for the interactive cockpit.\n",
  );

  try {
    const [health, state] = await Promise.all([client.health(), client.state()]);
    process.stdout.write(
      JSON.stringify(
        {
          ok: true,
          mode: "headless",
          health,
          state,
        },
        null,
        2,
      ) + "\n",
    );
  } catch (err) {
    process.stderr.write(`[symphony-tui] backend unreachable: ${(err as Error).message}\n`);
    process.exit(1);
  }
}

void main();
