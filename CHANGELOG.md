# Changelog

## 2.1.2

* `uninstall` with rtrash passes `-r`: `rtrash put` follows rm(1) and
  refused the installation directories, so 2.1.1 trashed the module files
  and left the installations. Installations now go first, in their own
  call, so a refusal leaves every module file in place. Found by running
  against rtrash 0.1.4 on Snellius; the test double now refuses a
  directory without `-r` as rtrash does.

## 2.1.1

Fixes from an adversarial review of 2.1.0:

* Only a site file (owned by root or by the account that installed
  eb-local) may set `[storage]`; a file of your own named with `--config`
  or `EB_LOCAL_CONFIG` is a user file, and the site file is always read.
  Shared scratch and node-local trees are compared after resolving symbolic
  links, and the installation's `versions` and `.eb-local` trees must not
  lead onto them.
* Secrets: the log directory is made private (0700) for a build that has
  them; the copy of the log EasyBuild keeps in an installation's
  `easybuild/` is cleaned too; base64 and percent-encoded forms of a value
  are removed with it; a value too short to remove, and a log too large or
  too deep to check, is reported.
* `uninstall` looks only at installations (beside their module files, per
  CPU target), never descends into installed software, and refuses any
  path through a symbolic link.
* The build command keeps the signal dispositions it was started with, so
  `nohup eb-local ...` survives a hangup.
* `clean` checks for rtrash or `--delete` before it removes anything, and
  says how many workspaces it removed.
* Paths are made canonical as `readlink -m` does (`link/..` is the parent
  of the link's target).
* The TOML reader refuses arrays nested more than 32 deep and files of more
  than 10000 keys and items.

## 2.1.0

* `eb-local uninstall NAME/VERSION...`: an installation and its module file,
  for every CPU target under the installation directory, made writable (an
  EasyBuild installation is read-only, so `rm -rf` fails on it) and moved to
  the trash with rtrash, or deleted with `--delete`; `--dry-run` lists them.
  A symbolic link is never followed.

## 2.0.0

eb-local in Zig, one static binary per architecture; the Bash script stays
in the repository as the reference implementation, and the command-line
suite runs against both.

* `eb-local dev [MODULE...]`: the lines that load EESSI, the named modules
  and a build environment last, so `gcc`, `mpicc`, `make`, CMake and meson
  build programs that run without `LD_LIBRARY_PATH`. Checked on Snellius
  for C with FFTW and OpenMP, MPI, CMake against GSL, a Python venv with a
  compiled package, and an R package.
* `eb-local env`: the lines that make your installed modules visible;
  `--env` keeps working. Before the first install the stack is loaded
  alone, because EESSI-extend refuses a missing install directory and Lmod
  then undoes the whole load.
* Layered TOML configuration: the site file, a site profile, your file, your
  profile, `EB_LOCAL_*` variables and options, with `eb-local config`
  showing where each setting came from and `eb-local profiles` listing the
  profiles. Storage settings come only from the site file. Every key, type
  and module name is checked, in every profile, with file and line. A 1.x
  `eb-local.conf` is read as before.
* Secrets from the environment, owner-only files or nimvault, named in the
  configuration and never written in it; read only for a build, passed only
  to `eb`, never printed (`eb-local config --check` reports `ok` or why
  not), and removed from the logs written during the build.
* A successful build removes its node-local workspace; a failed one keeps it
  and says where. `eb-local clean` moves old logs (and, asked, sources) to
  the trash with rtrash, deletes only with `--delete` without it, removes
  an allocation's leftover workspaces, and never follows a symbolic link out
  of the installation directory.
* Output for `eval` is shell-quoted and module names are checked, so it
  means the same whatever the input.
* Documentation: <https://stackhands.github.io/eb-local/>.

## 1.3

* The node-local root and the shared scratch trees come from
  `eb-local.conf`; without a node-local root, a build stops before it
  creates anything.

## 1.2

* The workspace is bound to the current user and allocation.

## 1.1

* The node-local allocation requirement is shown in the build hint; the
  owned installation environment is selected after EESSI-extend is unloaded.

## 1.0

* The first release: build and install with EasyBuild on top of EESSI
  2026.06 into a directory you own, with a project mode and `--env`.
