#!/usr/bin/env python3
"""The env, dev and clean commands, and the build workspace's lifetime.

The fixture and the module, eb and findmnt doubles are those of
test_storage; rtrash is a double that records what it was given.
"""
import os
from pathlib import Path
import subprocess
import time
import unittest

from test_storage import StorageFixture

RTRASH = r'''#!/bin/sh
[ "$1" = put ] || exit 64
shift
[ "$1" = -- ] && shift
for f in "$@"; do printf '%s\n' "$f" >> "$CONTROL_ROOT/trashed"; rm -f -- "$f"; done
'''


class Commands(StorageFixture):
    def setUp(self):
        super().setUp()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.env["PATH"] = os.environ["PATH"]

    def with_rtrash(self):
        rtrash = self.bin / "rtrash"
        rtrash.write_text(RTRASH)
        rtrash.chmod(0o755)
        self.env["PATH"] = f"{self.bin}:{os.environ['PATH']}"

    def workspaces(self):
        return sorted(p.name for p in self.job.iterdir() if p.name.startswith("eb-local."))

    def replay(self, text):
        """Run printed lines in bash with a module double that records each call."""
        script = self.root / "replay.sh"
        script.write_text('module() { printf "%s\\n" "$*" >> "$CONTROL_ROOT/module-calls"; }\n' + text)
        return subprocess.run(["bash", str(script)], env=self.env, cwd=self.root, text=True, capture_output=True)

    # -- the build workspace -------------------------------------------------

    def test_successful_build_removes_its_workspace(self):
        run = self.run_wrapper()
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertEqual(self.workspaces(), [])
        self.assertIn('eval "$(eb-local env)"', run.stdout)

    def test_failed_build_keeps_its_workspace_and_says_where(self):
        run = self.run_wrapper(CONTROL_EB_STATUS="5")
        self.assertEqual(run.returncode, 5, run.stdout + run.stderr)
        kept = self.workspaces()
        self.assertEqual(len(kept), 1)
        self.assertIn(str(self.job / kept[0]), run.stderr)

    def test_keep_work_keeps_a_successful_workspace(self):
        run = self.run_wrapper(EB_LOCAL_KEEP_WORK="1")
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertEqual(len(self.workspaces()), 1)

    # -- env and dev ---------------------------------------------------------

    def test_dev_loads_the_named_modules_then_the_build_environment_last(self):
        run = self.run_wrapper(["dev", "GSL/2.8-GCC-15.2.0", "FFTW/3.3.10-GCC-15.2.0"], SLURM_JOB_ID="")
        self.assertEqual(run.returncode, 0, run.stderr)
        replay = self.replay(run.stdout)
        self.assertEqual(replay.returncode, 0, replay.stderr)
        calls = (self.root / "module-calls").read_text().splitlines()
        self.assertEqual(calls[-3:], ["load EESSI/2026.06 EESSI-extend/2026.06-easybuild",
                                      "load GSL/2.8-GCC-15.2.0 FFTW/3.3.10-GCC-15.2.0",
                                      "load buildenv/default-foss-2026.1"])
        self.assertFalse(self.prefix.exists())

    def test_dev_refuses_a_module_name_that_is_not_one(self):
        for name in ("GSL; touch injected", "$(touch injected)", "../x", "a b", "-x", "GSL/`id`"):
            with self.subTest(name=name):
                run = self.run_wrapper(["dev", name], SLURM_JOB_ID="")
                self.assertEqual(run.returncode, 2, run.stdout)
                self.assertEqual(run.stdout, "")
        self.assertFalse((self.root / "injected").exists())

    def test_dev_buildenv_comes_from_the_option_or_the_configuration(self):
        run = self.run_wrapper(["dev", "--buildenv", "buildenv/default-gompi-2026.1"], SLURM_JOB_ID="")
        self.assertTrue(run.stdout.rstrip().endswith("module load buildenv/default-gompi-2026.1"), run.stdout)
        self.config.write_text(self.config.read_text() + "dev_buildenv = buildenv/mine\nstack_module = 2026\n")
        run = self.run_wrapper(["dev"], SLURM_JOB_ID="")
        self.assertIn("module load 2026 EESSI-extend/2026.06-easybuild", run.stdout)
        self.assertTrue(run.stdout.rstrip().endswith("module load buildenv/mine"), run.stdout)

    def test_configured_module_names_are_checked(self):
        self.config.write_text(self.config.read_text() + "stack_module = EESSI;touch injected\n")
        run = self.run_wrapper(["env"], SLURM_JOB_ID="")
        self.assertEqual(run.returncode, 2)
        self.assertEqual(run.stdout, "")

    def test_dev_warns_about_ld_library_path(self):
        run = self.run_wrapper(["dev"], SLURM_JOB_ID="", LD_LIBRARY_PATH="/somewhere")
        self.assertEqual(run.returncode, 0)
        self.assertIn("LD_LIBRARY_PATH", run.stderr)
        self.assertNotIn("LD_LIBRARY_PATH", run.stdout)

    def test_env_subcommand_matches_the_legacy_option(self):
        new = self.run_wrapper(["env"], SLURM_JOB_ID="")
        old = self.run_wrapper(["--env"], SLURM_JOB_ID="")
        self.assertEqual((new.returncode, new.stdout), (0, old.stdout))
        self.assertEqual(self.run_wrapper(["env", "extra"], SLURM_JOB_ID="").returncode, 2)

    # -- clean ---------------------------------------------------------------

    def logs(self, *ages_days):
        logs = self.prefix / ".eb-local" / "logs" / "Foo-1"
        logs.mkdir(parents=True)
        paths = []
        for n, age in enumerate(ages_days):
            p = logs / f"easybuild-{n}.log"
            p.write_text("log\n")
            t = time.time() - age * 86400
            os.utime(p, (t, t))
            paths.append(p)
        return paths

    def test_clean_moves_old_logs_to_the_trash(self):
        self.with_rtrash()
        old, new = self.logs(40, 1)
        run = self.run_wrapper(["clean"], SLURM_JOB_ID="")
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertEqual((self.root / "trashed").read_text().splitlines(), [str(old)])
        self.assertTrue(new.exists())

    def test_clean_without_rtrash_deletes_nothing_unless_asked(self):
        self.env["PATH"] = "/usr/bin:/bin"
        old, = self.logs(40)
        run = self.run_wrapper(["clean"], SLURM_JOB_ID="")
        self.assertEqual(run.returncode, 1)
        self.assertTrue(old.exists())
        run = self.run_wrapper(["clean", "--delete"], SLURM_JOB_ID="")
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertFalse(old.exists())

    def test_clean_dry_run_lists_and_keeps(self):
        self.with_rtrash()
        old, = self.logs(40)
        run = self.run_wrapper(["clean", "--dry-run"], SLURM_JOB_ID="")
        self.assertEqual(run.returncode, 0)
        self.assertIn(str(old), run.stdout)
        self.assertTrue(old.exists())
        self.assertFalse((self.root / "trashed").exists())

    def test_clean_does_not_follow_a_symlinked_log_directory(self):
        self.with_rtrash()
        outside = self.root / "outside"
        outside.mkdir()
        victim = outside / "important.log"
        victim.write_text("keep\n")
        os.utime(victim, (0, 0))
        (self.prefix / ".eb-local").mkdir(parents=True)
        (self.prefix / ".eb-local" / "logs").symlink_to(outside, target_is_directory=True)
        run = self.run_wrapper(["clean"], SLURM_JOB_ID="")
        self.assertNotEqual(run.returncode, 0)
        self.assertTrue(victim.exists())
        self.assertFalse((self.root / "trashed").exists())

    def test_clean_does_not_follow_a_symlink_inside_the_logs(self):
        self.with_rtrash()
        outside = self.root / "outside.log"
        outside.write_text("keep\n")
        os.utime(outside, (0, 0))
        self.logs(1)
        (self.prefix / ".eb-local" / "logs" / "Foo-1" / "link.log").symlink_to(outside)
        run = self.run_wrapper(["clean"], SLURM_JOB_ID="")
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertTrue(outside.exists())

    def test_clean_sources_only_when_asked(self):
        self.with_rtrash()
        sources = self.prefix / ".eb-local" / "sources" / "f"
        sources.mkdir(parents=True)
        tarball = sources / "foo-1.tar.gz"
        tarball.write_text("x")
        self.run_wrapper(["clean"], SLURM_JOB_ID="")
        self.assertTrue(tarball.exists())
        self.run_wrapper(["clean", "--sources"], SLURM_JOB_ID="")
        self.assertFalse(tarball.exists())

    def test_clean_workspaces_removes_only_eb_local_workspaces_of_this_job(self):
        kept = self.run_wrapper(CONTROL_EB_STATUS="5")
        self.assertEqual(kept.returncode, 5)
        mine, = self.workspaces()
        other = self.job / "user-data"
        other.mkdir()
        lookalike = self.job / "eb-local.link"
        lookalike.symlink_to(other, target_is_directory=True)
        run = self.run_wrapper(["clean", "--workspaces", "--no-logs"])
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertFalse((self.job / mine).exists())
        self.assertTrue(other.is_dir())
        self.assertTrue(lookalike.is_symlink())

    def test_clean_workspaces_needs_the_allocation(self):
        run = self.run_wrapper(["clean", "--workspaces"], SLURM_JOB_ID="")
        self.assertEqual(run.returncode, 2)


if __name__ == "__main__":
    unittest.main()
