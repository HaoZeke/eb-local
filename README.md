# eb-local

Install software with EasyBuild on top of [EESSI](https://www.eessi.io) 2026.06, into a directory you own.

`eb-local` sets `EESSI_USER_INSTALL` (or `EESSI_PROJECT_INSTALL`), loads `EESSI/2026.06` and `EESSI-extend/2026.06-easybuild`, and runs `eb`.
EESSI-extend supplies EESSI's hooks, RPATH wrappers and compat layer, so what you build links against the same libraries as the EESSI modules.

## Use

Build inside a Slurm allocation on the node type that will run the software, because EasyBuild targets the CPU of the node it runs on:

```sh
salloc -p <partition> -n 16 -t 02:00:00   # on nodes with a node-local disk
eb-local GSL-2.8-GCC-15.2.0.eb --robot
```

To use the modules in a new shell or job:

```sh
eval "$(eb-local --env)"
module avail
```

For a group install, the project owner creates the directory once with the project group and the setgid bit:

```sh
mkdir -p /path/to/project/eessi && chgrp myproj /path/to/project/eessi && chmod 2770 /path/to/project/eessi
eb-local --project /path/to/project/eessi GSL-2.8-GCC-15.2.0.eb --robot
```

## Where things go

| what | where |
|---|---|
| installs | `$HOME/.local/eessi`, `EB_LOCAL_PREFIX`, or `--project DIR` |
| build, temporary, cache and EESSI setup directories | a unique workspace in the allocation's node-local mount |
| downloaded source archives | `<install-prefix>/.eb-local/sources` |
| build logs | `<install-prefix>/.eb-local/logs` |

Build mode requires a numeric Slurm allocation ID. It derives
the allocation's node-local directory from the actual user identity and
allocation, then requires that owned, writable, canonical directory to be
its own mount of the configured file system type (XFS by default). An inherited shared or nested `TMPDIR` does not select
the build filesystem. Shared parallel-filesystem paths, tmpfs, enclosing mounts and symlink aliases are refused
before the installation prefix is created. There is no shared-scratch fallback.
The scheduler owns the lifetime of the job workspace; sources and logs remain
with the user or project installation. `--help` and `--env` create no directories
and require no allocation.

## Site configuration

The node-local mount and the shared scratch trees differ per site, so they come from `eb-local.conf`.
`eb-local` reads the first of `EB_LOCAL_CONFIG`, `eb-local.conf` beside the resolved script, and `/etc/eb-local.conf` that exists.
The file is parsed, never sourced, and is used only when it is a regular file, not a symlink, not writable by group or others, and owned by root, by the owner of the script, or by the caller.
Without a configured `node_local_root`, build mode stops before it creates anything; `--help` and `--env` need no configuration.

```ini
# eb-local.conf
node_local_root = /local/scratch          # allocation mounts are <root>/<user>.<job id>
node_local_fstype = xfs                   # file system type the allocation mount must have
shared_scratch = /scratch /scratch-shared # refused as installation prefix
allocation_hint = salloc -p <partition> -n 16 -t 02:00:00
```

The node-local root is refused as an installation prefix too. A site's easyconfig installs the file next to the script.

Everything after the options goes to `eb` unchanged, and `eb-local` exits with `eb`'s status.

## Install

`eb-local` is one Bash script using GNU coreutils, util-linux `findmnt`, Lmod and an EESSI 2026.06 mount.
Copy it onto `PATH`, or install it with the matching released easyconfig.

## License

MIT, see [LICENSE](LICENSE).
