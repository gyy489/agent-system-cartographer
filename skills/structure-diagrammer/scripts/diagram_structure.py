#!/usr/bin/env python3
"""Generate structure diagrams for agents, skills, and project folders."""

from __future__ import annotations

import argparse
from collections import defaultdict, deque
from dataclasses import dataclass
from datetime import datetime, timezone
import html
import json
from pathlib import Path
import re
import textwrap


DEFAULT_OUTPUT = Path("artifacts/structure-diagrams")
SPECIAL_DIRS = {
    "agents": ("agents", "agent metadata"),
    "scripts": ("scripts", "executable helpers"),
    "references": ("references", "loaded-on-demand knowledge"),
    "assets": ("assets", "templates and media"),
    "tests": ("tests", "validation"),
    "docs": ("docs", "documentation"),
    "registries": ("registries", "machine-readable registry"),
    "inventories": ("inventories", "published inventory"),
    "contexts": ("contexts", "runtime state"),
    "logs": ("logs", "execution logs"),
    ".codex-plugin": ("plugin", "Codex plugin manifest"),
}


@dataclass(frozen=True)
class Node:
    id: str
    label: str
    kind: str
    detail: str = ""
    path: Path | None = None


@dataclass(frozen=True)
class Edge:
    source: str
    target: str
    label: str = ""
    inferred: bool = False


def slug(text: str) -> str:
    cleaned = re.sub(r"[^a-zA-Z0-9_]+", "_", text).strip("_").lower()
    return cleaned or "node"


def unique_id(base: str, used: set[str]) -> str:
    candidate = slug(base)
    if candidate not in used:
        used.add(candidate)
        return candidate
    index = 2
    while f"{candidate}_{index}" in used:
        index += 1
    value = f"{candidate}_{index}"
    used.add(value)
    return value


def read_text(path: Path, limit: int = 12000) -> str:
    try:
        return path.read_text(encoding="utf-8", errors="replace")[:limit]
    except OSError:
        return ""


def frontmatter(path: Path) -> dict[str, str]:
    text = read_text(path)
    match = re.match(r"\A---\s*\n(.*?)\n---\s*\n", text, re.DOTALL)
    if not match:
        return {}
    data: dict[str, str] = {}
    current_key = ""
    current_lines: list[str] = []
    for raw in match.group(1).splitlines():
        if raw.startswith((" ", "\t")) and current_key:
            current_lines.append(raw.strip())
            continue
        if current_key:
            data[current_key] = " ".join(current_lines).strip().strip("\"'")
        if ":" not in raw:
            current_key = ""
            current_lines = []
            continue
        key, value = raw.split(":", 1)
        current_key = key.strip()
        current_lines = [value.strip()]
    if current_key:
        data[current_key] = " ".join(current_lines).strip().strip("\"'")
    return data


def count_files(path: Path) -> int:
    if path.is_file():
        return 1
    try:
        return sum(1 for item in path.rglob("*") if item.is_file())
    except OSError:
        return 0


def list_files(path: Path, max_items: int = 8) -> list[Path]:
    if not path.exists():
        return []
    if path.is_file():
        return [path]
    files = []
    for item in sorted(path.rglob("*"), key=lambda p: p.as_posix()):
        if item.is_file() and "__pycache__" not in item.parts and ".git" not in item.parts:
            files.append(item)
        if len(files) >= max_items:
            break
    return files


def detect_mode(root: Path, requested: str) -> str:
    if requested != "auto":
        return requested
    if (root / "SKILL.md").is_file():
        return "skill"
    if (root / ".codex-plugin" / "plugin.json").is_file():
        return "plugin"
    if root.name == "manifests" or root.suffix in {".yaml", ".yml", ".json"}:
        return "agent"
    if (root / "agents").exists() or (root / "skills").exists() or (root / "registries").exists():
        return "project"
    return "project"


def add_node(nodes: list[Node], used: set[str], label: str, kind: str, detail: str = "", path: Path | None = None) -> str:
    node_id = unique_id(label, used)
    nodes.append(Node(node_id, label, kind, detail, path))
    return node_id


