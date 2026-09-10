---
name: system-cartographer
description: Scan and map local agent systems as physical, logical, and runtime topology diagrams. Use when Codex needs to inventory agents, skills, manifests, registries, launchers, environments, context directories, logs, symlinks, or their relationships; explain where components live or how they connect; detect topology drift, broken paths, duplicate skills, unregistered components, or stale registries; or update Mermaid system maps after local architecture changes. Do not use for ordinary source-code dependency analysis inside a single application.
---

# System Cartographer

Create reproducible maps from filesystem and registry facts. Keep tool source,
runtime state, logs, and published inventories separate.

## Workflow

1. Identify the target project root.
2. Read `references/topology-schema.md` when changing the scanner, output
   schema, directory policy, or audit rules.
3. Run the unified deterministic updater:

   ```bash
   ruby <skill-dir>/scripts/update_topology.rb --root <project-root>
   ```

   It runs the project scanner and, when
   `<project-root>/registries/cartography_registry.yaml` exists, the detailed
   local-machine scanner.

4. Inspect `topology-audit.md` and `local-topology-audit.md` when present.
5. Report the generated paths, error and warning counts, and any unresolved
   relationships. Do not claim the topology is clean when the audit reports
   errors.
6. Open `detailed-system-map.md`, `system-map.md`, or the `.mmd` files in a
   Mermaid-capable preview.

Use `--strict` when topology errors should produce a nonzero exit status:

```bash
ruby <skill-dir>/scripts/update_topology.rb --root <project-root> --strict
```

## Storage Contract

- Keep Skill source in `skills/`.
- Keep scanner state, cache, and unpublished output in
  `skills/contexts/system-cartographer/`.
- Keep logs in `skills/logs/system-cartographer/`.
- Publish durable maps in `skills/outputs/system-cartographer/topology/`.
- Never create a root-level directory named after this Skill.
- Never write generated files into the Skill source directory.

The scanner may create only these managed output directories. Preserve files
outside them.

## Scan Boundaries

Read only:

- directory and symlink metadata;
- `SKILL.md` frontmatter;
- `registries/*.yaml`;
- `agents/manifests/*.yaml`.
- `registries/cartography_registry.yaml` and only the external paths declared
  there.

Do not inspect secrets, credential files, context bodies, model data,
environment package contents, `.git`, caches, logs, or Agent source bodies.

## Manual Interpretation

Treat generated relationships precisely:

- `available_to` means a Skill is exposed through an active surface, not that
  an Agent invokes it in every run.
- `configured_path` means a manifest or registry declares a path.
- `source_of` means an active Skill resolves to that source directory.
- Missing evidence is `unknown`; do not infer a runtime call edge from names
  alone.

Add manually confirmed edges to project registries or manifests, then rerun
the scanner. Do not hand-edit generated topology files as the source of truth.
