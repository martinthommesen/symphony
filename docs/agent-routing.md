# Agent Routing

GitHub issue labels select an agent id. Issues need the dispatch label
`symphony`; an optional `symphony/agent/<agent-id>` label overrides the
configured default agent. Multiple agent labels are rejected by default.

The selected agent id maps to an acpx agent argument in `.symphony/config.yml`.
Symphony never spawns the underlying coding-agent executable for runtime work.
