#!/usr/bin/env python3
"""TOML configuration, profiles, EB_LOCAL_* overrides and secrets, through
the command line of the Zig build (EB_LOCAL_BIN). The Bash script has none
of these, so the tests run only against the binary.
"""
import json
import os
from pathlib import Path
import stat
import subprocess
import unittest

import binary
from test_storage import StorageFixture

SITE = '''
[storage]
node_local_root = "{nodes}"
node_local_fstype = "xfs"
shared_scratch = ["/scratch-shared"]

[build]
allocation_hint = "salloc -p rome -n 16"

[profile.gpu]
dev.modules = ["CUDA/13.3.0"]
'''

USER = '''
default_profile = "mine"

[profile.mine]
dev.modules = ["FFTW/3.3.10-GCC-15.2.0"]

[profile.licensed.secrets]
LM_LICENSE_FILE = "nimvault:licences/flexlm"

[secrets]
SOURCE_TOKEN = "file:{token}"
OTHER_TOKEN = "env:MY_OTHER"
'''

NIMVAULT = r'''#!/bin/sh
[ "$1" = get ] || exit 64
case "$2" in
  licences/flexlm) printf '27000@licence.example\n' ;;
  *) echo "no entry $2" >&2; exit 1 ;;
esac
'''

# An eb that records what it received and echoes its environment into the
# build log, as a careless easyblock might.
EB = r'''
eb() {
    python3 - "$@" <<'PY'
import json, os, sys
root = os.environ["CONTROL_ROOT"]
names = ["SOURCE_TOKEN", "OTHER_TOKEN", "LM_LICENSE_FILE"]
seen = {n: os.environ.get(n) for n in names}
open(os.path.join(root, "eb.json"), "w").write(json.dumps({"argv": sys.argv[1:], "secrets": seen}))
log = os.path.join(os.environ["EASYBUILD_TMP_LOGDIR"], "easybuild-test.log")
open(log, "w").write("".join(f"{n}={v}\n" for n, v in seen.items()))
PY
}
export -f eb
'''


