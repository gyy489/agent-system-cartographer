# Structure Diagram Tooling

Use this reference when choosing a rendering backend.

## Default Layers

| Layer | Tool | Role |
|---|---|---|
| Facts | `system-cartographer` or direct directory scan | Source of truth for agent/skill topology. |
| Editable source | Mermaid `.mmd` | Versionable, diffable, easy to keep in docs. |
| Quick preview | Built-in SVG writer | No dependency, fast visual inspection. |
| Polished teaching visual | Archscribe spec | Hand-drawn, animated, Excalidraw-ready output. |

## Tool Choice

Use Mermaid when:

- The diagram belongs in docs or architecture inventory.
- The structure will change often.
- The main need is quick understanding.
- The diagram must remain easy to diff and edit.

Use the built-in SVG output when:

- The user wants an immediate visual preview.
- No Mermaid renderer is installed.
- The diagram needs to be shared quickly.

Use Archscribe when:

- The user asks for hand-drawn, animated, Excalidraw, GIF, MP4, DailyDoseOfDS,
  or 岚叔-style diagrams.
- The diagram is for teaching, presentations, articles, or public-facing
  reports.
- The structure has already been reduced to a clear 6-15 node story.

Use Graphviz, D2, or PlantUML only when the user specifically prefers those
formats or an existing project already uses them.

## Archscribe Status

Archscribe is a strong candidate for the polished rendering layer because it
generates `.excalidraw`, PNG, SVG, GIF, MP4, and interactive HTML from one JSON
spec. It is not the default source-of-truth layer because it has a larger
runtime surface: Pillow, `svg.path`, optional Playwright/Chromium, and ffmpeg.

Recommended two-head-wu policy:

1. Generate Mermaid/SVG/Archscribe spec with `structure-diagrammer`.
2. Use Archscribe only after the spec validates.
3. Keep the Mermaid and Archscribe spec beside the final image/video.
4. Do not overwrite generated topology maps from `system-cartographer`; create
   focused explanatory diagrams separately.

## Quality Checklist

- The title explains the diagram's purpose.
- The graph has one visible entry point and one visible output or learning
  conclusion.
- Source, runtime, state, logs, and outputs are separate nodes.
- Edge labels use verbs.
- Dashed or annotated edges are treated as inferred until verified.
- A teaching diagram should usually stay under 15 nodes.
