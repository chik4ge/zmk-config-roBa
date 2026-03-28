#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${ZMK_BUILD_IMAGE:-zmkfirmware/zmk-build-arm:stable}"
WORK_BASE="${ROOT_DIR}/.local-build"
WORKSPACE_DIR="${WORK_BASE}"
CONFIG_COPY_DIR="${WORK_BASE}/config"
ARTIFACT_DIR="${ROOT_DIR}/dist"
STATE_DIR="${WORK_BASE}/state"
STATE_FILE="${STATE_DIR}/build-state.env"

usage() {
  cat <<'EOF'
Usage: scripts/local-build.sh [--pull] [--update] [--pristine] [--flash PATH] [target]

Targets:
  all             Build all firmware targets in build.yaml
  roBa_R          Build right half firmware with studio-rpc-usb-uart
  roBa_L          Build left half firmware
  settings_reset  Build settings reset firmware

Options:
  --pull          Always pull the Docker image before building
  --update        Run west update before building
  --pristine      Force pristine builds
  --flash PATH    Copy the built artifact to PATH after a single-target build
EOF
}

pull_image=0
update_workspace=0
pristine_build=0
flash_path=""
target="all"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pull)
      pull_image=1
      shift
      ;;
    --update)
      update_workspace=1
      shift
      ;;
    --pristine)
      pristine_build=1
      shift
      ;;
    --flash)
      flash_path="${2:-}"
      if [[ -z "${flash_path}" ]]; then
        usage >&2
        exit 1
      fi
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    all|roBa_R|roBa_L|settings_reset)
      target="$1"
      shift
      ;;
    *)
      usage >&2
      exit 1
      ;;
  esac
done

case "${target}" in
  all|roBa_R|roBa_L|settings_reset)
    ;;
esac

mkdir -p "${WORK_BASE}" "${ARTIFACT_DIR}"
mkdir -p "${STATE_DIR}"
rm -rf "${CONFIG_COPY_DIR}"
mkdir -p "${CONFIG_COPY_DIR}"
cp -R "${ROOT_DIR}/config/." "${CONFIG_COPY_DIR}/"

sha256_dir() {
  local dir="$1"
  if [[ ! -d "${dir}" ]]; then
    printf 'missing'
    return
  fi

  find "${dir}" -type f -print0 \
    | sort -z \
    | xargs -0 sha256sum \
    | sha256sum \
    | awk "{print \$1}"
}

sha256_file() {
  local file="$1"
  if [[ ! -f "${file}" ]]; then
    printf 'missing'
    return
  fi

  sha256sum "${file}" | awk "{print \$1}"
}

artifact_path_for_target() {
  case "$1" in
    roBa_R)
      printf '%s\n' "${ARTIFACT_DIR}/roBa-right.uf2"
      ;;
    roBa_L)
      printf '%s\n' "${ARTIFACT_DIR}/roBa-left.uf2"
      ;;
    settings_reset)
      printf '%s\n' "${ARTIFACT_DIR}/settings-reset-seeeduino_xiao_ble.uf2"
      ;;
    *)
      return 1
      ;;
  esac
}

