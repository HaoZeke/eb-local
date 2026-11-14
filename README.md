<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="branding/logo/logo-dark.svg">
    <img src="branding/logo/logo-light.svg" alt="eb-local" width="420">
  </picture>
</p>

# eb-local

<!-- docs:start -->
Build your own code and install software on top of [EESSI](https://www.eessi.io) (the European Environment for Scientific Software Installations) 2026.06, without knowing EasyBuild's RPATH wrappers, `buildenv` or `LD_LIBRARY_PATH`.

Documentation: <https://stackhands.github.io/eb-local/>

## Compile your own code

```sh
eval "$(eb-local dev FFTW/3.3.10-GCC-15.2.0)"
gcc -O2 -fopenmp prog.c -lfftw3 -o prog
./prog                      # runs in a new shell or a job, with no modules loaded
```

`eb-local dev` loads EESSI, the modules you name, and a build environment last, so `gcc`, `mpicc`, `make`, CMake and meson record where each library lives.
The program then runs without `LD_LIBRARY_PATH`; do not set it, because it can mix the host's libraries into EESSI's.
Load the modules you link against on the `dev` line, not after it.

These were checked on Snellius with EESSI 2026.06, each program then run with no modules at all:

| task | the line before building |
|---|---|
| C with FFTW and OpenMP | `eval "$(eb-local dev FFTW/3.3.10-GCC-15.2.0)"` |
| MPI | `eval "$(eb-local dev)"`, then `mpicc` |
| CMake against GSL | `eval "$(eb-local dev GSL/2.8-GCC-15.2.0 CMake/3.31.11-GCCcore-15.2.0)"` |
| a Python venv, with packages that compile C | `eval "$(eb-local dev Python/3.14.2-GCCcore-15.2.0)"`, then `python -m venv` and `pip install` |
| R packages into your own library | `eval "$(eb-local dev R/4.6.1-gfbf-2026.1)"`, then `install.packages(..., lib=...)` and `R_LIBS` |

Load EESSI on the node type that will run the program: it picks the binaries for the CPU it finds when it loads.

## Install software with EasyBuild

Build inside a Slurm allocation on the node type that will run the software, because EasyBuild targets the CPU of the node it runs on:

```sh
salloc -p <partition> -n 16 -t 02:00:00   # on nodes with a node-local disk
eb-local GSL-2.8-GCC-15.2.0.eb --robot
```

To use what you installed in a new shell or job:

```sh
eval "$(eb-local env)"
module avail
```

For a group install, the project owner creates the directory once with the project group and the setgid bit:

```sh
mkdir -p /path/to/project/eessi && chgrp myproj /path/to/project/eessi && chmod 2770 /path/to/project/eessi
eb-local --project /path/to/project/eessi GSL-2.8-GCC-15.2.0.eb --robot
```

A successful build removes its workspace; a failed one keeps it for inspection until the allocation ends.

## Where things go

| what | where |
|---|---|
| installs | `$HOME/.local/eessi`, the `prefix` setting, or `--project DIR` |
| build, temporary, cache and EESSI setup directories | a unique workspace in the allocation's node-local mount |
| downloaded source archives | `<install-prefix>/.eb-local/sources` |
| build logs | `<install-prefix>/.eb-local/logs` |

A build needs a Slurm allocation whose node-local directory is its own mount, of the configured file system type, owned by you.
Shared parallel-file-system paths, tmpfs, enclosing mounts and symbolic-link aliases are refused before anything is created.

## Clean up

```sh
eb-local clean --dry-run            # what would go
eb-local clean                      # logs older than 30 days, to the trash with rtrash
eb-local clean --sources            # downloaded archives too
eb-local clean --workspaces --no-logs   # inside an allocation: its leftover workspaces
```

With [rtrash](https://github.com/HaoZeke/rtrash) on `PATH`, files go to the trash (`rtrash list`, `rtrash restore`); without it, nothing is deleted unless you pass `--delete`.
`clean` never follows a symbolic link out of the installation directory.

To remove something you installed, for every CPU target you built it for:

```sh
eb-local uninstall pigz/2.8-GCCcore-15.2.0 --dry-run
eb-local uninstall pigz/2.8-GCCcore-15.2.0      # to the trash with rtrash, or --delete
```

EasyBuild leaves installations read-only, so `rm -rf` fails on them; `uninstall` makes them writable first, and removes the module files with them.

## Configuration

Settings come from, lowest first: built-in defaults, the site file, a site profile, your file, your profile, `EB_LOCAL_*` variables, options.
`eb-local config` prints every setting and where it came from; `eb-local profiles` lists the profiles.

```toml
# ~/.config/eb-local/config.toml
default_profile = "mine"

[profile.mine]
dev.modules = ["FFTW/3.3.10-GCC-15.2.0"]

[profile.group]
project = "/projects/0/myproj/eessi"

[profile.gpu]
dev.modules = ["CUDA/13.3.0"]
```

`eb-local --profile gpu dev` or `EB_LOCAL_PROFILE=gpu` selects a profile.
The keys are `prefix`, `project`, `stack.module`, `stack.extend`, `dev.buildenv`, `dev.modules`, `build.allocation_hint`, `clean.trash` (`auto`, `rtrash` or `none`), `clean.logs_older_than_days` and `[secrets]`; the variables are `EB_LOCAL_PREFIX`, `EB_LOCAL_PROJECT`, `EB_LOCAL_STACK_MODULE`, `EB_LOCAL_STACK_EXTEND`, `EB_LOCAL_DEV_BUILDENV`, `EB_LOCAL_DEV_MODULES`, `EB_LOCAL_BUILD_ALLOCATION_HINT`, `EB_LOCAL_CLEAN_TRASH` and `EB_LOCAL_CLEAN_LOGS_OLDER_THAN_DAYS`.
An unknown key, a wrong type, a duplicate key or an unsafe module name is an error naming its file and line, in every profile, selected or not.

The site file (`/etc/eb-local/config.toml`, or `config.toml` beside the program) also holds the storage settings, which only it may set:

```toml
[storage]
node_local_root = "/scratch-node"        # allocation mounts are <root>/<user>.<job id>
node_local_fstype = "xfs"
shared_scratch = ["/scratch-shared", "/gpfs/scratch1"]

[build]
allocation_hint = "salloc -p rome -n 16 -t 02:00:00 --constraint=scratch-node"
```

A configuration file is used only when it is a regular file, not a symbolic link, not writable by group or others, and owned by root, the program's owner or you (a site file) or by you (your file); otherwise eb-local stops.
A 1.x `eb-local.conf` is read as before.

## Secrets

A build that needs a credential, such as a licence server or a token for a private source mirror, names where it comes from; the value is never written in a configuration file:

```toml
[secrets]
LM_LICENSE_FILE = "nimvault:licences/flexlm"   # nimvault get licences/flexlm
SOURCE_TOKEN = "file:~/.secrets/source-token"   # your file, mode 600
MIRROR_PASSWORD = "env:MY_MIRROR_PASSWORD"
```

- Values are read only for a build, after every other check, and go only into the environment of `eb` and what it runs.
- `eb-local config --check` reads each secret and reports `ok` or why not, never the value.
- After the build, the logs written during it (in `.eb-local/logs` and each installation's `easybuild/`) have each value, and its base64 and percent-encoded forms, replaced with `<secret NAME removed by eb-local>`; the log directory is private meanwhile. A value shorter than 4 bytes, or a log that is too large or too deep to check, is reported instead. A secret reaches every program the build runs, and a build killed before it ends leaves its logs unchecked.
- A secret cannot set `PATH`, `LD_*`, `EESSI_*`, `EASYBUILD_*` or another variable the build depends on.
- [nimvault](https://github.com/HaoZeke/nimvault) runs with a 30-second deadline; on failure eb-local shows its error output, never what it printed as the value.

## Install

The static binary, one file per architecture, from a [release](https://github.com/stackhands/eb-local/releases), or `zig build --release=safe` with Zig 0.17.1.
The Bash script (`eb-local`, 1.x) needs GNU coreutils, util-linux `findmnt`, Lmod and an EESSI 2026.06 mount, and has no configuration files, profiles or secrets.
A site's easyconfig installs the program and its site configuration.

## Test

```sh
python3 -m unittest discover -s tests                    # the Bash script
zig build unit && zig build -Dtest-ops=true test          # the Zig build: unit tests, then the same suite
```

`tests/site/` holds the acceptance scripts run on Snellius: the development tasks above, and a build inside an allocation.

## License

MIT, see [LICENSE](https://github.com/stackhands/eb-local/blob/main/LICENSE).

<!-- stackhands:begin -->
## Part of stackhands

eb-local is one of the [stackhands](https://github.com/stackhands) tools for building, installing and maintaining an HPC software stack with EasyBuild on top of EESSI.

| Tool | Job | Docs |
|---|---|---|
| [eb-stack](https://github.com/stackhands/eb-stack) | Solve, shard and plan an EasyBuild build list; admit builds under a scratch inode budget | [docs](https://eb-stack.rgoswami.me/) |
| [eb-staged-rebuild](https://github.com/stackhands/eb-staged-rebuild) | Rebuild an installation in a staged tree and swap it in, so running jobs keep their paths | [docs](https://stackhands.github.io/eb-staged-rebuild/) |
| [eessi-arch-guard](https://github.com/stackhands/eessi-arch-guard) | Reload EESSI in a Slurm task that inherited it for another CPU or GPU | [docs](https://stackhands.github.io/eessi-arch-guard/) |
| **eb-local** | Install software with EasyBuild on top of EESSI into a directory a user or project owns | [docs](https://stackhands.github.io/eb-local/) |
| [eb-keep-logs](https://github.com/stackhands/eb-keep-logs) | Keep a failed build's EasyBuild log and command output; rotate a pipeline's log tree | [docs](https://stackhands.github.io/eb-keep-logs/) |
| [rfc9162](https://github.com/stackhands/rfc9162) | Append-only Merkle logs hashed as RFC 9162, with tiled storage and signed checkpoints | [docs](https://stackhands.github.io/rfc9162/) |
| [zig-common](https://github.com/stackhands/zig-common) | The shared Zig library under the Zig tools: system calls, checked files, child processes | [docs](https://stackhands.github.io/zig-common/) |
<!-- stackhands:end -->
