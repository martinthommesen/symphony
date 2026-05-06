import { appendFile, readFile, rename, unlink } from "node:fs/promises";
import { BoxRenderable, TextRenderable, createCliRenderer } from "@opentui/core";

type Json = Record<string, unknown>;

const CONFIG_PATH = process.env.SYMPHONY_CONFIG ?? ".symphony/config.yml";
const AUDIT_PATH = process.env.SYMPHONY_TUI_AUDIT ?? ".symphony/logs/tui-audit.ndjson";
const LOG_DIR = process.env.SYMPHONY_LOG_DIR ?? ".symphony/logs";
const LOG_FILES = {
  runs: "agent-runs.ndjson",
  acpx: "acpx-events.ndjson",
  orchestrator: "orchestrator.ndjson",
  github: "github.ndjson",
  git: "git.ndjson",
  installer: "installer.ndjson",
  doctor: "doctor.ndjson",
  audit: "tui-audit.ndjson",
  errors: "errors.ndjson"
} as const;

function usage(): never {
  console.log(`Symphony TUI config console

Usage:
  bun run src/index.ts view
  bun run src/index.ts cockpit [--once]
  bun run src/index.ts get <path>
  bun run src/index.ts set <path> <value>
  bun run src/index.ts unset <path>
  bun run src/index.ts agent <agent-id> <field> <value>
  bun run src/index.ts logs [runs|acpx|orchestrator|github|git|installer|doctor|audit|errors] [limit]
  bun run src/index.ts events [limit]
  bun run src/index.ts failures [limit]
  bun run src/index.ts metrics
  bun run src/index.ts audit [limit]

Agent fields:
  enabled display_name issue_label acpx_agent custom_acpx_agent_command
  model.enabled model.config_key model.value model.on_unsupported
  permissions.mode permissions.non_interactive
  runtime.timeout_seconds runtime.ttl_seconds runtime.max_attempts runtime.max_correction_attempts
  notes
`);
  process.exit(2);
}

async function main() {
  const [command, ...args] = Bun.argv.slice(2);
  if (!command) usage();

  const config = await readConfig();

  if (command === "view") {
    printView(config);
    return;
  }

  if (command === "cockpit") {
    if (args.includes("--once") || !process.stdin.isTTY || !process.stdout.isTTY) {
      await printCockpitSnapshot(config);
    } else {
      await runOpenTuiCockpit(config);
    }
    return;
  }

  if (command === "logs") {
    const [kind = "orchestrator", rawLimit = "25"] = args;
    await printLog(kind, Number(rawLimit));
    return;
  }

  if (command === "events") {
    const [rawLimit = "25"] = args;
    await printLog("acpx", Number(rawLimit));
    return;
  }

  if (command === "failures") {
    const [rawLimit = "25"] = args;
    await printFailures(Number(rawLimit));
    return;
  }

  if (command === "metrics") {
    await printMetrics();
    return;
  }

  if (command === "audit") {
    const [rawLimit = "25"] = args;
    await printLog("audit", Number(rawLimit));
    return;
  }

  if (command === "get") {
    const [path] = args;
    if (!path) usage();
    console.log(stringifyValue(getPath(config, path)));
    return;
  }

  if (command === "set") {
    const [path, rawValue] = args;
    if (!path || rawValue === undefined) usage();
    assertSafeConfigEdit(path, rawValue);

    const updated = structuredClone(config);
    setPath(updated, path, coerceValue(rawValue));
    validateConfig(updated);
    await writeConfigAtomically(updated, { path, value: rawValue });
    console.log(`Updated ${path}`);
    return;
  }

  if (command === "unset") {
    const [path] = args;
    if (!path) usage();
    assertSafeConfigEdit(path, "");

    const updated = structuredClone(config);
    deletePath(updated, path);
    validateConfig(updated);
    await writeConfigAtomically(updated, { path, value: "[unset]" });
    console.log(`Unset ${path}`);
    return;
  }

  if (command === "agent") {
    const [agentId, field, rawValue] = args;
    if (!agentId || !field || rawValue === undefined) usage();

    const path = `agents.registry.${agentId}.${field}`;
    assertSafeConfigEdit(path, rawValue);
    const updated = structuredClone(config);
    setPath(updated, path, coerceValue(rawValue));
    validateConfig(updated);
    await writeConfigAtomically(updated, { path, value: rawValue });
    console.log(`Updated ${path}`);
    return;
  }

  usage();
}