def summarize_skill(root: Path, nodes: list[Node], edges: list[Edge], used: set[str]) -> tuple[str, str]:
    meta = frontmatter(root / "SKILL.md")
    name = meta.get("name") or root.name
    desc = meta.get("description", "")
    root_id = add_node(nodes, used, f"Skill: {name}", "skill", short(desc), root)

    skill_md = add_node(nodes, used, "SKILL.md", "file", "trigger and workflow instructions", root / "SKILL.md")
    edges.append(Edge(root_id, skill_md, "defines"))

    for dirname, (label, detail) in SPECIAL_DIRS.items():
        child = root / dirname
        if child.exists():
            count = count_files(child)
            child_id = add_node(nodes, used, label, dirname.strip(".") or "directory", f"{detail}; {count} file(s)", child)
            edges.append(Edge(root_id, child_id, "contains"))
            for file_path in list_files(child, max_items=5):
                rel = file_path.relative_to(root)
                file_id = add_node(nodes, used, rel.as_posix(), "file", file_role(file_path), file_path)
                edges.append(Edge(child_id, file_id, "includes"))

    for special in ["requirements.txt", "pyproject.toml", "package.json", "README.md", "LICENSE"]:
        item = root / special
        if item.is_file():
            item_id = add_node(nodes, used, special, "file", file_role(item), item)
            edges.append(Edge(root_id, item_id, "uses"))

    return name, desc


def summarize_project(root: Path, nodes: list[Node], edges: list[Edge], used: set[str]) -> tuple[str, str]:
    root_id = add_node(nodes, used, f"Project: {root.name}", "project", root.as_posix(), root)
    description = "project folder structure"
    for child in sorted(root.iterdir(), key=lambda p: p.name.lower()) if root.is_dir() else []:
        if child.name.startswith(".") and child.name not in {".codex-plugin"}:
            continue
        if child.name in {"node_modules", "__pycache__"}:
            continue
        if child.is_dir():
            label, detail = SPECIAL_DIRS.get(child.name, (child.name, "directory"))
            child_id = add_node(nodes, used, label, child.name, f"{detail}; {count_files(child)} file(s)", child)
            edges.append(Edge(root_id, child_id, "contains"))
        elif child.name in {"SKILL.md", "README.md", "pyproject.toml", "package.json"} or child.suffix in {".yaml", ".yml", ".json"}:
            child_id = add_node(nodes, used, child.name, "file", file_role(child), child)
            edges.append(Edge(root_id, child_id, "contains"))
    return root.name, description


def summarize_agent(root: Path, nodes: list[Node], edges: list[Edge], used: set[str]) -> tuple[str, str]:
    if root.is_file():
        text = read_text(root)
        name = root.stem
        root_id = add_node(nodes, used, f"Agent: {name}", "agent", "manifest file", root)
        manifest_id = add_node(nodes, used, root.name, "manifest", "configuration", root)
        edges.append(Edge(root_id, manifest_id, "configured by"))
        for key in ["skills", "tools", "contexts", "logs", "outputs"]:
            if re.search(rf"\b{re.escape(key)}\b", text, re.IGNORECASE):
                node_id = add_node(nodes, used, key, key, f"mentioned in {root.name}", root)
                edges.append(Edge(manifest_id, node_id, "declares", inferred=True))
        return name, "agent manifest"
    return summarize_project(root, nodes, edges, used)


def file_role(path: Path) -> str:
    name = path.name.lower()
    suffix = path.suffix.lower()
    if name == "skill.md":
        return "skill trigger and procedure"
    if name == "openai.yaml":
        return "UI metadata"
    if suffix in {".py", ".sh", ".rb", ".js", ".ts"}:
        return "executable helper"
    if suffix in {".md", ".txt"}:
        return "reference text"
    if suffix in {".json", ".yaml", ".yml"}:
        return "structured config"
    if suffix in {".svg", ".png", ".jpg", ".jpeg", ".gif", ".webp"}:
        return "visual asset"
    return "file"


