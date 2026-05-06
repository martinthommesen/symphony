export function formatRuntime(seconds: number | null | undefined): string {
  if (!seconds || seconds <= 0) return "0s";
  const total = Math.floor(seconds);
  const days = Math.floor(total / 86_400);
  const hours = Math.floor((total % 86_400) / 3_600);
  const minutes = Math.floor((total % 3_600) / 60);
  const secs = total % 60;
  if (days > 0) return `${days}d ${hours}h`;
  if (hours > 0) return `${hours}h ${minutes}m`;
  if (minutes > 0) return `${minutes}m ${secs}s`;
  return `${secs}s`;
}

export function formatTokens(value: number | null | undefined): string {
  const n = value ?? 0;
  if (Math.abs(n) >= 1_000_000) {
    return `${(n / 1_000_000).toFixed(1)}M`;
  }
  if (Math.abs(n) >= 1_000) {
    return `${(n / 1_000).toFixed(1)}k`;
  }
  return `${n}`;
}

export function pad(value: string | number | null | undefined, width: number, alignRight = false): string {
  const text = value === null || value === undefined ? "" : String(value);
  if (text.length >= width) return text.slice(0, width);
  const padding = " ".repeat(width - text.length);
  return alignRight ? padding + text : text + padding;
}

export function truncate(value: string | null | undefined, width: number): string {
  if (!value) return "";
  if (value.length <= width) return value;
  return value.slice(0, Math.max(0, width - 1)) + "…";
}

export function relativeTime(isoTimestamp: string | null | undefined, now = Date.now()): string {
  if (!isoTimestamp) return "n/a";
  const ts = Date.parse(isoTimestamp);
  if (Number.isNaN(ts)) return "n/a";
  const diff = Math.max(0, Math.floor((now - ts) / 1000));
  if (diff < 5) return "just now";
  if (diff < 60) return `${diff}s ago`;
  if (diff < 3600) return `${Math.floor(diff / 60)}m ago`;
  if (diff < 86_400) return `${Math.floor(diff / 3600)}h ago`;
  return `${Math.floor(diff / 86_400)}d ago`;
}

export function joinSpansText(spans: { text: string }[]): string {
  return spans.map((s) => s.text).join("");
}
