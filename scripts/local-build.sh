#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${ZMK_BUILD_IMAGE:-zmkfirmware/zmk-build-arm:stable}"
WORK_BASE="${ROOT_DIR}/.local-build"
WORKSPACE_DIR="${WORK_BASE}"
CONFIG_COPY_DIR="${WORK_BASE}/config"
ARTIFACT_DIR="${ROOT_DIR}/dist"

usage() {
  cat <<'EOF'
Usage: scripts/local-build.sh [target]

Targets:
  all             Build all firmware targets in build.yaml
  roBa_R          Build right half firmware with studio-rpc-usb-uart
  roBa_L          Build left half firmware
  settings_reset  Build settings reset firmware
EOF
}

target="${1:-all}"

case "${target}" in
  all|roBa_R|roBa_L|settings_reset)
    ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 1
    ;;
esac

mkdir -p "${WORK_BASE}" "${ARTIFACT_DIR}"
rm -rf "${CONFIG_COPY_DIR}"
mkdir -p "${CONFIG_COPY_DIR}"
cp -R "${ROOT_DIR}/config/." "${CONFIG_COPY_DIR}/"

docker pull "${IMAGE}" >/dev/null

docker run --rm \
  --user "$(id -u):$(id -g)" \
  -v "${ROOT_DIR}:/workspace/module" \
  -v "${WORK_BASE}:/workspace/work" \
  -w /workspace/work \
  -e TARGET="${target}" \
  -e MODULE_DIR="/workspace/module" \
  -e WORKSPACE_DIR="/workspace/work" \
  -e CONFIG_DIR="/workspace/work/config" \
  -e ARTIFACT_DIR="/workspace/module/dist" \
  "${IMAGE}" \
  bash -lc '
    set -euo pipefail

    build_one() {
      local name="$1"
      local board="$2"
      local shield="$3"
      local snippet="$4"
      local artifact_base="$5"
      local build_dir="${WORKSPACE_DIR}/build/${name}"
      local west_args=(-p -s zmk/app -d "${build_dir}" -b "${board}")
      local cmake_args=(-DZMK_CONFIG="${CONFIG_DIR}" -DZMK_EXTRA_MODULES="${MODULE_DIR}")

      if [[ -n "${snippet}" ]]; then
        west_args+=(-S "${snippet}")
      fi

      if [[ -n "${shield}" ]]; then
        cmake_args+=(-DSHIELD="${shield}")
      fi

      (
        cd "${WORKSPACE_DIR}"
        west build "${west_args[@]}" -- "${cmake_args[@]}"
      )

      if [[ -f "${build_dir}/zephyr/zmk.uf2" ]]; then
        cp "${build_dir}/zephyr/zmk.uf2" "${ARTIFACT_DIR}/${artifact_base}.uf2"
      elif [[ -f "${build_dir}/zephyr/zmk.bin" ]]; then
        cp "${build_dir}/zephyr/zmk.bin" "${ARTIFACT_DIR}/${artifact_base}.bin"
      else
        echo "No firmware artifact produced for ${name}" >&2
        exit 1
      fi
    }

    if [[ ! -d "${WORKSPACE_DIR}/.west" ]]; then
      rm -rf "${WORKSPACE_DIR}"
      mkdir -p "${WORKSPACE_DIR}"
      (
        cd "${WORKSPACE_DIR}"
        west init -l "${CONFIG_DIR}"
      )
    fi

    (
      cd "${WORKSPACE_DIR}"
      west update --fetch-opt=--filter=tree:0
      west zephyr-export
    )

    rm -f "${ARTIFACT_DIR}"/roBa-*.uf2 "${ARTIFACT_DIR}"/settings-reset-*.uf2 "${ARTIFACT_DIR}"/roBa-*.bin "${ARTIFACT_DIR}"/settings-reset-*.bin

    case "${TARGET}" in
      all)
        build_one roBa_R seeeduino_xiao_ble roBa_R studio-rpc-usb-uart roBa-right
        build_one roBa_L seeeduino_xiao_ble roBa_L "" roBa-left
        build_one settings_reset seeeduino_xiao_ble settings_reset "" settings-reset-seeeduino_xiao_ble
        ;;
      roBa_R)
        build_one roBa_R seeeduino_xiao_ble roBa_R studio-rpc-usb-uart roBa-right
        ;;
      roBa_L)
        build_one roBa_L seeeduino_xiao_ble roBa_L "" roBa-left
        ;;
      settings_reset)
        build_one settings_reset seeeduino_xiao_ble settings_reset "" settings-reset-seeeduino_xiao_ble
        ;;
    esac
  '
