# LinearB Agent Plugins

LinearB plugins for AI coding agents: engineering context from LinearB, right inside your agent.

## Install (Claude Code)

```
/plugin marketplace add linear-b/agent-plugins
/plugin install <plugin-name>@linearb-ai
```

Then restart Claude Code so the plugin's hooks load.

## Plugins

| Plugin | What it does |
| --- | --- |
| [`agentic-advisor`](plugins/agentic-advisor) | Before writing code, grades how fragile the target is (LinearB rework, incidents, unreviewed merges + local git history) and holds the agent to a matching LOW / MEDIUM / HIGH effort level. |

## License

[Apache-2.0](LICENSE) © LinearB, Inc.
