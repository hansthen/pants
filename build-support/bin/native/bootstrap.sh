#!/usr/bin/env bash

# Defines:
# + LIB_EXTENSION: The extension of native libraries.
# + KERNEL: The lower-cased name of the kernel as reported by uname.
# + CACHE_ROOT: The pants cache root dir.
# + NATIVE_ENGINE_CACHE_DIR: The directory containing all versions of the native engine for
#                            the current OS.
# + NATIVE_ENGINE_BINARY: The basename of the native engine binary for the current OS.
# + NATIVE_ENGINE_VERSION_RESOURCE: The path of the resource file containing the native engine
#                                   version hash.
# Exposes:
# + calculate_current_hash: Calculates the current native engine version hash and echoes it to
#                           stdout.
# + bootstrap_native_code: Builds native engine binaries.

REPO_ROOT=$(cd $(dirname "${BASH_SOURCE[0]}") && cd ../../.. && pwd -P)
source ${REPO_ROOT}/build-support/common.sh

readonly KERNEL=$(uname -s | tr '[:upper:]' '[:lower:]')
case "${KERNEL}" in
  linux)
    readonly LIB_EXTENSION=so
    ;;
  darwin)
    readonly LIB_EXTENSION=dylib
    ;;
  *)
    die "Unknown kernel ${KERNEL}, cannot bootstrap pants native code!"
    ;;
esac

readonly NATIVE_ROOT="${REPO_ROOT}/src/rust/engine"
readonly NATIVE_ENGINE_BINARY="native_engine.so"
readonly NATIVE_ENGINE_RESOURCE="${REPO_ROOT}/src/python/pants/engine/${NATIVE_ENGINE_BINARY}"
readonly CFFI_BOOTSTRAPPER="${REPO_ROOT}/build-support/native-engine/bootstrap_cffi.py"

# N.B. Set $MODE to "debug" to generate a binary with debugging symbols.
readonly MODE="${MODE:-release}"
case "$MODE" in
  debug) MODE_FLAG="" ;;
  *) MODE_FLAG="--release" ;;
esac

readonly CACHE_ROOT=${XDG_CACHE_HOME:-$HOME/.cache}/pants
readonly NATIVE_ENGINE_CACHE_DIR=${CACHE_ROOT}/bin/native-engine

function calculate_current_hash() {
  # Cached and unstaged files, with ignored files excluded.
  # NB: We fork a subshell because one or both of `ls-files`/`hash-object` are
  # sensitive to the CWD, and the `--work-tree` option doesn't seem to resolve that.
  (
   cd ${REPO_ROOT}
   git ls-files -c -o --exclude-standard \
     "${NATIVE_ROOT}" \
     "${REPO_ROOT}/src/python/pants/engine/native.py" \
     "${REPO_ROOT}/build-support/bin/native" \
     "${REPO_ROOT}/3rdparty/python/requirements.txt" \
   | git hash-object -t blob --stdin-paths | fingerprint_data
  )
}

function _ensure_cffi_sources() {
  # N.B. Here we assume that higher level callers have already setup the pants' venv and $PANTS_SRCPATH.
  PYTHONPATH="${PANTS_SRCPATH}:${PYTHONPATH}" python "${CFFI_BOOTSTRAPPER}" "${NATIVE_ROOT}/src/cffi" >&2
}

function ensure_native_build_prerequisites() {
  # Control a pants-specific rust toolchain.

  export CARGO_HOME=${CACHE_ROOT}/rust-toolchain
  export RUSTUP_HOME=${CARGO_HOME}

  local rust_toolchain="1.20.0"

  if [[ ! -x "${RUSTUP_HOME}/bin/rustup" ]]
  then
    log "A pants owned rustup installation could not be found, installing via the instructions at" \
        "https://www.rustup.rs ..."
    local readonly rustup=$(mktemp -t pants.rustup.XXXXXX)
    curl https://sh.rustup.rs -sSf > ${rustup}
    sh ${rustup} -y --no-modify-path --default-toolchain "${rust_toolchain}" 1>&2
    rm -f ${rustup}
  fi

  # Make sure rust is pinned at the correct version.
  # We sincerely hope that no one ever runs `rustup override set` in a subdirectory of the working directory.
  "${CARGO_HOME}/bin/rustup" override set "${rust_toolchain}" >&2

  if [[ ! -x "${CARGO_HOME}/bin/protoc-gen-rust" ]]; then
    "${CARGO_HOME}/bin/cargo" install protobuf >&2
  fi
  if [[ ! -x "${CARGO_HOME}/bin/grpc_rust_plugin" ]]; then
    "${CARGO_HOME}/bin/cargo" install grpcio-compiler >&2
  fi
  if [[ ! -x "${CARGO_HOME}/bin/rustfmt" ]]; then
    "${CARGO_HOME}/bin/cargo" install rustfmt >&2
  fi
}

function prepare_to_build_native_code() {
  # Must happen in the pants venv and have PANTS_SRCPATH set.

  ensure_native_build_prerequisites
  _ensure_cffi_sources
}

function run_cargo() {
  prepare_to_build_native_code

  local readonly cargo="${CARGO_HOME}/bin/cargo"
  "${cargo}" "$@"
}

function _build_native_code() {
  # Builds the native code, and echos the path of the built binary.
  run_cargo build ${MODE_FLAG} --manifest-path ${NATIVE_ROOT}/Cargo.toml || die
  echo "${NATIVE_ROOT}/target/${MODE}/libengine.${LIB_EXTENSION}"
}

function bootstrap_native_code() {
  # Bootstraps the native code only if needed.
  local native_engine_version="$(calculate_current_hash)"
  local target_binary="${NATIVE_ENGINE_CACHE_DIR}/${native_engine_version}/${NATIVE_ENGINE_BINARY}"
  if [ ! -f "${target_binary}" ]
  then
    local readonly native_binary="$(_build_native_code)"

    # If bootstrapping the native engine fails, don't attempt to run pants
    # afterwards.
    if ! [ -f "${native_binary}" ]
    then
      die "Failed to build native engine."
    fi

    # Pick up Cargo.lock changes if any caused by the `cargo build`.
    native_engine_version="$(calculate_current_hash)"
    target_binary="${NATIVE_ENGINE_CACHE_DIR}/${native_engine_version}/${NATIVE_ENGINE_BINARY}"

    mkdir -p "$(dirname ${target_binary})"
    cp "${native_binary}" "${target_binary}"
  fi
  cp -p "${target_binary}" "${NATIVE_ENGINE_RESOURCE}"
}
