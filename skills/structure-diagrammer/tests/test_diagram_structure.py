"""Synthetic boundary and compatibility checks for the source candidate."""

from __future__ import annotations

import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "diagram_structure.py"
SPEC = importlib.util.spec_from_file_location("diagram_structure", SCRIPT)
assert SPEC and SPEC.loader
diagram = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = diagram
SPEC.loader.exec_module(diagram)


class DiagramBoundaryTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="diagram-boundary-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.inputs = self.root / "inputs"
        self.outputs = self.root / "outputs"
        self.inputs.mkdir()
        self.outputs.mkdir()

    def run_diagram(self, input_path: Path, *extra: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "--input", str(input_path),
                "--input-root", str(self.inputs),
                "--output", str(self.outputs),
                "--output-root", str(self.outputs),
                *extra,
            ],
            text=True,
            capture_output=True,
            check=False,
        )

    def test_agent_manifest_is_never_opened_for_content(self) -> None:
        manifest = self.inputs / "agent.yaml"
        manifest.write_text("skills: PRIVATE_SENTINEL\n", encoding="utf-8")
        original_open = Path.open

        def guard(path: Path, *args: object, **kwargs: object):
            if path == manifest:
                raise AssertionError("agent manifest content was opened")
            return original_open(path, *args, **kwargs)

        with mock.patch.object(Path, "open", guard):
            name, _, nodes, edges = diagram.build_graph(manifest, "agent")
        self.assertEqual("agent", name)
        self.assertEqual(2, len(nodes))
        self.assertEqual(1, len(edges))
        result = self.run_diagram(manifest)
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertNotIn("PRIVATE_SENTINEL", (self.outputs / "agent" / "agent-structure.md").read_text(encoding="utf-8"))

    def test_skill_frontmatter_only_and_nominal_outputs(self) -> None:
        skill = self.inputs / "sample"
        skill.mkdir()
        (skill / "SKILL.md").write_text(
            "---\nname: sample\ndescription: safe metadata\n---\nPRIVATE_BODY_SENTINEL\n",
            encoding="utf-8",
        )
        (skill / "scripts").mkdir()
        (skill / "scripts" / "helper.py").write_text("PRIVATE_SCRIPT_SENTINEL", encoding="utf-8")
        result = self.run_diagram(skill)
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        output = self.outputs / "sample"
        self.assertEqual(4, len(list(output.iterdir())))
        combined = "\n".join(path.read_text(encoding="utf-8") for path in output.iterdir())
        self.assertIn("safe metadata", combined)
        self.assertNotIn("PRIVATE_BODY_SENTINEL", combined)
        self.assertNotIn("PRIVATE_SCRIPT_SENTINEL", combined)

    def test_project_metadata_listing_does_not_follow_symlinks(self) -> None:
        project = self.inputs / "project"
        project.mkdir()
        outside = self.root / "private"
        outside.mkdir()
        (outside / "secret.txt").write_text("PRIVATE_SENTINEL", encoding="utf-8")
        (project / "docs").symlink_to(outside, target_is_directory=True)
        result = self.run_diagram(project, "--mode", "project")
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        report = (self.outputs / "project" / "project-structure.md").read_text(encoding="utf-8")
        self.assertNotIn("secret.txt", report)
        self.assertNotIn("PRIVATE_SENTINEL", report)

    def test_skill_frontmatter_symlink_is_not_read(self) -> None:
        outside = self.root / "private-skill.md"
        outside.write_text("---\nname: private\ndescription: PRIVATE_SENTINEL\n---\n", encoding="utf-8")
        skill = self.inputs / "linked"
        skill.mkdir()
        (skill / "SKILL.md").symlink_to(outside)
        result = self.run_diagram(skill, "--mode", "skill")
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        report = (self.outputs / "linked" / "linked-structure.md").read_text(encoding="utf-8")
        self.assertNotIn("PRIVATE_SENTINEL", report)

    def test_input_and_output_escapes_fail_before_writing(self) -> None:
        outside = self.root / "outside.yaml"
        outside.write_text("secret: PRIVATE_SENTINEL", encoding="utf-8")
        self.assertNotEqual(0, self.run_diagram(outside).returncode)
        (self.inputs / "escape.yaml").symlink_to(outside)
        self.assertNotEqual(0, self.run_diagram(self.inputs / "escape.yaml").returncode)
        safe = self.inputs / "safe.yaml"
        safe.write_text("name: safe", encoding="utf-8")
        result = self.run_diagram(safe, "--output", str(self.root / "outside-outputs"))
        self.assertNotEqual(0, result.returncode)
        self.assertFalse((self.root / "outside-outputs").exists())
        self.assertEqual([], list(self.outputs.iterdir()))

    def test_basename_and_existing_outputs_are_guarded(self) -> None:
        manifest = self.inputs / "agent.yaml"
        manifest.write_text("name: sample", encoding="utf-8")
        self.assertNotEqual(0, self.run_diagram(manifest, "--basename", "../escape").returncode)
        self.assertEqual([], list(self.outputs.iterdir()))
        self.assertEqual(0, self.run_diagram(manifest).returncode)
        output = self.outputs / "agent"
        initial_outputs = {path.name: path.read_bytes() for path in output.iterdir()}
        report = output / "agent-structure.md"
        initial = report.read_bytes()
        self.assertNotEqual(0, self.run_diagram(manifest).returncode)
        self.assertEqual(initial, report.read_bytes())
        self.assertEqual(initial_outputs, {path.name: path.read_bytes() for path in output.iterdir()})
        self.assertEqual(0, self.run_diagram(manifest, "--replace").returncode)
        report.unlink()
        outside = self.root / "outside.md"
        outside.write_text("KEEP", encoding="utf-8")
        report.symlink_to(outside)
        self.assertNotEqual(0, self.run_diagram(manifest, "--replace").returncode)
        self.assertEqual("KEEP", outside.read_text(encoding="utf-8"))

    def test_roots_are_required(self) -> None:
        manifest = self.inputs / "agent.yaml"
        manifest.write_text("name: sample", encoding="utf-8")
        result = subprocess.run(
            [sys.executable, str(SCRIPT), "--input", str(manifest), "--output", str(self.outputs)],
            text=True, capture_output=True, check=False,
        )
        self.assertNotEqual(0, result.returncode)
        self.assertEqual([], list(self.outputs.iterdir()))


if __name__ == "__main__":
    unittest.main()
