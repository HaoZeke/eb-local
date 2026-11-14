"""Exercise storage refusal and workspace routing with controlled mount metadata."""
import json
import os
import pwd
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "eb-local"
MUTABLE = (
    "WORKING_DIR", "TMPDIR", "TMP", "TEMP", "EASYBUILD_BUILDPATH",
    "EASYBUILD_TMPDIR", "XDG_CACHE_HOME", "CARGO_HOME",
)
DURABLE = ("EASYBUILD_SOURCEPATH", "EASYBUILD_TMP_LOGDIR")
DOUBLE = r'''
findmnt() {
    case "$3" in
        FSTYPE) printf '%s\n' "${CONTROL_FSTYPE:-xfs}";;
        TARGET) printf '%s\n' "${CONTROL_MOUNT_TARGET:-$CONTROL_JOB_ROOT}";;
        OPTIONS) printf '%s\n' "${CONTROL_MOUNT_OPTIONS:-rw,relatime}";;
        *) return 99;;
    esac
}
stat() {
    if [ "$*" = "-c %u -- $CONTROL_JOB_ROOT" ] && [ -n "${CONTROL_OWNER:-}" ]; then
        printf '%s\n' "$CONTROL_OWNER"
    else command stat "$@"; fi
}
module() {
    if [ "$1" = unload ]; then
        export TMPDIR=/scratch-shared/restored WORKING_DIR=/scratch-shared/restored
        export EASYBUILD_BUILDPATH=/scratch-shared/restored
        return 0
    fi
    if [ "$1" = load ]; then
        python3 "$CONTROL_ROOT/capture.py" load "$@" || return
        export EESSI_SOFTWARE_SUBDIR=x86_64/amd/zen4 EESSI_ACCELERATOR_TARGET=
        export EASYBUILD_HOOKS=/selected/hooks.py
        export TMPDIR=/scratch-shared/module WORKING_DIR=/scratch-shared/module
        export EASYBUILD_BUILDPATH=/scratch-shared/module
        return 0
    fi
    return 99
}
eb() { python3 "$CONTROL_ROOT/capture.py" eb "$@"; }
export -f findmnt stat module eb
'''
CAPTURE = r'''
import json,os,sys
from pathlib import Path
root=Path(os.environ["CONTROL_ROOT"])
names=os.environ["CONTROL_PATH_NAMES"].split()
result={"paths":{name:os.environ.get(name) for name in names},"argv":sys.argv[2:],
        "user":os.environ.get("EESSI_USER_INSTALL"),
        "project":os.environ.get("EESSI_PROJECT_INSTALL"),
        "hooks":os.environ.get("EASYBUILD_HOOKS")}
(root/(sys.argv[1]+".json")).write_text(json.dumps(result))
if sys.argv[1]=="eb":sys.exit(int(os.environ.get("CONTROL_EB_STATUS","0")))
'''


def write_config(path, nodes, extra=""):
    """A site configuration naming NODES as the node-local root, owned by the caller."""
    path.write_text(
        "# test site\n"
        f"node_local_root = {nodes}\n"
        "node_local_fstype = xfs\n"
        f"shared_scratch = /scratch-shared /scratch-local {nodes.parent / 'shared'}\n"
        "allocation_hint = salloc -n 16 -t 02:00:00\n" + extra
    )
    path.chmod(0o600)