detect_boot_mounts() {
  local dir

  for dir in /media/*/* /run/media/*/* /mnt/*; do
    [[ -d "${dir}" ]] || continue
    if [[ -f "${dir}/INFO_UF2.TXT" ]] || [[ -f "${dir}/CURRENT.UF2" ]]; then
      printf '%s\n' "${dir}"
    fi
  done
}

prev_west_hash=""
prev_build_hash=""
prev_config_hash=""
prev_boards_hash=""
prev_module_hash=""

if [[ -f "${STATE_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${STATE_FILE}"
fi

current_west_hash="$(sha256_file "${ROOT_DIR}/config/west.yml")"
current_build_hash="$(sha256_file "${ROOT_DIR}/build.yaml")"
current_config_hash="$(sha256_dir "${ROOT_DIR}/config")"
current_boards_hash="$(sha256_dir "${ROOT_DIR}/boards")"
current_module_hash="$(sha256_file "${ROOT_DIR}/zephyr/module.yml")"

auto_update_workspace=0
auto_pristine_build=0

if [[ ! -d "${WORKSPACE_DIR}/.west" ]]; then
  auto_update_workspace=1
  auto_pristine_build=1
fi

if [[ "${current_west_hash}" != "${prev_west_hash}" ]]; then
  auto_update_workspace=1
fi

if [[ "${current_build_hash}" != "${prev_build_hash}" ]] \
  || [[ "${current_config_hash}" != "${prev_config_hash}" ]] \
  || [[ "${current_boards_hash}" != "${prev_boards_hash}" ]] \
  || [[ "${current_module_hash}" != "${prev_module_hash}" ]]; then
  auto_pristine_build=1
fi

if [[ "${update_workspace}" -eq 0 ]]; then
  update_workspace="${auto_update_workspace}"
fi

if [[ "${pristine_build}" -eq 0 ]]; then
  pristine_build="${auto_pristine_build}"
fi

if [[ "${pull_image}" -eq 1 ]] || ! docker image inspect "${IMAGE}" >/dev/null 2>&1; then
  docker pull "${IMAGE}" >/dev/null
fi

docker run --rm \
  --user "$(id -u):$(id -g)" \
  -v "${ROOT_DIR}:/workspace/module" \
  -v "${WORK_BASE}:/workspace/work" \
  -w /workspace/work \
  -e TARGET="${target}" \
  -e PRISTINE_BUILD="${pristine_build}" \
  -e UPDATE_WORKSPACE="${update_workspace}" \
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
      local west_args=(-s zmk/app -d "${build_dir}" -b "${board}")
      local cmake_args=(-DZMK_CONFIG="${CONFIG_DIR}" -DZMK_EXTRA_MODULES="${MODULE_DIR}")

      if [[ -n "${snippet}" ]]; then
        west_args+=(-S "${snippet}")
      fi

      if [[ "${PRISTINE_BUILD}" -eq 1 ]]; then
        west_args=(-p "${west_args[@]}")
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
      UPDATE_WORKSPACE=1
    fi

    if [[ "${UPDATE_WORKSPACE}" -eq 1 ]]; then
      (
        cd "${WORKSPACE_DIR}"
        west update --fetch-opt=--filter=tree:0
        west zephyr-export
      )
    fi

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

cat > "${STATE_FILE}" <<EOF
prev_west_hash="${current_west_hash}"
prev_build_hash="${current_build_hash}"
prev_config_hash="${current_config_hash}"
prev_boards_hash="${current_boards_hash}"
prev_module_hash="${current_module_hash}"
EOF

if [[ "${target}" != "all" ]]; then
  artifact_path="$(artifact_path_for_target "${target}")"

  if [[ ! -f "${artifact_path}" ]]; then
    echo "Built artifact not found: ${artifact_path}" >&2
    exit 1
  fi

  mapfile -t detected_mounts < <(detect_boot_mounts)

  if [[ -n "${flash_path}" ]]; then
    if [[ ! -d "${flash_path}" ]]; then
      echo "Flash destination does not exist: ${flash_path}" >&2
      exit 1
    fi

    cp "${artifact_path}" "${flash_path}/"
    echo "Copied $(basename "${artifact_path}") to ${flash_path}/"
    exit 0
  fi

  if [[ "${#detected_mounts[@]}" -eq 0 ]]; then
    echo "No mounted UF2 device detected."
    echo "Built artifact: ${artifact_path}"
    exit 0
  fi

  echo "Mounted UF2 device(s) detected:"
  printf '  %s\n' "${detected_mounts[@]}"
  echo "Built artifact: ${artifact_path}"
  echo "Copy destination must be confirmed before writing."
  echo "Re-run with:"
  echo "  ./scripts/local-build.sh ${target} --flash <mount-path>"
fi