async function readConfig(): Promise<Json> {
  const file = Bun.file(CONFIG_PATH);
  if (!(await file.exists())) {
    throw new Error(`Config not found at ${CONFIG_PATH}. Run scripts/install-symphony.sh first.`);
  }

  const decoded = JSON.parse(await rubyYamlToJson(CONFIG_PATH));
  if (!decoded || typeof decoded !== "object" || Array.isArray(decoded)) {
    throw new Error("Config root must be a mapping.");
  }

  validateConfig(decoded as Json);
  return decoded as Json;
}

function printView(config: Json) {
  const routing = getPath(config, "agents.routing") as Json | undefined;
  const registry = (getPath(config, "agents.registry") as Json | undefined) ?? {};
  const acpx = getPath(config, "acpx") as Json | undefined;

  console.log("Symphony Runtime Configuration");
  console.log("");
  console.log(`Config: ${CONFIG_PATH}`);
  console.log(`Dispatch label: ${routing?.required_dispatch_label ?? "symphony"}`);
  console.log(`Default agent: ${routing?.default_agent ?? "codex"}`);
  console.log(`Multi-agent policy: ${routing?.multi_agent_policy ?? "reject"}`);
  console.log(`acpx executable: ${acpx?.executable ?? "acpx"}`);
  console.log("");
  console.log("Agents");

  for (const [id, raw] of Object.entries(registry)) {
    const agent = raw as Json;
    const model = (agent.model as Json | undefined) ?? {};
    const runtime = (agent.runtime as Json | undefined) ?? {};
    console.log(
      `  ${id}: enabled=${agent.enabled ?? true} label=${agent.issue_label ?? ""} acpx=${agent.acpx_agent ?? "custom"} model=${model.enabled ? `${model.config_key}=${model.value}` : "disabled"} timeout=${runtime.timeout_seconds ?? agent.timeout_seconds ?? 3600}s`
    );
  }

  console.log("");
  console.log("Operational Views");
  console.log("  logs runs|acpx|orchestrator|github|git|installer|doctor|audit|errors [limit]");
  console.log("  events [limit]");
  console.log("  failures [limit]");
  console.log("  metrics");
}

function validateConfig(config: Json) {
  const acpxExecutable = getPath(config, "acpx.executable");
  if (acpxExecutable !== undefined && typeof acpxExecutable !== "string") {
    throw new Error("acpx.executable must be a string.");
  }

  const policy = getPath(config, "agents.routing.multi_agent_policy");
  if (policy && !["reject", "fanout_draft_prs", "race_first_success"].includes(String(policy))) {
    throw new Error("agents.routing.multi_agent_policy is invalid.");
  }

  const registry = getPath(config, "agents.registry");
  if (registry !== undefined && (typeof registry !== "object" || Array.isArray(registry))) {
    throw new Error("agents.registry must be a mapping.");
  }

  for (const path of [
    "agent.max_concurrent_agents",
    "validation.max_retries",
    "self_correction.max_correction_attempts",
    "logging.event_retention_days"
  ]) {
    const value = getPath(config, path);
    if (value !== undefined && (!Number.isInteger(value) || Number(value) < 0)) {
      throw new Error(`${path} must be a non-negative integer.`);
    }
  }
}

async function writeConfigAtomically(config: Json, change: { path: string; value: string }) {
  await Bun.write(`${CONFIG_PATH}.json.tmp`, JSON.stringify(config));
  await rubyJsonToYaml(`${CONFIG_PATH}.json.tmp`, `${CONFIG_PATH}.tmp`);
  await rename(`${CONFIG_PATH}.tmp`, CONFIG_PATH);
  await unlink(`${CONFIG_PATH}.json.tmp`);
  await appendAudit(change);
}

async function appendAudit(change: { path: string; value: string }) {
  const event = {
    timestamp: new Date().toISOString(),
    event_type: "tui_config_change",
    severity: "info",
    message: `Updated ${change.path}`,
    payload: { path: change.path, value: redact(change.value) }
  };

  await appendFile(AUDIT_PATH, JSON.stringify(event) + "\n");
}

