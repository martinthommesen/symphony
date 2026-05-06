# Self-Correction

Symphony classifies failures, logs the decision, and retries only when config
allows it. Retry loops are bounded by per-agent runtime settings and
self-correction settings.

Validation and test failures build a corrective prompt with the failing command,
exit code, relevant logs, and current diff summary, then rerun the same selected
agent through acpx.