class StorageFixture(unittest.TestCase):
    """The fixture, without tests; test_commands builds on it too."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="eb-local-storage-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.nodes = self.root / "node-mounts"
        self.job = self.nodes / (pwd.getpwuid(os.getuid()).pw_name + ".123")
        self.job.mkdir(parents=True)
        self.prefix = self.root / "durable" / "owned prefix"
        self.script = self.root / "eb-local"
        original = SCRIPT.read_text()
        self.assertNotIn("/scratch-node", original)
        self.script.write_text(original)
        # The site configuration names the mount namespace; probes remain real.
        self.config = self.root / "site.conf"
        write_config(self.config, self.nodes)
        (self.root / "doubles.sh").write_text(DOUBLE)
        (self.root / "capture.py").write_text(CAPTURE)
        self.env = dict(os.environ, BASH_ENV=str(self.root / "doubles.sh"),
                        CONTROL_ROOT=str(self.root), CONTROL_JOB_ROOT=str(self.job),
                        CONTROL_PATH_NAMES=" ".join(MUTABLE + DURABLE),
                        EB_LOCAL_PREFIX=str(self.prefix), SLURM_JOB_ID="123",
                        TMPDIR=str(self.job), EB_LOCAL_CONFIG=str(self.config))
        for name in ("EESSI_USER_INSTALL", "EESSI_PROJECT_INSTALL",
                     "EESSI_SITE_INSTALL", "EESSI_CVMFS_INSTALL"):
            self.env.pop(name, None)

    def run_wrapper(self, args=None, **extra):
        return subprocess.run(["bash", str(self.script)] + (args or ["recipe.eb"]),
                              env=dict(self.env, **extra), cwd=self.root,
                              capture_output=True, text=True)

    def refused(self, **extra):
        run = self.run_wrapper(**extra)
        self.assertEqual(run.returncode, 2, run.stdout + run.stderr)
        self.assertFalse(self.prefix.exists())
        self.assertFalse((self.root / "load.json").exists())
        self.assertEqual(list(self.job.iterdir()), [])


class StorageControls(StorageFixture):
    def test_missing_allocation_creates_no_prefix_or_workspace(self):
        self.refused(SLURM_JOB_ID="")

    def test_invalid_allocation_identity_creates_no_prefix(self):
        self.refused(SLURM_JOB_ID="not-a-job")

    def test_shared_tmpdir_is_refused_before_prefix_creation(self):
        other = self.nodes / "other-job.123"
        self.job.rename(other)
        self.job = other
        self.env["CONTROL_JOB_ROOT"] = str(other)
        self.refused(TMPDIR=str(self.root))

    def test_gpfs_mount_is_refused(self):
        self.refused(CONTROL_FSTYPE="gpfs")

    def test_tmpfs_mount_is_refused(self):
        self.refused(CONTROL_FSTYPE="tmpfs")

    def test_foreign_mount_owner_is_refused(self):
        self.refused(CONTROL_OWNER=str(os.getuid() + 1))

    def test_enclosing_mount_is_refused(self):
        self.refused(CONTROL_MOUNT_TARGET=str(self.nodes))

    def test_read_only_mount_is_refused(self):
        self.refused(CONTROL_MOUNT_OPTIONS="ro,relatime")

    def test_symlink_root_is_refused(self):
        real = self.root / "real-job"
        self.job.rename(real)
        self.job.symlink_to(real, target_is_directory=True)
        self.refused(TMPDIR=str(self.job))

    def test_parent_symlink_escape_is_refused(self):
        real = self.root / "real-node-mounts"
        self.nodes.rename(real)
        self.nodes.symlink_to(real, target_is_directory=True)
        self.refused(TMPDIR=str(self.job))

    def test_build_paths_survive_unload_and_module_initialization(self):
        args = ["recipe with spaces.eb", "--hooks=/selected/custom.py", "--robot"]
        # Kept, so the paths the build used can be inspected afterwards.
        run = self.run_wrapper(args, EB_LOCAL_KEEP_WORK="1")
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        loaded = json.loads((self.root / "load.json").read_text())
        built = json.loads((self.root / "eb.json").read_text())
        for event in (loaded, built):
            for name in MUTABLE:
                path = Path(event["paths"][name])
                self.assertTrue(path.is_relative_to(self.job), (name, path))
                self.assertTrue(path.is_dir(), (name, path))
            for name in DURABLE:
                path = Path(event["paths"][name])
                self.assertTrue(path.is_relative_to(self.prefix))
                self.assertFalse(path.is_relative_to(self.job))
                self.assertTrue(path.is_dir())
        self.assertEqual(loaded["paths"], built["paths"])
        self.assertEqual(built["argv"], ["--umask=022"] + args)
        self.assertEqual(built["user"], str(self.prefix))
        self.assertEqual(built["hooks"], "/selected/hooks.py")

    def test_build_failure_status_is_retained(self):
        run = self.run_wrapper(CONTROL_EB_STATUS="37")
        self.assertEqual(run.returncode, 37, run.stdout + run.stderr)

    def test_help_is_pure_without_allocation(self):
        run = self.run_wrapper(["--help"], SLURM_JOB_ID="", TMPDIR="")
        self.assertEqual(run.returncode, 0)
        self.assertFalse(self.prefix.exists())
        self.assertEqual(list(self.job.iterdir()), [])

    def test_environment_mode_is_pure_without_allocation(self):
        run = self.run_wrapper(["--env"], SLURM_JOB_ID="", TMPDIR="")
        self.assertEqual(run.returncode, 0)
        self.assertIn("EESSI_USER_INSTALL=", run.stdout)
        self.assertFalse(self.prefix.exists())
        self.assertEqual(list(self.job.iterdir()), [])


    def test_alias_inside_mount_namespace_cannot_escape_to_another_directory(self):
        other = self.nodes / "other-allocation"
        self.job.rename(other)
        self.job.symlink_to(other, target_is_directory=True)
        self.refused(TMPDIR=str(self.job))

    def test_durable_sources_cannot_be_redirected_into_job_storage(self):
        (self.prefix / ".eb-local").mkdir(parents=True)
        (self.prefix / ".eb-local" / "sources").symlink_to(self.job, target_is_directory=True)
        run = self.run_wrapper()
        self.assertEqual(run.returncode, 2, run.stdout + run.stderr)
        self.assertFalse((self.root / "load.json").exists())
        self.assertEqual(list(self.job.iterdir()), [])

    def test_missing_configuration_refuses_before_any_write(self):
        self.config.unlink()
        self.refused()

    def test_configuration_without_node_local_root_is_refused(self):
        self.config.write_text("node_local_fstype = xfs\n")
        self.refused()

    def test_group_writable_configuration_is_refused(self):
        self.config.chmod(0o620)
        self.refused()

    def test_symlinked_configuration_is_refused(self):
        real = self.root / "real.conf"
        self.config.rename(real)
        self.config.symlink_to(real)
        self.refused()

    def test_unknown_setting_is_refused(self):
        write_config(self.config, self.nodes, "source_me = $(touch injected)\n")
        self.refused()
        self.assertFalse((self.root / "injected").exists())

    def test_configured_shared_scratch_is_refused_as_prefix(self):
        destination = self.root / "shared" / "install"
        run = self.run_wrapper(EB_LOCAL_PREFIX=str(destination))
        self.assertEqual(run.returncode, 2, run.stdout + run.stderr)
        self.assertFalse(destination.exists())

    def test_configured_fstype_is_enforced(self):
        write_config(self.config, self.nodes, "node_local_fstype = ext4\n")
        self.refused()

    def test_allocation_hint_comes_from_the_configuration(self):
        run = self.run_wrapper(SLURM_JOB_ID="")
        self.assertEqual(run.returncode, 2)
        self.assertIn("salloc -n 16 -t 02:00:00", run.stderr)

    def test_install_prefix_cannot_use_job_storage(self):
        destination = self.job / "install"
        run = self.run_wrapper(EB_LOCAL_PREFIX=str(destination))
        self.assertEqual(run.returncode, 2, run.stdout + run.stderr)
        self.assertFalse(destination.exists())
        self.assertEqual(list(self.job.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