def short(text: str, limit: int = 110) -> str:
    text = " ".join(text.split())
    return text if len(text) <= limit else text[: limit - 1].rstrip() + "..."


def mermaid_label(node: Node) -> str:
    parts = [node.label]
    if node.detail:
        parts.append(short(node.detail, 70))
    return "<br/>".join(escape_mermaid(part) for part in parts)


def escape_mermaid(text: str) -> str:
    return text.replace('"', "'").replace("[", "(").replace("]", ")").replace("|", "/")


def mermaid(nodes: list[Node], edges: list[Edge]) -> str:
    lines = ["flowchart LR"]
    for node in nodes:
        shape_open, shape_close = {
            "skill": ("{{", "}}"),
            "agent": ("{{", "}}"),
            "project": ("{{", "}}"),
            "manifest": ("[", "]"),
            "scripts": ("[", "]"),
            "references": ("[", "]"),
            "assets": ("[", "]"),
        }.get(node.kind, ("[", "]"))
        lines.append(f'  {node.id}{shape_open}"{mermaid_label(node)}"{shape_close}')
    for edge in edges:
        label = f"|{escape_mermaid(edge.label)}|" if edge.label else ""
        connector = "-.->" if edge.inferred else "-->"
        lines.append(f"  {edge.source} {connector}{label} {edge.target}")
    lines.extend(
        [
            "  classDef root fill:#dff4e4,stroke:#287a3f,color:#14261a",
            "  classDef file fill:#eef2ff,stroke:#5264c7,color:#1f2a5c",
            "  classDef runtime fill:#fff7d6,stroke:#b7791f,color:#3d2b00",
        ]
    )
    return "\n".join(lines) + "\n"


def graph_levels(nodes: list[Node], edges: list[Edge]) -> dict[str, int]:
    incoming: dict[str, int] = {node.id: 0 for node in nodes}
    outgoing: dict[str, list[str]] = defaultdict(list)
    for edge in edges:
        outgoing[edge.source].append(edge.target)
        incoming[edge.target] = incoming.get(edge.target, 0) + 1
    queue = deque([node.id for node in nodes if incoming.get(node.id, 0) == 0])
    levels = {node_id: 0 for node_id in queue}
    while queue:
        node_id = queue.popleft()
        for target in outgoing.get(node_id, []):
            levels[target] = max(levels.get(target, 0), levels[node_id] + 1)
            incoming[target] -= 1
            if incoming[target] == 0:
                queue.append(target)
    for node in nodes:
        levels.setdefault(node.id, 0)
    return levels