async function printLog(kind: string, limit: number) {
  const path = logPath(kind);
  const events = await readNdjson(path, boundedLimit(limit));

  console.log(`Symphony ${kind} log`);
  console.log(`Path: ${path}`);
  console.log("");

  for (const event of events) {
    console.log(formatEvent(event));
  }

  if (events.length === 0) console.log("(no events)");
}

async function printCockpitSnapshot(config: Json) {
  console.log(await cockpitText(config));
}

async function runOpenTuiCockpit(config: Json) {
  const renderer = await createCliRenderer({
    exitOnCtrlC: true,
    clearOnShutdown: true,
    targetFps: 10
  });

  const root = new BoxRenderable(renderer, {
    id: "cockpit-root",
    width: "100%",
    height: "100%",
    flexDirection: "column",
    padding: 1,
    gap: 1,
    border: true,
    title: "Symphony Operations Cockpit",
    borderColor: "#6aa9ff"
  });

  const header = new TextRenderable(renderer, {
    id: "cockpit-header",
    content: "q: quit  r: refresh  views: config, agents, logs, failures, metrics",
    height: 1
  });

  const body = new TextRenderable(renderer, {
    id: "cockpit-body",
    content: await cockpitText(config),
    height: "100%"
  });

  root.add(header);
  root.add(body);
  renderer.root.add(root);

  renderer.addInputHandler((sequence) => {
    if (sequence === "q" || sequence === "\u0003") {
      renderer.destroy();
      process.exit(0);
      return true;
    }

    if (sequence === "r") {
      void readConfig().then(async (fresh) => {
        body.content = await cockpitText(fresh);
        renderer.requestRender();
      });
      return true;
    }

    return false;
  });

  renderer.start();
}

async function cockpitText(config: Json): Promise<string> {
  const routing = getPath(config, "agents.routing") as Json | undefined;
  const acpx = getPath(config, "acpx") as Json | undefined;
  const registry = (getPath(config, "agents.registry") as Json | undefined) ?? {};
  const runEvents = await readNdjson(logPath("runs"), 2000);
  const acpxEvents = await readNdjson(logPath("acpx"), 5);
  const failures = await recentFailures(5);
  const metrics = await metricsRows();

  const enabledAgents = Object.entries(registry)
    .filter(([, raw]) => (raw as Json).enabled !== false)
    .map(([id]) => id)
    .join(", ");

  return [
    "Runtime",
    `  config: ${CONFIG_PATH}`,
    `  dispatch_label: ${routing?.required_dispatch_label ?? "symphony"}`,
    `  default_agent: ${routing?.default_agent ?? "codex"}`,
    `  multi_agent_policy: ${routing?.multi_agent_policy ?? "reject"}`,
    `  acpx: ${acpx?.executable ?? "acpx"}`,
    "",
    "Agents",
    `  enabled: ${enabledAgents || "(none)"}`,
    "",
    "Live Run Log",
    ...formatEventLines(runEvents.slice(-5)),
    "",
    "acpx Events",
    ...formatEventLines(acpxEvents),
    "",
    "Failure Classifier",
    ...formatEventLines(failures),
    "",
    "Per-Agent Metrics",
    ...(metrics.length > 0 ? metrics : ["  (no agent run metrics)"])
  ].join("\n");
}

async function recentFailures(limit: number): Promise<Json[]> {
  const events = await readNdjson(logPath("orchestrator"), 5000);
  return events
    .filter((event) => {
      const text = `${event.event_type ?? ""} ${event.message ?? ""} ${JSON.stringify(event.payload ?? {})}`;
      return /failure|failed|self_correction|recovery|ambiguous_agent_labels|unsupported_agent|validation_failed|tests_failed|no_changes/i.test(text);
    })
    .slice(-boundedLimit(limit));
}

function formatEventLines(events: Json[]): string[] {
  if (events.length === 0) return ["  (no events)"];
  return events.map((event) => `  ${formatEvent(event)}`);
}

async function printFailures(limit: number) {
  const failures = await recentFailures(limit);

  console.log("Symphony failure classifier and recovery decisions");
  console.log("");

  for (const event of failures) {
    console.log(formatEvent(event));
  }

  if (failures.length === 0) console.log("(no failure or recovery events)");
}

async function printMetrics() {
  const rows = await metricsRows();

  console.log("Symphony per-agent metrics");
  console.log("");

  if (rows.length === 0) {
    console.log("(no agent run metrics)");
    return;
  }

  for (const row of rows) console.log(row);
}

