# eb-local

Install software with EasyBuild on top of [EESSI](https://www.eessi.io) 2026.06, into a directory you own.

`eb-local` sets `EESSI_USER_INSTALL` (or `EESSI_PROJECT_INSTALL`), loads `EESSI/2026.06` and `EESSI-extend/2026.06-easybuild`, and runs `eb`.
EESSI-extend supplies EESSI's hooks, RPATH wrappers and compat layer, so what you build links against the same libraries as the EESSI modules.

## Use

Build inside a Slurm allocation on the node type that will run the software, because EasyBuild targets the CPU of the node it runs on:

```sh
salloc -p rome -n 16 -t 02:00:00
eb-local GSL-2.8-GCC-15.2.0.eb --robot
```

To use the modules in a new shell or job:

```sh
eval "$(eb-local --env)"
module avail
```

For a group install, the project owner creates the directory once with the project group and the setgid bit:

```sh
mkdir -p /projects/myproj/eessi && chgrp myproj /projects/myproj/eessi && chmod 2770 /projects/myproj/eessi
eb-local --project /projects/myproj/eessi GSL-2.8-GCC-15.2.0.eb --robot
```

## Where things go

| what | where |
|---|---|
| installs | `$HOME/.local/eessi`, `EB_LOCAL_PREFIX`, or `--project DIR` |
| builds, temporary files, sources | `/scratch-shared/$USER/eb` |

Everything after the options goes to `eb` unchanged, and `eb-local` exits with `eb`'s status.

## Install

`eb-local` is one Bash script with no dependencies beyond Lmod and an EESSI 2026.06 mount.
Copy it onto `PATH`, or install it with the easyconfig `eb-local-1.1.eb`.

## License

MIT, see [LICENSE](LICENSE).
