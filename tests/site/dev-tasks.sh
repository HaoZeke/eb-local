#!/bin/bash
# Site acceptance: the development tasks of the 2025 user documentation, done
# with eb-local on the 2026 stack (EESSI 2026.06 module names).
#
#   EB_LOCAL_TEST_ROOT=DIR [EB_LOCAL_BIN=eb-local] bash tests/site/dev-tasks.sh
#
# DIR holds eb-local.conf (the site configuration) and receives eessi/ and
# work/; remove it afterwards. Each task runs in a fresh subshell from a purged
# module environment. Every program is then run with env -i (no modules, no
# LD_LIBRARY_PATH), and its run path must point into EESSI, so a pass cannot
# come from host libraries. Needs network access for pip and CRAN.
set -o pipefail
T=${EB_LOCAL_TEST_ROOT:?set EB_LOCAL_TEST_ROOT to a scratch directory}
EL=${EB_LOCAL_BIN:-$(dirname "$(readlink -f "$0")")/../../eb-local}
export EB_LOCAL_CONFIG=$T/eb-local.conf EB_LOCAL_PREFIX=$T/eessi
W=$T/work
rm -rf "$W"; mkdir -p "$W"
pass=0; fail=0
bare() { env -i HOME="$HOME" PATH=/usr/bin:/bin "$@"; }
eessi_runpath() { readelf -d "$1" | grep -E 'RPATH|RUNPATH' | grep -q "/cvmfs/software.eessi.io/.*/$2/"; }
from_eessi() { case "$(command -v "$1")" in /cvmfs/*) ;; *) echo "$1 is $(command -v "$1"), not EESSI's"; return 1;; esac; }
task() {
    local name="$1"; shift
    if ( set -e; module purge >/dev/null 2>&1; unset LD_LIBRARY_PATH; "$@" ) > "$W/$name.log" 2>&1; then
        echo "PASS $name"; pass=$((pass+1))
    else
        echo "FAIL $name (see $W/$name.log)"; tail -5 "$W/$name.log" | sed 's/^/    /'; fail=$((fail+1))
    fi
}

t_env() {
    eval "$($EL env)"
    module is-loaded EESSI/2026.06
    [ -n "$EESSI_SOFTWARE_SUBDIR" ]
    [ "$(readlink -m "$EESSI_USER_INSTALL")" = "$(readlink -m "$EB_LOCAL_PREFIX")" ]
}

t_fftw_openmp() {
    eval "$($EL dev FFTW/3.3.10-GCC-15.2.0)"
    module is-loaded buildenv/default-foss-2026.1
    cd "$W"
    cat > fft.c <<'EOF'
#include <fftw3.h>
#include <omp.h>
#include <stdio.h>
int main(void) {
    int n = 8; double in[8]; fftw_complex out[5];
    for (int i = 0; i < n; i++) in[i] = i;
    fftw_plan p = fftw_plan_dft_r2c_1d(n, in, out, FFTW_ESTIMATE);
    fftw_execute(p);
    printf("dc=%g threads=%d\n", out[0][0], omp_get_max_threads());
    fftw_destroy_plan(p);
    return out[0][0] == 28.0 ? 0 : 1;
}
EOF
    gcc -O2 -fopenmp fft.c -lfftw3 -o fft
    eessi_runpath fft FFTW
    bare ./fft
}

t_mpi() {
    eval "$($EL dev)"
    from_eessi mpicc
    cd "$W"
    cat > mpi.c <<'EOF'
#include <mpi.h>
#include <stdio.h>
int main(int c, char **v) { int r; MPI_Init(&c, &v); MPI_Comm_rank(MPI_COMM_WORLD, &r); printf("rank %d\n", r); MPI_Finalize(); return 0; }
EOF
    mpicc -O2 mpi.c -o mpi
    eessi_runpath mpi OpenMPI
    ! bare ldd ./mpi | grep 'not found'
}

t_cmake_gsl() {
    eval "$($EL dev GSL/2.8-GCC-15.2.0 CMake/3.31.11-GCCcore-15.2.0)"
    from_eessi cmake
    mkdir -p "$W/gsl-src" && cd "$W/gsl-src"
    cat > CMakeLists.txt <<'EOF'
cmake_minimum_required(VERSION 3.20)
project(bessel C)
find_package(GSL REQUIRED)
add_executable(bessel bessel.c)
target_link_libraries(bessel GSL::gsl)
install(TARGETS bessel)
EOF
    cat > bessel.c <<'EOF'
#include <gsl/gsl_sf_bessel.h>
#include <stdio.h>
int main(void) { double y = gsl_sf_bessel_J0(5.0); printf("J0(5) = %.6f\n", y); return y < -0.17 && y > -0.18 ? 0 : 1; }
EOF
    cmake -S . -B build -DCMAKE_INSTALL_PREFIX="$W/gsl-install"
    cmake --build build
    cmake --install build
    eessi_runpath "$W/gsl-install/bin/bessel" GSL
    bare "$W/gsl-install/bin/bessel"
}

t_python_venv() {
    eval "$($EL dev Python/3.14.2-GCCcore-15.2.0)"
    from_eessi python
    python -m venv "$W/venv"
    "$W/venv/bin/pip" install --quiet --no-cache-dir --no-binary msgpack msgpack
    bare "$W/venv/bin/python" -c 'import msgpack; assert msgpack.unpackb(msgpack.packb([1, 2])) == [1, 2]; print("msgpack", msgpack.version)'
}

t_r_package() {
    eval "$($EL dev R/4.6.1-gfbf-2026.1)"
    from_eessi Rscript
    mkdir -p "$W/rlib"
    Rscript -e "install.packages('digest', lib='$W/rlib', repos='https://cloud.r-project.org', quiet=TRUE)"
    R_LIBS="$W/rlib" Rscript -e 'library(digest); stopifnot(digest("a", algo="md5", serialize=FALSE) == "0cc175b9c0f1b6a831c399e269772661"); cat("digest ok\n")'
}

t_refusal() {
    ! $EL dev 'GSL;touch /tmp/eb-local-injected' > "$W/refused.out" 2>&1
    [ ! -e /tmp/eb-local-injected ]
    grep -q 'is not a module name' "$W/refused.out"
}

task env t_env
task fftw-openmp t_fftw_openmp
task mpi t_mpi
task cmake-gsl t_cmake_gsl
task python-venv t_python_venv
task r-package t_r_package
task refusal t_refusal
echo "passed $pass, failed $fail"
[ "$fail" -eq 0 ]
