# Topology Schema And Policy

## Data Sources

The scanner uses four evidence classes:

1. Filesystem metadata: directory existence and symlink targets.
2. Skill metadata: only YAML frontmatter from `SKILL.md`.
3. Registries: YAML files under `registries/` and `skills/registries/`, plus
   the registered JSON Release lifecycle ledger.
4. Agent manifests: YAML files under `agents/manifests/`.

It intentionally excludes source-code import graphs. Those require a
language-specific analyzer and should be added as a separate evidence source.

## Managed Outputs

```text
skills/contexts/system-cartographer/
  cache/
  generated/topology.yaml
  state/last-scan.json
  workspace/

skills/logs/system-cartographer/
  scan.log

skills/outputs/system-cartographer/topology/
  topology.yaml
  local-topology.yaml
  system-map.md
  detailed-system-map.md
  physical-topology.mmd
  logical-topology.mmd
  runtime-topology.mmd
  complete-topology.mmd
  local-agent-topology.mmd
  skill-discovery-topology.mmd
  skill-storage-topology.mmd
  topology-audit.md
  local-topology-audit.md
```

`skills/contexts` contains reproducible skill working state. `skills/outputs`
contains the current published skill-owned snapshots. A future history feature
should store snapshots under `skills/contexts`, not duplicate dated files in
`skills/outputs`.

The project-level `development/` directory is a human-maintained governance
surface for notes, reports, and decisions. Treat it as a physical topology
node, not as runtime state, generated output, or an evidence source for runtime
call relationships.

Architecture V2 also exposes `core/`, `catalog/`, `capabilities/`, and `var/`
as physical topology nodes. Recursively scan `capabilities/` for packaged
`SKILL.md` sources, but do not infer that every package component is a Skill or
that package presence grants runtime access.

Human-facing Markdown headings, tables, Mermaid nodes, and relationship labels
use Chinese-first bilingual text (`中文 / English`). Keep component names,
filesystem paths, registry values, YAML keys, and finding codes unchanged so
the visual maps remain traceable to machine-readable evidence.

## Topology Record

`topology.yaml` contains:

- `generated_at`: UTC timestamp.
- `project_root`: absolute scanned root.
- `summary`: counts for agents, source Skills, globally visible Skills, and findings.
- `directories`: managed top-level directory roles and existence.
- `agents`: normalized entries from `registries/agents_registry.yaml`.
- `skills`: merged source, active-surface, and registry metadata.
- `relationships`: evidence-backed directed edges.
- `audit`: errors, warnings, and informational findings.

## Audit Levels

- `error`: declared path missing, broken active link, duplicate active name, or
  required registry inconsistency.
- `warning`: a globally visible component is not registered. In lifecycle v1,
  a declared active component not exposed is also a warning; in v2, registered
  and approved Skills may intentionally remain project-hot or cold.
- `info`: source-only component or optional expected directory not present.

Strict mode exits nonzero only for errors.

## Detailed Local Scope

`registries/cartography_registry.yaml` declares local Agent hosts, interaction
surfaces, Skill discovery roots, inactive stores, and expected symlinks.
`scan_local_assets.rb` may inspect only those declared paths.

Keep lifecycle classes distinct:

- `canonical_source`: editable source library.
- `compatibility_catalog`: approved compatibility view retained for legacy
  tooling; it is not itself a runtime visibility decision.
- `release_store`: immutable, digest-addressed local Release snapshots.
- `active`, `active_alias`, `active_user`: live discovery surfaces.
- `runtime_builtin`: a runtime-owned built-in Skill layer; lifecycle managers may inventory it but must not replace or write it.
- `generated_surface`: manager-built compatibility surface prepared for a
  runtime that is not necessarily installed or connected.
- `backup`: recovery copy.
- `bundled_agent_internal`: Skill shipped inside an Agent source tree.
- `standalone_project_source`: Skill owned by another local project.
- `dependency_source`: Skill-like metadata shipped inside a dependency.
- `vendor_catalog`: locally available upstream catalog.
- `temporary_catalog`: replaceable marketplace checkout.
- `cache`: downloaded but not installed content.

Counts from aliases must not be added to unique active Skill counts.

Use `derived_from` when a generated runtime surface is a filtered view of
another discovery surface. Duplicate-name auditing groups derived surfaces
with their source without claiming that the two paths are filesystem aliases.
Use `duplicate_group` for independent runtime discovery roots that intentionally
expose some of the same project Skills; it suppresses only duplicate-name noise
and does not imply aliasing or derivation.

## Change Rules

- Add new evidence parsers without weakening scan boundaries.
- Keep generated Mermaid node IDs deterministic.
- Label inferred relationships explicitly; never present inference as a
  configured fact.
- Preserve backward compatibility for existing top-level YAML keys.
- Test against a temporary fixture and the Liang-Tou-Wu workspace after script
  changes.
