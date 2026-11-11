#!/usr/bin/env python3
"""Behavioral checks for the environment eb-local selects.

The module and eb doubles verify wrapper routing and argument preservation.
They do not establish the destination chosen by a native EESSI extension.
"""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "eb-local"
CLEAR = (
    "EESSI_CVMFS_INSTALL", "EESSI_SITE_INSTALL", "EESSI_USER_INSTALL", "EESSI_PROJECT_INSTALL",
    "EESSI_SITE_SOFTWARE_PREFIX", "EESSI_SOFTWARE_SUBDIR_OVERRIDE",
    "EESSI_ACCELERATOR_TARGET_OVERRIDE", "EESSI_OVERRIDE_GPU_CHECK",
    "EASYBUILD_INSTALLPATH", "EASYBUILD_INSTALLPATH_SOFTWARE",
    "EASYBUILD_INSTALLPATH_MODULES", "EASYBUILD_PREFIX",
)
DOUBLE = r'''
module() {
    if [ "$1" = unload ]; then
        # Model values restored when an existing extension is unloaded.
        for name in $CONTROL_CLEAR; do export "$name=restored-by-unload"; done
        return 0
    fi
    if [ "$1" = load ]; then
        python3 "$CONTROL_ROOT/capture.py" load "$@" || return
        export EESSI_SOFTWARE_SUBDIR=x86_64/amd/zen4
        export EESSI_ACCELERATOR_TARGET=
        export EASYBUILD_HOOKS=/selected/eessi/eb_hooks.py
        return 0
    fi
    return 99
}
eb() {
    python3 "$CONTROL_ROOT/capture.py" eb "$@"
}
# Scope the wrapper's scratch operations to the fixture's filesystem.
mkdir() {
    local rewritten=() arg
    for arg in "$@"; do
        case "$arg" in /scratch-shared/*) arg="$CONTROL_ROOT/scratch${arg#/scratch-shared}";; esac
        rewritten+=("$arg")
    done
    command mkdir "${rewritten[@]}"
}
cd() {
    case "${1-}" in
        /scratch-shared/*) builtin cd "$CONTROL_ROOT/scratch${1#/scratch-shared}";;
        *) builtin cd "$@";;
    esac
}
export -f module eb mkdir cd
'''
CAPTURE = r'''
import json, os, sys
from pathlib import Path
kind = sys.argv[1]
root = Path(os.environ["CONTROL_ROOT"])
names = os.environ["CONTROL_CLEAR"].split()
values = {name: os.environ[name] for name in names if name in os.environ}
if kind == "load":
    expected = {os.environ["CONTROL_MODE"]: os.environ["CONTROL_PREFIX"]}
    if values != expected:
        print("unexpected load environment: " + repr(values), file=sys.stderr)
        sys.exit(96)
    if sys.argv[2:] != ["load", "EESSI/2026.06", "EESSI-extend/2026.06-easybuild"]:
        sys.exit(97)
    (root / "load.json").write_text(json.dumps({"env": values, "argv": sys.argv[2:]}))
else:
    if os.environ.get("EASYBUILD_HOOKS") != "/selected/eessi/eb_hooks.py":
        sys.exit(98)
    (root / "eb.json").write_text(json.dumps({"argv": sys.argv[2:],
                                            "hooks": os.environ["EASYBUILD_HOOKS"]}))
    sys.exit(int(os.environ.get("CONTROL_EB_STATUS", "0")))
'''

class EnvironmentControls(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="controls-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        (self.root / "doubles.sh").write_text(DOUBLE)
        (self.root / "capture.py").write_text(CAPTURE)
        self.prefix = self.root / "owned space 'quote' $(touch injected)"
        self.prefix.mkdir()
        self.env = dict(os.environ, BASH_ENV=str(self.root / "doubles.sh"),
                        CONTROL_ROOT=str(self.root), CONTROL_CLEAR=" ".join(CLEAR),
                        CONTROL_PREFIX=str(self.prefix), CONTROL_MODE="EESSI_USER_INSTALL",
                        EB_LOCAL_PREFIX=str(self.prefix), USER="fixture",
                        SLURM_JOB_ID="123")
        self.env.update({name: "inherited" for name in CLEAR})

    def run_wrapper(self, arguments, **extra):
        return subprocess.run(["bash", str(SCRIPT)] + arguments,
                              env=dict(self.env, **extra), cwd=self.root, text=True, capture_output=True)

    def check_build(self, mode, status=0):
        arguments = ["recipe with spaces.eb", "--robot", "--hooks=/private site/hooks.py",
                     "--include-easyblocks=/public helpers/package.py", "--rebuild"]
        if mode == "EESSI_PROJECT_INSTALL":
            prefix_args = ["--project", str(self.prefix)]
        else:
            prefix_args = []
        run = self.run_wrapper(prefix_args + arguments, CONTROL_MODE=mode, CONTROL_EB_STATUS=str(status))
        self.assertEqual(run.returncode, status, run.stdout + run.stderr)
        self.assertEqual(json.loads((self.root / "eb.json").read_text())["argv"],
                         ["--umask=022"] + arguments)
        self.assertEqual(json.loads((self.root / "load.json").read_text())["env"],
                         {mode: str(self.prefix)})

    def test_user_mode_clears_inherited_and_unload_restored_values(self):
        self.check_build("EESSI_USER_INSTALL")

    def test_project_mode_clears_inherited_and_unload_restored_values(self):
        self.check_build("EESSI_PROJECT_INSTALL")

    def test_eb_failure_exit_is_preserved(self):
        self.check_build("EESSI_USER_INSTALL", status=37)

    def check_environment(self, mode):
        arguments = ["--env"]
        if mode == "EESSI_PROJECT_INSTALL":
            arguments += ["--project", str(self.prefix)]
        run = self.run_wrapper(arguments, CONTROL_MODE=mode)
        self.assertEqual(run.returncode, 0, run.stderr)
        env_script = self.root / "selected-env.sh"
        env_script.write_text(run.stdout)
        replay = subprocess.run(["bash", "-c", 'source "$1"', "environment", str(env_script)],
                                env=dict(self.env, CONTROL_MODE=mode), cwd=self.root, text=True, capture_output=True)
        self.assertEqual(replay.returncode, 0, replay.stdout + replay.stderr)
        self.assertEqual(json.loads((self.root / "load.json").read_text())["env"],
                         {mode: str(self.prefix)})
        self.assertFalse((self.root / "injected").exists())

    def test_user_env_is_shell_safe_and_selects_only_user_mode(self):
        self.check_environment("EESSI_USER_INSTALL")

    def test_project_env_is_shell_safe_and_selects_only_project_mode(self):
        self.check_environment("EESSI_PROJECT_INSTALL")

    def test_project_directory_must_exist(self):
        run = self.run_wrapper(["--project", str(self.root / "absent"), "recipe.eb"])
        self.assertEqual(run.returncode, 2, run.stderr)
        self.assertFalse((self.root / "load.json").exists())

    def test_allocation_is_required(self):
        env = dict(self.env)
        env.pop("SLURM_JOB_ID")
        run = subprocess.run(["bash", str(SCRIPT), "recipe.eb"], env=env, cwd=self.root, text=True, capture_output=True)
        self.assertEqual(run.returncode, 2, run.stderr)
        self.assertFalse((self.root / "load.json").exists())

if __name__ == "__main__":
    unittest.main()