def svg(nodes: list[Node], edges: list[Edge], title: str) -> str:
    levels = graph_levels(nodes, edges)
    by_level: dict[int, list[Node]] = defaultdict(list)
    for node in nodes:
        by_level[levels[node.id]].append(node)
    col_w = 320
    row_h = 116
    margin = 36
    box_w = 244
    box_h = 76
    width = max(720, margin * 2 + col_w * (max(by_level.keys(), default=0) + 1))
    height = max(420, margin * 2 + 60 + row_h * max((len(v) for v in by_level.values()), default=1))
    positions: dict[str, tuple[int, int]] = {}
    for level, group in by_level.items():
        total_h = (len(group) - 1) * row_h
        start_y = margin + 70 + max(0, (height - margin * 2 - 70 - total_h - box_h) // 2)
        for index, node in enumerate(group):
            positions[node.id] = (margin + level * col_w, start_y + index * row_h)

    lines = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}">',
        "<defs>",
        '<marker id="arrow" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M 0 0 L 10 5 L 0 10 z" fill="#52616b"/></marker>',
        "</defs>",
        '<rect width="100%" height="100%" fill="#fbfcfd"/>',
        f'<text x="{margin}" y="38" font-family="Arial, PingFang SC, sans-serif" font-size="24" font-weight="700" fill="#102a43">{html.escape(title)}</text>',
    ]
    for edge in edges:
        if edge.source not in positions or edge.target not in positions:
            continue
        sx, sy = positions[edge.source]
        tx, ty = positions[edge.target]
        x1, y1 = sx + box_w, sy + box_h // 2
        x2, y2 = tx, ty + box_h // 2
        mid = (x1 + x2) // 2
        dash = ' stroke-dasharray="6 6"' if edge.inferred else ""
        lines.append(f'<path d="M{x1},{y1} C{mid},{y1} {mid},{y2} {x2},{y2}" fill="none" stroke="#52616b" stroke-width="1.8"{dash} marker-end="url(#arrow)"/>')
        if edge.label:
            lx, ly = (x1 + x2) // 2, (y1 + y2) // 2 - 8
            lines.append(f'<text x="{lx}" y="{ly}" text-anchor="middle" font-family="Arial, PingFang SC, sans-serif" font-size="11" fill="#52616b">{html.escape(edge.label)}</text>')

    for node in nodes:
        x, y = positions[node.id]
        fill, stroke = colors_for(node.kind)
        lines.append(f'<rect x="{x}" y="{y}" width="{box_w}" height="{box_h}" rx="8" fill="{fill}" stroke="{stroke}" stroke-width="1.8"/>')
        text_lines = wrap_svg_text(node.label, 25)[:2]
        if node.detail:
            text_lines.extend(wrap_svg_text(short(node.detail, 64), 34)[:2])
        for index, text in enumerate(text_lines[:4]):
            size = 14 if index == 0 else 11
            weight = "700" if index == 0 else "400"
            color = "#102a43" if index == 0 else "#52616b"
            lines.append(f'<text x="{x + 14}" y="{y + 22 + index * 16}" font-family="Arial, PingFang SC, sans-serif" font-size="{size}" font-weight="{weight}" fill="{color}">{html.escape(text)}</text>')
    lines.append("</svg>")
    return "\n".join(lines) + "\n"


def colors_for(kind: str) -> tuple[str, str]:
    if kind in {"skill", "agent", "project"}:
        return "#dff4e4", "#287a3f"
    if kind in {"scripts", "script"}:
        return "#fff7d6", "#b7791f"
    if kind in {"references", "docs"}:
        return "#e6f6ff", "#2b6cb0"
    if kind in {"assets"}:
        return "#fcebea", "#c05621"
    if kind in {"contexts", "logs", "inventories", "registries"}:
        return "#f0f4f8", "#627d98"
    return "#eef2ff", "#5264c7"


def wrap_svg_text(text: str, width: int) -> list[str]:
    if has_cjk(text):
        return [text[i : i + width] for i in range(0, len(text), width)]
    return textwrap.wrap(text, width=width) or [text]


def has_cjk(text: str) -> bool:
    return any("\u4e00" <= char <= "\u9fff" for char in text)


def archscribe_spec(nodes: list[Node], edges: list[Edge], title: str, subtitle: str) -> dict:
    return {
        "layout": "graph",
        "style": "paper",
        "animation": "flow",
        "title": {
            "prefix": "Structure",
            "highlight": short(title, 18),
            "subtitle": short(subtitle, 90),
        },
        "density": "balanced",
        "direction": "right",
        "nodes": [
            {
                "id": node.id,
                "label": short(node.label, 36),
                "body": short(node.detail, 72) if node.detail else "",
                "icon": icon_for(node.kind),
                "kind": "card" if node.kind not in {"manifest"} else "terminal",
            }
            for node in nodes[:24]
        ],
        "edges": [
            {
                "from": edge.source,
                "to": edge.target,
                "label": edge.label,
                "kind": "loop" if edge.inferred else "flow",
            }
            for edge in edges
            if edge.source in {node.id for node in nodes[:24]} and edge.target in {node.id for node in nodes[:24]}
        ][:40],
    }


def icon_for(kind: str) -> str:
    return {
        "skill": "agent",
        "agent": "agent",
        "project": "folder",
        "scripts": "terminal",
        "references": "file",
        "assets": "package",
        "tests": "check",
        "docs": "clipboard",
        "registries": "db",
        "inventories": "audit",
        "contexts": "brain",
        "logs": "event",
        "manifest": "clipboard",
        "file": "file",
    }.get(kind, "folder")