@unittest.skipUnless(binary.BIN, "configuration files and secrets are features of the Zig build")
class ConfigCli(StorageFixture):
    def setUp(self):
        super().setUp()
        self.home = self.root / "home"
        (self.home / ".config" / "eb-local").mkdir(parents=True)
        self.token = self.home / "token"
        self.token.write_text("file-secret-value\n")
        self.token.chmod(0o600)
        self.site = self.root / "site.toml"
        self.site.write_text(SITE.format(nodes=self.nodes))
        self.site.chmod(0o644)
        self.user = self.home / ".config" / "eb-local" / "config.toml"
        self.user.write_text(USER.format(token=self.token))
        self.user.chmod(0o600)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        (self.bin / "nimvault").write_text(NIMVAULT)
        (self.bin / "nimvault").chmod(0o755)
        self.env.update(EB_LOCAL_CONFIG="", HOME=str(self.home), MY_OTHER="env-secret-value",
                        PATH=f"{self.bin}:{os.environ['PATH']}")
        self.env.pop("XDG_CONFIG_HOME", None)
        with open(self.root / "doubles.sh", "a") as handle:
            handle.write(EB)

    def run_tool(self, args, **extra):
        # The site file is named with --config, which (as in 1.x) replaces the
        # user file; the user file alone is found through HOME.
        argv, env = binary.command(self.script, args, dict(self.env, **extra))
        return subprocess.run(argv, env=env, cwd=self.root, capture_output=True, text=True)

    def test_config_shows_each_value_and_where_it_came_from(self):
        run = self.run_tool(["config"])
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertIn("profile                      mine", run.stdout)
        self.assertRegex(run.stdout, r"dev\.modules\s+FFTW/3\.3\.10-GCC-15\.2\.0\s+\[user profile mine, .*config\.toml:5\]")
        self.assertIn("SOURCE_TOKEN", run.stdout)
        self.assertNotIn("file-secret-value", run.stdout + run.stderr)

    def test_config_check_reads_secrets_without_showing_them(self):
        run = self.run_tool(["config", "--check", "--profile", "licensed"])
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertEqual(run.stdout.count("   ok"), 3, run.stdout)
        for value in ("file-secret-value", "env-secret-value", "27000@licence.example"):
            self.assertNotIn(value, run.stdout + run.stderr)
        self.token.chmod(0o644)
        run = self.run_tool(["config", "--check"])
        self.assertEqual(run.returncode, 1)
        self.assertIn("chmod 600", run.stdout)

    def test_the_environment_and_options_win(self):
        run = self.run_tool(["dev"], EB_LOCAL_DEV_MODULES="GSL/2.8-GCC-15.2.0", SLURM_JOB_ID="")
        self.assertIn("module load GSL/2.8-GCC-15.2.0\n", run.stdout)
        run = self.run_tool(["dev", "--profile", "mine", "--buildenv", "buildenv/mine"], SLURM_JOB_ID="")
        self.assertIn("module load FFTW/3.3.10-GCC-15.2.0\n", run.stdout)
        self.assertTrue(run.stdout.endswith("module load buildenv/mine\n"), run.stdout)

    def test_profiles_lists_every_profile(self):
        run = self.run_tool(["profiles"])
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertIn("mine", run.stdout)
        self.assertIn("licensed", run.stdout)

    def test_a_build_gets_its_secrets_and_its_log_does_not_keep_them(self):
        self.user.write_text(USER.format(token=self.token).replace(
            "[profile.licensed.secrets]", "[profile.licensed.secrets]"))
        # The storage settings come from the site layer: name it explicitly.
        self.site.write_text(SITE.format(nodes=self.nodes))
        argv, env = binary.command(self.script, ["--config", str(self.site), "--profile", "gpu", "recipe.eb"], dict(self.env))
        # --config replaces the user file, so give the secrets in the site file.
        with open(self.site, "a") as handle:
            handle.write(f'[secrets]\nSOURCE_TOKEN = "file:{self.token}"\nOTHER_TOKEN = "env:MY_OTHER"\n'
                         'LM_LICENSE_FILE = "nimvault:licences/flexlm"\n')
        run = subprocess.run(argv, env=env, cwd=self.root, capture_output=True, text=True)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        seen = json.loads((self.root / "eb.json").read_text())["secrets"]
        self.assertEqual(seen, {"SOURCE_TOKEN": "file-secret-value", "OTHER_TOKEN": "env-secret-value",
                                "LM_LICENSE_FILE": "27000@licence.example"})
        log = self.prefix / ".eb-local" / "logs" / "easybuild-test.log"
        text = log.read_text()
        for value in seen.values():
            self.assertNotIn(value, text)
        self.assertIn("<secret SOURCE_TOKEN removed by eb-local>", text)
        self.assertIn("removed secret values from 1 log file(s)", run.stdout)
        for value in seen.values():
            self.assertNotIn(value, run.stdout + run.stderr)

    def test_a_missing_secret_stops_the_build_before_anything_is_made(self):
        with open(self.site, "a") as handle:
            handle.write('[secrets]\nGONE = "env:NOT_SET_ANYWHERE"\n')
        run = self.run_tool(["--config", str(self.site), "recipe.eb"])
        self.assertEqual(run.returncode, 2, run.stdout + run.stderr)
        self.assertIn("NOT_SET_ANYWHERE is not set", run.stderr)
        self.assertEqual(list(self.job.iterdir()), [])
        self.assertFalse((self.root / "eb.json").exists())

    def test_refusals(self):
        cases = {
            'TOKEN = "hunter2"\n': "never written",
            'colour = "blue"\n': "unknown key colour",
            '[storage]\nnode_local_root = "/tmp"\n': "site setting",
            '[secrets]\nLD_PRELOAD = "env:X"\n': "not a variable name",
            '[profile.p]\nstack.module = "EESSI;id"\n': "not a module name",
        }
        for text, needle in cases.items():
            with self.subTest(text=text):
                body = text if not text.startswith("TOKEN") else "[secrets]\n" + text
                self.user.write_text(body)
                run = self.run_tool(["env"], SLURM_JOB_ID="")
                self.assertEqual(run.returncode, 2, run.stdout)
                self.assertEqual(run.stdout, "")
                self.assertIn(needle, run.stderr)
        self.user.write_text("")
        self.user.chmod(0o620)
        run = self.run_tool(["env"])
        self.assertEqual(run.returncode, 2)
        self.assertIn("writable by group or others", run.stderr)


if __name__ == "__main__":
    unittest.main()
