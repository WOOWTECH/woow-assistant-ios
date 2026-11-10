#!/usr/bin/env python3
"""Bounded native CLT check; never runs a Python PDF implementation."""
from pathlib import Path
import subprocess
import tempfile


def main():
    repo = Path(__file__).resolve().parents[1]
    sources = sorted(p for p in (repo / "Sources/AssistantSkills").glob("*.swift")
                     if p.name != "SkillLearningService.swift")
    with tempfile.TemporaryDirectory(prefix="woow-pdf-assembly-") as temporary:
        binary = Path(temporary) / "checks"
        subprocess.run(["swiftc", "-D", "SKILL_EXECUTION_SMOKE", "-D", "PDF_ASSEMBLY_STANDALONE",
                        "-parse-as-library", *map(str, sources),
                        str(repo / "Tests/AssistantSkillsTests/SkillPDFAssemblyTests.swift"),
                        "-o", str(binary)], check=True, timeout=180, cwd=repo)
        subprocess.run([str(binary), str(repo / "Sources/AssistantSkills/Resources/MikaBundledSkills.json")],
                       check=True, timeout=120, cwd=repo)


if __name__ == "__main__":
    try:
        main()
    except subprocess.TimeoutExpired:
        raise SystemExit("PDF_ASSEMBLY_CHECK_TIMEOUT")
    except subprocess.CalledProcessError:
        raise SystemExit("PDF_ASSEMBLY_CHECK_FAILED")
