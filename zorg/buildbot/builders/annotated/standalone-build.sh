#!/bin/bash

# This script builds LLVM and Clang in standalone mode that means it first
# builds LLVM and installs it into a specific directory. That directory is then
# used when building Clang which depends on it.

# Enable Error tracing
set -o errtrace

# Print trace for all commands ran before execution
set -x

# Include the Buildbot helper functions
HERE="$(realpath $(dirname $0))"
. ${HERE}/buildbot-helper.sh

# Ensure all commands pass, and not dereferencing unset variables.
set -eu
halt_on_failure

BUILDBOT_ROOT=${BUILDBOT_ROOT:-${HERE}}
REVISION="${BUILDBOT_REVISION:-origin/main}"
LLVM_ROOT="${BUILDBOT_ROOT}/llvm-project"
BUILD_TYPE=Release
INSTALL_ROOT_DIR=${BUILDBOT_ROOT}/install
BUILD_ROOT_DIR=${BUILDBOT_ROOT}/build

# Enable CMake tracing during configure per component
CMAKE_TRACE_CONFIGURE_LLVM=${CMAKE_TRACE_CONFIGURE_LLVM:-}
CMAKE_TRACE_CONFIGURE_CLANG=${CMAKE_TRACE_CONFIGURE_CLANG:-}
CMAKE_TRACE_CONFIGURE_LLD=${CMAKE_TRACE_CONFIGURE_LLD:-}

# Turn CMake's verbose mode for build, check and install steps per component
CMAKE_VERBOSE_LLVM=${CMAKE_VERBOSE_LLVM:-}
CMAKE_VERBOSE_CLANG=${CMAKE_VERBOSE_CLANG:-}
CMAKE_VERBOSE_LLD=${CMAKE_VERBOSE_LLD:-}

# Enable CMake verbose-mode during building
CMAKE_VERBOSE_BUILD_LLVM=${CMAKE_VERBOSE_BUILD_LLVM:-${CMAKE_VERBOSE_LLVM}}
CMAKE_VERBOSE_BUILD_CLANG=${CMAKE_VERBOSE_BUILD_CLANG:-${CMAKE_VERBOSE_CLANG}}
CMAKE_VERBOSE_BUILD_LLD=${CMAKE_VERBOSE_BUILD_LLD:-${CMAKE_VERBOSE_LLD}}

# Enable CMake verbose-mode during checking
CMAKE_VERBOSE_CHECK_LLVM=${CMAKE_VERBOSE_CHECK_LLVM:-${CMAKE_VERBOSE_LLVM}}
CMAKE_VERBOSE_CHECK_CLANG=${CMAKE_VERBOSE_CHECK_CLANG:-${CMAKE_VERBOSE_CLANG}}
CMAKE_VERBOSE_CHECK_LLD=${CMAKE_VERBOSE_CHECK_LLD:-${CMAKE_VERBOSE_LLD}}

# Enable CMake verbose-mode during installation
CMAKE_VERBOSE_INSTALL_LLVM=${CMAKE_VERBOSE_INSTALL_LLVM:-${CMAKE_VERBOSE_LLVM}}
CMAKE_VERBOSE_INSTALL_CLANG=${CMAKE_VERBOSE_INSTALL_CLANG:-${CMAKE_VERBOSE_CLANG}}
CMAKE_VERBOSE_INSTALL_LLD=${CMAKE_VERBOSE_INSTALL_LLD:-${CMAKE_VERBOSE_LLD}}

install_dir() {
    echo ${INSTALL_ROOT_DIR}/$1
}

build_dir() {
    echo ${BUILD_ROOT_DIR}/$1
}

setup_llvm_project() {
    build_step "Setup llvm-project"

    if [ ! -d "${LLVM_ROOT}" ]; then
      build_step "Cloning llvm-project repo"
      git clone --progress https://github.com/llvm/llvm-project.git ${LLVM_ROOT}
    fi

    build_step "Updating llvm-project repo"
    git -C "${LLVM_ROOT}" fetch origin
    git -C "${LLVM_ROOT}" reset --hard "${REVISION}"
    git -C "${LLVM_ROOT}" sparse-checkout init --cone
}

pre_build_cleanup() {
    build_step "Pre-build cleanup"
    rm -rf ${INSTALL_ROOT_DIR}
    rm -rf ${BUILD_ROOT_DIR}
}