def report_md(root: Path, mode: str, name: str, description: str, nodes: list[Node], edges: list[Edge], mmd_path: Path, svg_path: Path, spec_path: Path) -> str:
    lines = [
        f"# {name} Structure Diagram",
        "",
        f"Generated: `{datetime.now(timezone.utc).isoformat(timespec='seconds')}`",
        f"Source: `{root.as_posix()}`",
        f"Mode: `{mode}`",
        "",
    ]
    if description:
        lines.extend(["## Summary", "", description, ""])
    lines.extend(
        [
            "## Outputs",
            "",
            f"- Mermaid source: `{mmd_path.as_posix()}`",
            f"- SVG preview: `{svg_path.as_posix()}`",
            f"- Archscribe spec: `{spec_path.as_posix()}`",
            "",
            "## Nodes",
            "",
            "| Node | Kind | Detail | Path |",
            "|---|---|---|---|",
        ]
    )
    for node in nodes:
        path = node.path.as_posix() if node.path else ""
        lines.append(f"| `{node.label}` | `{node.kind}` | {node.detail.replace('|', '/')} | `{path}` |")
    lines.extend(["", "## Mermaid", "", "```mermaid", mermaid(nodes, edges).rstrip(), "```", ""])
    lines.extend(
        [
            "## Quality Notes",
            "",
            "- Mermaid is the maintainable source for documentation.",
            "- SVG is the quick preview artifact.",
            "- Archscribe spec is for polished hand-drawn or animated rendering.",
            "- Inferred edges are dashed in Mermaid/SVG and should be verified before treating them as runtime facts.",
        ]
    )
    return "\n".join(lines) + "\n"


def build_graph(root: Path, mode: str) -> tuple[str, str, list[Node], list[Edge]]:
    nodes: list[Node] = []
    edges: list[Edge] = []
    used: set[str] = set()
    if mode == "skill":
        name, description = summarize_skill(root, nodes, edges, used)
    elif mode == "agent":
        name, description = summarize_agent(root, nodes, edges, used)
    elif mode == "plugin":
        name, description = summarize_project(root, nodes, edges, used)
    else:
        name, description = summarize_project(root, nodes, edges, used)
    return name, description, nodes, edges


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, required=True, help="Skill, agent, plugin, or project path.")
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT, help="Output directory.")
    parser.add_argument("--basename", help="Output basename. Defaults to input folder/file name.")
    parser.add_argument("--mode", choices=["auto", "skill", "agent", "plugin", "project"], default="auto")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    root = args.input.expanduser()
    if not root.is_absolute():
        root = (Path.cwd() / root).resolve()
    if not root.exists():
        print(f"Input path does not exist: {root}", flush=True)
        return 1
    mode = detect_mode(root, args.mode)
    name, description, nodes, edges = build_graph(root, mode)
    output_dir = args.output / (args.basename or slug(root.stem if root.is_file() else root.name))
    output_dir.mkdir(parents=True, exist_ok=True)
    base = args.basename or slug(name)
    mmd_path = output_dir / f"{base}-structure.mmd"
    svg_path = output_dir / f"{base}-structure.svg"
    spec_path = output_dir / f"{base}-archscribe-spec.json"
    md_path = output_dir / f"{base}-structure.md"

    mmd_path.write_text(mermaid(nodes, edges), encoding="utf-8")
    svg_path.write_text(svg(nodes, edges, f"{name} structure"), encoding="utf-8")
    spec_path.write_text(json.dumps(archscribe_spec(nodes, edges, name, description), ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    md_path.write_text(report_md(root, mode, name, description, nodes, edges, mmd_path, svg_path, spec_path), encoding="utf-8")

    print(f"Generated structure diagram: {md_path}")
    print(f"Mermaid: {mmd_path}")
    print(f"SVG: {svg_path}")
    print(f"Archscribe spec: {spec_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
