#!/usr/bin/env python3
"""What an adversarial review of eb-local 2.1 found, as tests of the Zig build.

Each test is one finding: a user's own configuration file cannot set the
storage settings; uninstall touches only installations and never follows a
symbolic link; clean says what it removed; secrets are removed from the
installation's copy of the log and in their encoded forms, and the log
directory is private while they may be in it.
"""
import base64
import json
import os
from pathlib import Path
import stat
import subprocess
import unittest

import binary
from test_storage import StorageFixture

EB_ECHO = r'''
eb() {
    python3 - "$@" <<'PY'
import base64, os
v = os.environ["SOURCE_TOKEN"]
root = os.environ["EESSI_USER_INSTALL"]
logs = os.environ["EASYBUILD_TMP_LOGDIR"]
mode = oct(os.stat(logs).st_mode & 0o777)
open(os.path.join(os.environ["CONTROL_ROOT"], "logs-mode"), "w").write(mode)
open(os.path.join(logs, "easybuild-x.log"), "w").write(f"raw {v}\nauth {base64.b64encode(v.encode()).decode()}\n")
inst = os.path.join(root, "versions/2026.06/software/linux/x86_64/amd/zen4/software/demo/1/easybuild")
os.makedirs(inst, exist_ok=True)
open(os.path.join(inst, "easybuild-demo-1.log"), "w").write(f"copied {v}\n")
PY
}
export -f eb
'''


@unittest.skipUnless(binary.BIN, "features of the Zig build")
class Hardening(StorageFixture):
    def run_tool(self, args, **extra):
        argv, env = binary.command(self.script, args, dict(self.env, **extra))
        return subprocess.run(argv, env=env, cwd=self.root, capture_output=True, text=True)

    def test_a_users_own_file_cannot_set_storage(self):
        # The program belongs to another account, as a site install does; the
        # caller's file then is a user file, and [storage] is refused.
        mine = self.root / "mine.toml"
        mine.write_text('[storage]\nnode_local_root = "/tmp"\nshared_scratch = []\n')
        mine.chmod(0o600)
        run = self.run_tool(["--config", str(mine), "recipe.eb"], EB_LOCAL_TEST_SELF_OWNER=str(os.getuid() + 1))
        self.assertEqual(run.returncode, 2, run.stdout)
        self.assertIn("site setting", run.stderr)
        self.assertFalse(self.prefix.exists())

    def test_uninstall_matches_only_installations(self):
        target = self.prefix / "versions" / "2026.06" / "software" / "linux" / "x86_64" / "amd" / "zen4"
        (target / "software" / "pigz" / "2.8").mkdir(parents=True)
        (target / "modules" / "all" / "pigz").mkdir(parents=True)
        (target / "modules" / "all" / "pigz" / "2.8.lua").write_text("--\n")
        for name in ("linux/x86_64", "software/linux"):
            run = self.run_tool(["uninstall", name, "--delete"], SLURM_JOB_ID="")
            self.assertEqual(run.returncode, 2, run.stdout)
            self.assertTrue((target / "software" / "pigz" / "2.8").is_dir())

    def test_uninstall_does_not_follow_a_symlinked_name(self):
        target = self.prefix / "versions" / "2026.06" / "software" / "linux" / "x86_64" / "amd" / "zen4"
        (target / "software").mkdir(parents=True)
        (target / "modules" / "all").mkdir(parents=True)
        victim = self.root / "victim"
        (victim / "data").mkdir(parents=True)
        (victim / "data" / "keep").write_text("keep\n")
        (target / "software" / "Foo").symlink_to(victim, target_is_directory=True)
        run = self.run_tool(["uninstall", "Foo/data", "--delete"], SLURM_JOB_ID="")
        self.assertEqual(run.returncode, 2, run.stdout + run.stderr)
        self.assertTrue((victim / "data" / "keep").exists())

    def test_clean_says_what_it_removed(self):
        kept = self.run_tool(["recipe.eb"], CONTROL_EB_STATUS="5")
        self.assertEqual(kept.returncode, 5)
        run = self.run_tool(["clean", "--workspaces", "--no-logs"], PATH="/usr/bin:/bin")
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertIn("removed 1 build workspace(s)", run.stdout)
        self.assertNotIn("nothing", run.stdout + run.stderr)

    def test_secrets_leave_no_log_and_the_log_directory_is_private(self):
        token = self.root / "token"
        token.write_text("tok-3141-secret\n")
        token.chmod(0o600)
        # The 1.x site file cannot carry secrets; name a TOML site file.
        site = self.root / "site.toml"
        site.write_text(f'[storage]\nnode_local_root = "{self.nodes}"\n'
                        f'[secrets]\nSOURCE_TOKEN = "file:{token}"\n')
        site.chmod(0o600)
        with open(self.root / "doubles.sh", "a") as handle:
            handle.write(EB_ECHO)
        run = self.run_tool(["--config", str(site), "recipe.eb"])
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertEqual((self.root / "logs-mode").read_text(), "0o700")
        b64 = base64.b64encode(b"tok-3141-secret").decode()
        for path in self.prefix.rglob("*.log"):
            text = path.read_text()
            self.assertNotIn("tok-3141-secret", text, path)
            self.assertNotIn(b64, text, path)
        copied = next(self.prefix.rglob("easybuild-demo-1.log")).read_text()
        self.assertIn("<secret SOURCE_TOKEN removed by eb-local>", copied)


if __name__ == "__main__":
    unittest.main()