build_python_lit() {
    local PYTHON_LIT_BUILD_DIR=$(build_dir python-lit)
    local PYTHON_LIT_INSTALL_DIR=$(install_dir python-lit)
    
    build_step "Sparse checkout out python-lit"
    git -C "${LLVM_ROOT}" sparse-checkout set llvm/utils/lit

    build_step "Building python-lit"
    cd "${LLVM_ROOT}"/llvm/utils/lit
    python3 setup.py build '--executable=/usr/bin/python3 -s'

    # TODO(kkleine): Fix failing test: FAIL: lit :: shtest-not.py (43 of 50)
    #build_step "Testing python-lit"
    #python3 lit.py tests

    build_step "Installing python-lit"
    rm -rf ${PYTHON_LIT_INSTALL_DIR}
    python3 setup.py install -O1 --skip-build --root ${PYTHON_LIT_INSTALL_DIR}
    
    build_step "Removing python-lit build dir"
    rm -rf ${PYTHON_LIT_BUILD_DIR}

    cd -
}

# We don't install python to the system so we need help python to find it
discover_python_lit() {
    build_step "Help discover python-lit module"
    local PYTHON_LIT_INSTALL_DIR=$(install_dir python-lit)
    local pyver=$(echo 'import sys; print("{}.{}".format(sys.version_info.major, sys.version_info.minor))' | python3)
    export PYTHONPATH="${PYTHONPATH:-}:${PYTHON_LIT_INSTALL_DIR}/usr/local/lib/python${pyver}/site-packages"
}

build_llvm() {
    local PYTHON_LIT_INSTALL_DIR=$(install_dir python-lit)
    local LLVM_BUILD_DIR=$(build_dir llvm)
    local LLVM_INSTALL_DIR=$(install_dir llvm)

    build_step "Sparse checkout out llvm"
    git -C "${LLVM_ROOT}" sparse-checkout set llvm cmake third-party

    build_step "Configuring llvm"

    cmake ${CMAKE_TRACE_CONFIGURE_LLVM} \
        -S ${LLVM_ROOT}/llvm \
        -B ${LLVM_BUILD_DIR} \
        -G Ninja \
        -DCMAKE_BUILD_TYPE=${BUILD_TYPE} \
        -DLLVM_BUILD_LLVM_DYLIB=ON \
        -DLLVM_LINK_LLVM_DYLIB=ON \
        -DLLVM_INCLUDE_BENCHMARKS=OFF \
        -DLLVM_INSTALL_UTILS=ON \
        -DCMAKE_INSTALL_PREFIX=${LLVM_INSTALL_DIR} \
        -DLLVM_EXTERNAL_LIT=${PYTHON_LIT_INSTALL_DIR}/usr/local/bin/lit \
        -DLLVM_INCLUDE_UTILS:BOOL=ON \
        -DLLVM_INSTALL_UTILS:BOOL=ON \
        -DLLVM_UTILS_INSTALL_DIR:PATH=${LLVM_INSTALL_DIR}/bin \
        -DLLVM_CCACHE_BUILD=ON

    build_step "Building llvm"
    cmake --build ${LLVM_BUILD_DIR} ${CMAKE_VERBOSE_BUILD_LLVM}
    
    build_step "Testing llvm"
    LD_LIBRARY_PATH="${LLVM_INSTALL_DIR}/lib64" cmake --build ${LLVM_BUILD_DIR} --target check-all ${CMAKE_VERBOSE_CHECK_LLVM} 

    build_step "Installing llvm"
    rm -rf ${LLVM_INSTALL_DIR}
    cmake --install ${LLVM_BUILD_DIR} ${CMAKE_VERBOSE_INSTALL_LLVM}

    # This is meant to extinguish any dependency on files being taken
    # from the llvm build dir when building clang.
    build_step "Removing llvm build dir"
    rm -rf "${LLVM_BUILD_DIR}"
}

