# Changelog

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
