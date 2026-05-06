# Security

acpx normalizes agent execution. It is not a sandbox.

Symphony workspace isolation is not host isolation. High-autonomy agents can
execute commands inside the workspace through their tools. Default controls are
isolated workspaces, argv-only subprocess execution, branch validation before
push, configurable permission mode, no auto-merge, no auto-close, token
redaction, bounded retries, and TUI config audit logging.
