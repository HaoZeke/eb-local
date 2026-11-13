"""Check exact allocation identity independently of inherited temporary paths."""
import json
import os
from pathlib import Path
import pwd
import unittest

import test_storage as storage


class CurrentJobStorageControls(unittest.TestCase):
    def setUp(self):
        self.fixture = storage.StorageControls("test_build_paths_survive_unload_and_module_initialization")
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        selected = self.fixture.nodes / (pwd.getpwuid(os.getuid()).pw_name + ".123")
        self.fixture.job.rename(selected)
        self.fixture.job = selected
        self.fixture.env.update(CONTROL_JOB_ROOT=str(selected), TMPDIR=str(selected),
                                USER="untrusted-name", LOGNAME="untrusted-name")

    def successful(self, tmpdir):
        run = self.fixture.run_wrapper(TMPDIR=tmpdir)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        paths = json.loads((self.fixture.root / "eb.json").read_text())["paths"]
        self.assertTrue(Path(paths["TMPDIR"]).is_relative_to(self.fixture.job))
        self.assertTrue(Path(paths["WORKING_DIR"]).is_relative_to(self.fixture.job))

    def test_shared_tmpdir_does_not_hide_the_current_owned_mount(self):
        self.successful("/scratch-shared/inherited")

    def test_nested_tmpdir_does_not_select_a_second_workspace_domain(self):
        self.successful(str(self.fixture.job / "nested"))

    def test_another_owned_job_mount_is_not_the_current_job(self):
        other = self.fixture.nodes / "other.999"
        self.fixture.job.rename(other)
        self.fixture.env.update(CONTROL_JOB_ROOT=str(other))
        run = self.fixture.run_wrapper(TMPDIR=str(other))
        self.assertEqual(run.returncode, 2, run.stdout + run.stderr)
        self.assertFalse(self.fixture.prefix.exists())
        self.assertFalse((self.fixture.root / "load.json").exists())

    def test_changed_job_identity_cannot_reuse_the_inherited_mount(self):
        run = self.fixture.run_wrapper(SLURM_JOB_ID="124")
        self.assertEqual(run.returncode, 2, run.stdout + run.stderr)
        self.assertFalse(self.fixture.prefix.exists())
        self.assertEqual(list(self.fixture.job.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