async function metricsRows(): Promise<string[]> {
  const runEvents = await readNdjson(logPath("runs"), 10_000);
  const summary = new Map<string, { runs: number; failures: number; durationMs: number; retries: number; validationFailures: number }>();

  for (const event of runEvents) {
    const payload = event.payload as Json | undefined;
    const agent = String(event.agent_id ?? payload?.selected_agent ?? payload?.agent_id ?? "unknown");
    const current = summary.get(agent) ?? { runs: 0, failures: 0, durationMs: 0, retries: 0, validationFailures: 0 };
    const exitCode = payload?.exit_code;
    const duration = Number(payload?.duration_ms ?? payload?.duration ?? 0);
    const attempt = Number(payload?.attempt ?? payload?.attempt_number ?? 1);
    const failureClass = String(payload?.failure_class ?? "");

    current.runs += event.event_type === "agent_run_started" ? 1 : 0;
    current.failures += exitCode !== undefined && exitCode !== 0 ? 1 : 0;
    current.durationMs += Number.isFinite(duration) ? duration : 0;
    current.retries += Number.isFinite(attempt) && attempt > 1 ? 1 : 0;
    current.validationFailures += /validation_failed|tests_failed/.test(failureClass) ? 1 : 0;
    summary.set(agent, current);
  }

  const recoveryEvents = await readNdjson(logPath("orchestrator"), 10_000);
  for (const event of recoveryEvents) {
    const payload = event.payload as Json | undefined;
    const agent = String(event.agent_id ?? payload?.selected_agent ?? "unknown");
    if (agent === "unknown") continue;
    const current = summary.get(agent) ?? { runs: 0, failures: 0, durationMs: 0, retries: 0, validationFailures: 0 };
    const failureClass = String(payload?.failure_class ?? "");
    current.retries += /recovery|self_correction/.test(String(event.event_type ?? "")) ? 1 : 0;
    current.validationFailures += /validation_failed|tests_failed/.test(failureClass) ? 1 : 0;
    summary.set(agent, current);
  }

  if (summary.size === 0) return [];

  return [...summary.entries()].sort(([a], [b]) => a.localeCompare(b)).map(([agent, metrics]) => {
    const averageDurationMs = metrics.runs > 0 ? Math.round(metrics.durationMs / metrics.runs) : 0;
    return `${agent}: runs=${metrics.runs} failures=${metrics.failures} avg_duration_ms=${averageDurationMs} retries=${metrics.retries} validation_failures=${metrics.validationFailures}`;
  });
}

async function readNdjson(path: string, limit: number): Promise<Json[]> {
  let content = "";

  try {
    content = await readFile(path, "utf8");
  } catch (error) {
    if ((error as { code?: string }).code === "ENOENT") return [];
    throw error;
  }

  return content
    .split("\n")
    .filter((line) => line.trim() !== "")
    .slice(-limit)
    .map((line) => {
      try {
        const parsed = JSON.parse(line);
        return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? (parsed as Json) : { message: line };
      } catch {
        return { message: line };
      }
    });
}

function formatEvent(event: Json): string {
  const timestamp = event.timestamp ?? "";
  const severity = event.severity ?? "info";
  const eventType = event.event_type ?? "event";
  const runId = event.run_id ? ` run=${event.run_id}` : "";
  const issue = event.issue_number ? ` issue=${event.issue_number}` : "";
  const agent = event.agent_id ? ` agent=${event.agent_id}` : "";
  const message = event.message ?? "";
  const payload = event.payload && typeof event.payload === "object" ? summarizePayload(event.payload as Json) : "";

  return `${timestamp} ${severity} ${eventType}${runId}${issue}${agent} ${message}${payload ? ` ${payload}` : ""}`.trim();
}

function summarizePayload(payload: Json): string {
  const keys = [
    "failure_class",
    "recovery_action",
    "attempt",
    "result",
    "next_action",
    "selected_agent",
    "agent_execution_backend",
    "direct_agent_spawn",
    "spawned_executable",
    "exit_code",
    "duration_ms"
  ];

  const parts = keys
    .filter((key) => payload[key] !== undefined)
    .map((key) => `${key}=${JSON.stringify(payload[key])}`);

  return parts.length > 0 ? `[${parts.join(" ")}]` : "";
}

