#!/usr/bin/env python3
"""Run AppModel navigation methods with in-memory playback/animation doubles."""
from pathlib import Path
import os
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / "Bower/App/AppModel.swift").read_text()


def declaration(pattern):
    match = re.search(pattern, source)
    if match is None:
        raise RuntimeError(f"AppModel declaration not found: {pattern}")
    opening = source.index("{", match.start())
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[match.start():end]


methods = [declaration(rf"(?:private )?func {name}\(") for name in (
    "enterPlayer", "hidePlayer", "leavePlayer", "openPlayer", "closeVideoList",
)]
selection = declaration(r"var selection: LibrarySelection\?")
# Include the real transition state declaration once introduced by the fix.
transition = re.search(r"@ObservationIgnored (private var playerTransition\s*=\s*0)", source)
fixture = (ROOT / "tests/PlayerNavigationHarness.swift").read_text()
program = fixture.replace("// APPMODEL_DECLARATIONS", "\n".join([
    transition.group(1) if transition else "", selection, *methods,
]))
with tempfile.TemporaryDirectory(prefix="bower-navigation-") as temporary:
    path = Path(temporary)
    script = path / "main.swift"
    script.write_text(program)
    environment = os.environ.copy()
    environment.setdefault("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")
    result = subprocess.run([
        "swift", "-swift-version", "6", "-default-isolation", "MainActor",
        "-module-cache-path", str(path / "module-cache"), str(script),
    ], env=environment)
    sys.exit(result.returncode)
