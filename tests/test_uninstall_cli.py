#!/usr/bin/env python3
"""eb-local uninstall, through the command line of the Zig build.

An installation made by EasyBuild through EESSI-extend is read-only, so
rm -rf cannot remove it; uninstall makes it writable and removes it, for
every CPU target, with rtrash or, asked, for good.
"""
import os
from pathlib import Path
import stat
import subprocess
import unittest

import binary
from test_storage import StorageFixture

RTRASH = r'''#!/bin/sh
[ "$1" = put ] || exit 64
shift
[ "$1" = -- ] && shift
for f in "$@"; do printf '%s\n' "$f" >> "$CONTROL_ROOT/trashed"; chmod -R u+w -- "$f"; rm -rf -- "$f"; done
'''


@unittest.skipUnless(binary.BIN, "uninstall is a feature of the Zig build")
class Uninstall(StorageFixture):
    def setUp(self):
        super().setUp()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.env["PATH"] = "/usr/bin:/bin"
        self.installs, self.modules = [], []
        for target in ("x86_64/amd/zen2", "x86_64/amd/zen4"):
            base = self.prefix / "versions" / "2026.06" / "software" / "linux" / target
            install = base / "software" / "pigz" / "2.8-GCCcore-15.2.0"
            (install / "bin").mkdir(parents=True)
            (install / "bin" / "pigz").write_text("binary\n")
            (install / "easybuild").mkdir()
            (install / "easybuild" / "pigz.log").write_text("log\n")
            module = base / "modules" / "all" / "pigz" / "2.8-GCCcore-15.2.0.lua"
            module.parent.mkdir(parents=True)
            module.write_text("-- module\n")
            # Read-only, as EasyBuild leaves it.
            for path in sorted(install.rglob("*"), reverse=True) + [install]:
                path.chmod(0o555 if path.is_dir() else 0o444)
            self.installs.append(install)
            self.modules.append(module)

    def run_tool(self, args, **extra):
        argv, env = binary.command(self.script, args, dict(self.env, SLURM_JOB_ID="", **extra))
        return subprocess.run(argv, env=env, cwd=self.root, capture_output=True, text=True)

    def test_dry_run_lists_every_target(self):
        run = self.run_tool(["uninstall", "pigz/2.8-GCCcore-15.2.0", "--dry-run"])
        self.assertEqual(run.returncode, 0, run.stderr)
        for path in self.installs + self.modules:
            self.assertIn(str(path), run.stdout)
            self.assertTrue(path.exists())

    def test_without_rtrash_nothing_goes_unless_asked(self):
        run = self.run_tool(["uninstall", "pigz/2.8-GCCcore-15.2.0"])
        self.assertEqual(run.returncode, 1)
        self.assertTrue(all(p.exists() for p in self.installs + self.modules))
        run = self.run_tool(["uninstall", "pigz/2.8-GCCcore-15.2.0", "--delete"])
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertFalse(any(p.exists() for p in self.installs + self.modules))
        # The emptied NAME directories go too.
        self.assertFalse(self.installs[0].parent.exists())

    def test_with_rtrash_both_targets_go_to_the_trash(self):
        (self.bin / "rtrash").write_text(RTRASH)
        (self.bin / "rtrash").chmod(0o755)
        run = self.run_tool(["uninstall", "pigz/2.8-GCCcore-15.2.0"], PATH=f"{self.bin}:/usr/bin:/bin")
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        trashed = (self.root / "trashed").read_text().splitlines()
        self.assertEqual(sorted(trashed), sorted(str(p) for p in self.installs + self.modules))
        self.assertFalse(any(p.exists() for p in self.installs + self.modules))

    def test_refusals(self):
        self.assertEqual(self.run_tool(["uninstall", "absent/1.0"]).returncode, 2)
        self.assertEqual(self.run_tool(["uninstall", "pigz"]).returncode, 2)
        self.assertEqual(self.run_tool(["uninstall", "pigz/2.8;rm -rf ~"]).returncode, 2)
        self.assertEqual(self.run_tool(["uninstall", "../x/1"]).returncode, 2)
        self.assertEqual(self.run_tool(["uninstall"]).returncode, 2)
        self.assertTrue(all(p.exists() for p in self.installs + self.modules))

    def test_a_symlinked_tree_is_not_followed(self):
        outside = self.root / "outside"
        outside.mkdir()
        (outside / "keep").write_text("keep\n")
        versions = self.prefix / "versions"
        for path in sorted(versions.rglob("*"), reverse=True):
            os.chmod(path, 0o755 if path.is_dir() else 0o644)
        os.rename(versions, self.root / "real-versions")
        versions.symlink_to(self.root / "real-versions", target_is_directory=True)
        run = self.run_tool(["uninstall", "pigz/2.8-GCCcore-15.2.0", "--delete"])
        self.assertEqual(run.returncode, 2, run.stdout)
        self.assertTrue((self.root / "real-versions").exists())


if __name__ == "__main__":
    unittest.main()
