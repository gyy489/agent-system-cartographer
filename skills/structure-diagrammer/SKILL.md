---
name: structure-diagrammer
description: Draw and maintain structure diagrams for local agents, skills, plugins, workflows, and the two-head-wu system. Use when the user wants to visualize, explain, learn, audit, or document an agent/skill architecture; create Mermaid/SVG diagrams from a local directory; turn system-cartographer facts into teaching diagrams; prepare Archscribe/Excalidraw-style specs; or make high-efficiency structure maps for the two-head-wu project.
---

# Structure Diagrammer

Create diagrams from facts first, then render them for the target use. The
default path is deterministic and local: scan a directory, emit a Markdown
explanation, Mermaid source, SVG preview, and an optional Archscribe spec.

## Decision Tree

1. For two-head-wu runtime topology, run `system-cartographer` first and use
   its generated inventories as the source of truth.
2. For one skill, agent, plugin, or folder, run `scripts/diagram_structure.py`
   directly against that path.
3. For fast documentation, keep Mermaid as the source of truth and SVG as the
   preview.
4. For polished teaching visuals, hand-drawn diagrams, animations, Excalidraw,
   GIF, MP4, or DailyDoseOfDS-style outputs, generate the Archscribe spec and
   render it with Archscribe when the `archscribe` skill/backend is installed
   and validated.
5. If the diagram makes an inferred relationship, label it as inferred. Do not
   invent runtime call edges from filenames alone.

## Quick Start

Draw a skill structure:

```bash
python3 skills/structure-diagrammer/scripts/diagram_structure.py \
  --input skills/system-cartographer \
  --output /tmp/structure-diagrammer \
  --basename system-cartographer
```

Draw a project or agent folder:

```bash
python3 skills/structure-diagrammer/scripts/diagram_structure.py \
  --input /path/to/agent-or-project \
  --output /tmp/structure-diagrammer \
  --mode auto
```

Outputs:

```text
<basename>-structure.md
<basename>-structure.mmd
<basename>-structure.svg
<basename>-archscribe-spec.json
```

## Output Policy

- Put temporary diagrams under `skills/artifacts/structure-diagrammer`.
- Put durable two-head-wu explanatory architecture diagrams under
  `skills/outputs/structure-diagrammer`.
- Keep generated topology maps under
  `skills/outputs/system-cartographer/topology`.
- Keep `.mmd` as the editable source for maintainable architecture docs.
- Keep `.svg` for quick preview and sharing.
- Keep `*-archscribe-spec.json` when the diagram should later become animated,
  hand-drawn, Excalidraw-editable, or publication-grade.

## Diagram Quality Rules

- Keep learning diagrams small: 6-15 nodes is usually better than one giant
  complete map.
- Prefer action labels on edges: `loads`, `uses`, `writes`, `reads`,
  `activates`, `publishes`.
- Separate source, runtime, state, logs, and output nodes.
- For skills, always show `SKILL.md`, `agents/openai.yaml`, `scripts/`,
  `references/`, `assets/`, and generated outputs when present.
- For agents, always show manifest/config, source code, tools/skills,
  state/context, logs, and output artifacts when present.
- For two-head-wu maps, do not duplicate `system-cartographer`'s full topology;
  extract a focused teaching view from it.

## Archscribe Integration

Read `references/tooling.md` before deciding whether to render with Archscribe.
Use Archscribe when the user asks for:

- 手绘架构图
- 动态架构图
- Excalidraw 风格图
- GIF / MP4 technical explainer
- DailyDoseOfDS / 岚叔 style diagrams
- polished learning visuals for articles, talks, or public reports

Use this skill first when the task is to understand a structure quickly, because
it can generate the factual graph without needing browser rendering or animation
dependencies.