build_clang() {
    local PYTHON_LIT_INSTALL_DIR=$(install_dir python-lit)
    local LLVM_INSTALL_DIR=$(install_dir llvm)
    local CLANG_BUILD_DIR=$(build_dir clang)
    local CLANG_INSTALL_DIR=$(install_dir clang)

    build_step "Sparse checkout out clang"
    git -C "${LLVM_ROOT}" sparse-checkout set clang cmake

    build_step "Configuring clang"
    cmake ${CMAKE_TRACE_CONFIGURE_CLANG} \
        -S ${LLVM_ROOT}/clang \
        -B ${CLANG_BUILD_DIR} \
        -G Ninja \
        -DCMAKE_BUILD_TYPE=${BUILD_TYPE} \
        -DCLANG_LINK_CLANG_DYLIB=ON \
        -DCLANG_INCLUDE_TESTS=ON \
        -DLLVM_EXTERNAL_LIT=${PYTHON_LIT_INSTALL_DIR}/usr/local/bin/lit \
        -DCMAKE_INSTALL_PREFIX=${CLANG_INSTALL_DIR} \
        -DLLVM_ROOT=${LLVM_INSTALL_DIR} \
        -DLLVM_ENABLE_ASSERTIONS=ON \
        -DLLVM_TABLEGEN_EXE=${LLVM_INSTALL_DIR}/bin/llvm-tblgen \
        -DLLVM_CCACHE_BUILD=ON

    build_step "Building clang"
    LD_LIBRARY_PATH="${LLVM_INSTALL_DIR}/lib64" cmake --build ${CLANG_BUILD_DIR} ${CMAKE_VERBOSE_BUILD_CLANG}

    # TODO(kwk): Add Clang check

    build_step "Installing clang"
    rm -rf ${CLANG_INSTALL_DIR}
    cmake --install ${CLANG_BUILD_DIR} ${CMAKE_VERBOSE_INSTALL_CLANG}

    build_step "Removing clang build dir"
    rm -rf ${CLANG_BUILD_DIR}
}

build_lld() {
    local LLVM_INSTALL_DIR=$(install_dir llvm)
    local PYTHON_LIT_INSTALL_DIR=$(install_dir python-lit)
    local LLD_BUILD_DIR=$(build_dir lld)
    local LLD_INSTALL_DIR=$(install_dir lld)

    build_step "Sparse checkout out lld"
    git -C "${LLVM_ROOT}" sparse-checkout set lld cmake libunwind
    
    # We don't want to checkout the llvm source tree but sadly there are paths
    # like ${LLVM_MAIN_SRC_DIR}/../libunwind/include in lld source code. They
    # resolve to /<SOMEPATH>/../llvm/../libunwind/include which makes absolutely
    # no sense when the llvm dir doesn't exist. Let's fix this by just providing
    # the empty llvm dir so that paths are resolved without errors.
    # TODO: I don't know how to fix this easily
    rm -rf "${LLVM_ROOT}"/llvm && mkdir "${LLVM_ROOT}"/llvm
    rm -rf ${LLD_INSTALL_DIR}
    rm -rf ${LLD_BUILD_DIR}

    build_step "Configuring lld"
    cmake ${CMAKE_TRACE_CONFIGURE_LLD} \
        -S ${LLVM_ROOT}/lld \
        -B ${LLD_BUILD_DIR} \
        -G Ninja \
        -DCMAKE_BUILD_TYPE=${BUILD_TYPE} \
        -DLLVM_LINK_LLVM_DYLIB=ON \
        -DCMAKE_INSTALL_PREFIX=${LLD_INSTALL_DIR} \
        -DLLVM_ROOT=${LLVM_INSTALL_DIR} \
        -DLLVM_CCACHE_BUILD=ON \
        -DLLVM_INCLUDE_TESTS=ON \
        -DLLVM_EXTERNAL_LIT=${PYTHON_LIT_INSTALL_DIR}/usr/local/bin/lit

    build_step "Building lld"
    LD_LIBRARY_PATH="${LLVM_INSTALL_DIR}/lib64" cmake --build ${LLD_BUILD_DIR} ${CMAKE_VERBOSE_BUILD_LLD}

    build_step "Testing lld"
    LD_LIBRARY_PATH="${LLVM_INSTALL_DIR}/lib64" cmake --build ${LLD_BUILD_DIR} --target check-lld ${CMAKE_VERBOSE_CHECK_LLD}

    build_step "Installing lld"
    rm -rf ${LLD_INSTALL_DIR}
    cmake --install ${LLD_BUILD_DIR} ${CMAKE_VERBOSE_INSTALL_LLD}

    build_step "Removing lld build dir"
    rm -rf ${LLD_BUILD_DIR}
}

setup_llvm_project
pre_build_cleanup

build_python_lit
discover_python_lit
build_llvm
build_clang
build_lld

exit 0

