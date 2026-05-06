# acpx Runner

`SymphonyElixir.AgentRunner.Acpx` is the only production runtime agent runner.
It spawns the configured acpx executable with argv-only subprocess construction.

Normal agents are passed as argv values. Custom ACP agents are passed to acpx
with `--agent`; Symphony never spawns custom ACP server commands directly.