function logPath(kind: string): string {
  if (!(kind in LOG_FILES)) {
    throw new Error(`Unknown log kind ${kind}. Known kinds: ${Object.keys(LOG_FILES).join(", ")}`);
  }
  return `${LOG_DIR}/${LOG_FILES[kind as keyof typeof LOG_FILES]}`;
}

function boundedLimit(limit: number): number {
  if (!Number.isInteger(limit) || limit <= 0) return 25;
  return Math.min(limit, 500);
}

function getPath(root: Json, path: string): unknown {
  return path.split(".").reduce<unknown>((current, part) => {
    if (!current || typeof current !== "object" || Array.isArray(current)) return undefined;
    return (current as Json)[part];
  }, root);
}

function setPath(root: Json, path: string, value: unknown) {
  const parts = path.split(".");
  const leaf = parts.at(-1);
  if (!leaf) return;
  let current: Json = root;

  for (const part of parts.slice(0, -1)) {
    if (!current[part] || typeof current[part] !== "object" || Array.isArray(current[part])) {
      current[part] = {};
    }
    current = current[part] as Json;
  }

  current[leaf] = value;
}

function deletePath(root: Json, path: string) {
  const parts = path.split(".");
  const leaf = parts.at(-1);
  if (!leaf) return;
  let current: Json = root;

  for (const part of parts.slice(0, -1)) {
    if (!current[part] || typeof current[part] !== "object" || Array.isArray(current[part])) return;
    current = current[part] as Json;
  }

  delete current[leaf];
}

function coerceValue(value: string): unknown {
  if (value === "true") return true;
  if (value === "false") return false;
  if (value === "null") return null;
  if (/^-?\d+$/.test(value)) return Number(value);
  return value;
}

function stringifyValue(value: unknown): string {
  if (typeof value === "string") return value;
  return JSON.stringify(value, null, 2);
}

function redact(value: string): string {
  return value.replace(/([A-Za-z0-9_]*(TOKEN|SECRET|KEY|PASSWORD)[A-Za-z0-9_]*=)[^\s]+/gi, "$1[REDACTED]");
}

function assertSafeConfigEdit(path: string, value: string) {
  if (!/^[A-Za-z0-9_.-]+$/.test(path)) throw new Error(`Invalid config path: ${path}`);
  if (/(secret|token|password|api[_-]?key|credential)/i.test(path)) {
    throw new Error("Secrets must not be written to .symphony/config.yml.");
  }
  if (looksLikeSecret(value)) {
    throw new Error("Refusing to write a secret-looking value to .symphony/config.yml.");
  }
}

function looksLikeSecret(value: string): boolean {
  return /(ghp_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9]{20,}|Bearer\s+[A-Za-z0-9._-]{20,}|[A-Za-z0-9_]*(TOKEN|SECRET|PASSWORD|API_KEY)=)/i.test(value);
}

async function rubyYamlToJson(path: string): Promise<string> {
  const proc = Bun.spawn(["ruby", "-ryaml", "-rjson", "-e", "print JSON.generate(YAML.load_file(ARGV.fetch(0)) || {})", path], {
    stdout: "pipe",
    stderr: "pipe"
  });
  const [stdout, stderr, exitCode] = await Promise.all([
    Bun.readableStreamToText(proc.stdout),
    Bun.readableStreamToText(proc.stderr),
    proc.exited
  ]);
  if (exitCode !== 0) throw new Error(`YAML parse failed: ${stderr.trim()}`);
  return stdout;
}

async function rubyJsonToYaml(jsonPath: string, yamlPath: string): Promise<void> {
  const proc = Bun.spawn(
    [
      "ruby",
      "-rjson",
      "-ryaml",
      "-e",
      "File.write(ARGV.fetch(1), JSON.parse(File.read(ARGV.fetch(0))).to_yaml)",
      jsonPath,
      yamlPath
    ],
    { stdout: "pipe", stderr: "pipe" }
  );
  const stderr = await Bun.readableStreamToText(proc.stderr);
  const exitCode = await proc.exited;
  if (exitCode !== 0) throw new Error(`YAML write failed: ${stderr.trim()}`);
}

main().catch((error) => {
  console.error(`[symphony-tui] ERROR: ${error.message}`);
  process.exit(1);
});
