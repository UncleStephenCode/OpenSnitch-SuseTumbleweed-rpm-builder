#!/usr/bin/env bash
set -Eeuo pipefail

# build-opensnitch-rpm-tw.sh
#
# Сборка OpenSnitch RPM-пакетов для openSUSE Tumbleweed в Docker.
#
# Цель этой версии:
#   - минимизировать зависимости итоговых RPM;
#   - сначала пробовать статическую линковку opensnitchd;
#   - если статическая линковка не удалась, собрать динамически;
#   - всё, что осталось динамически связанным, отдаётся rpm auto-requires;
#   - UI остаётся Python/PyQt-приложением и получает явные versioned Python/Qt Requires.
#
# Требования на хосте:
#   - docker
#   - zypper, sudo — только если INSTALL=1
#
# Примеры:
#   ./build-opensnitch-rpm-tw.sh
#   REBUILD_BUILDER=1 ./build-opensnitch-rpm-tw.sh
#   REF=v1.8.0 ./build-opensnitch-rpm-tw.sh
#   REF=master ./build-opensnitch-rpm-tw.sh
#   INSTALL=0 ./build-opensnitch-rpm-tw.sh
#   BUILD_UI=0 ./build-opensnitch-rpm-tw.sh
#   STATIC_DAEMON=0 ./build-opensnitch-rpm-tw.sh
#   STATIC_DAEMON=1 ./build-opensnitch-rpm-tw.sh
#   PROCESS_MONITOR_METHOD=proc ./build-opensnitch-rpm-tw.sh
#   PROCESS_MONITOR_METHOD=audit ./build-opensnitch-rpm-tw.sh
#   DOCKER_MOUNT_SUFFIX=rw ./build-opensnitch-rpm-tw.sh
#   DOCKER_REGISTRY_PREFIX=harbor.example.org/docker-hub-proxy ./build-opensnitch-rpm-tw.sh
#   DOCKER_BASE_IMAGE=registry.example.org/opensuse/tumbleweed ./build-opensnitch-rpm-tw.sh
#   PY_GRPCIO_VERSION=1.80.0 PY_GRPCIO_TOOLS_VERSION=1.80.0 REBUILD_BUILDER=1 ./build-opensnitch-rpm-tw.sh
#
# Полезные переменные:
#   REPO_URL                    URL репозитория OpenSnitch
#   REF                         latest, tag, branch или commit
#   DOCKER_BASE_IMAGE           базовый образ для Dockerfile, по умолчанию opensuse/tumbleweed
#   DOCKER_REGISTRY_PREFIX      опциональный префикс альтернативного registry/mirror
#                               пример: harbor.example.org/docker-hub-proxy
#   WORKDIR                     рабочий каталог сборки
#   BUILDER_IMAGE               имя Docker image сборщика
#   INSTALL                     1 = установить/обновить RPM после сборки, 0 = только собрать
#   REBUILD_BUILDER             1 = пересобрать Docker image
#   BUILD_UI                    1 = собрать opensnitch-ui RPM, 0 = только daemon
#   STATIC_DAEMON               auto = попробовать static и fallback dynamic
#                               1    = требовать static, падать при ошибке
#                               0    = сразу dynamic
#   MINIMAL_INSTALL             1 = zypper --no-recommends при установке локальных RPM
#   PROCESS_MONITOR_METHOD      метод мониторинга процессов: ebpf, audit или proc
#                               По умолчанию: ebpf
#   SKIP_EBPF                   1 = не собирать eBPF-модули. Если переменная не задана,
#                               при PROCESS_MONITOR_METHOD=ebpf используется 0,
#                               при audit/proc используется 1
#   RPM_RELEASE                 release RPM-пакета
#   HOST_KERNEL                 версия ядра хоста, по умолчанию uname -r
#   DOCKER_MOUNT_SUFFIX         суффикс bind mount, по умолчанию rw,Z
#   RUN_AS_USER                 1 = запускать сборку в контейнере от UID/GID текущего пользователя
#   PROTOC_GEN_GO_VERSION       версия protoc-gen-go
#   PROTOC_GEN_GO_GRPC_VERSION  версия protoc-gen-go-grpc
#   GO_BUILD_TAGS               build tags для Go, по умолчанию: netgo osusergo
#   PY_GRPCIO_VERSION           версия grpcio в builder image для генерации Python gRPC-кода
#   PY_GRPCIO_TOOLS_VERSION     версия grpcio-tools в builder image; должна быть <= runtime grpcio
#   PY_PROTOBUF_VERSION         опциональная фиксация protobuf в builder image, пусто = не фиксировать

REPO_URL="${REPO_URL:-https://github.com/evilsocket/opensnitch.git}"
REF="${REF:-latest}"
DOCKER_BASE_IMAGE="${DOCKER_BASE_IMAGE:-opensuse/tumbleweed}"
DOCKER_REGISTRY_PREFIX="${DOCKER_REGISTRY_PREFIX:-}"
if [[ -n "${DOCKER_REGISTRY_PREFIX}" ]]; then
  DOCKER_FROM_IMAGE="${DOCKER_REGISTRY_PREFIX%/}/${DOCKER_BASE_IMAGE#/}"
else
  DOCKER_FROM_IMAGE="${DOCKER_BASE_IMAGE}"
fi
WORKDIR="${WORKDIR:-$PWD/opensnitch-rpm-work}"
BUILDER_IMAGE="${BUILDER_IMAGE:-local/opensnitch-rpm-builder:tumbleweed}"
INSTALL="${INSTALL:-1}"
REBUILD_BUILDER="${REBUILD_BUILDER:-0}"
BUILD_UI="${BUILD_UI:-1}"
STATIC_DAEMON="${STATIC_DAEMON:-auto}"
MINIMAL_INSTALL="${MINIMAL_INSTALL:-1}"
PROCESS_MONITOR_METHOD="${PROCESS_MONITOR_METHOD:-ebpf}"

if [[ -z "${SKIP_EBPF+x}" ]]; then
  if [[ "${PROCESS_MONITOR_METHOD}" == "ebpf" ]]; then
    SKIP_EBPF="0"
  else
    SKIP_EBPF="1"
  fi
else
  SKIP_EBPF="${SKIP_EBPF}"
fi

RPM_RELEASE="${RPM_RELEASE:-1.local$(date -u +%Y%m%d%H%M)}"
HOST_KERNEL="${HOST_KERNEL:-$(uname -r)}"
DOCKER_MOUNT_SUFFIX="${DOCKER_MOUNT_SUFFIX:-rw,Z}"
RUN_AS_USER="${RUN_AS_USER:-1}"

# Важно: protoc-gen-go-grpc v1.5.x генерирует код под слишком свежий grpc-go
# для ряда версий OpenSnitch. v1.3.0 обычно совместимее.
PROTOC_GEN_GO_VERSION="${PROTOC_GEN_GO_VERSION:-v1.31.0}"
PROTOC_GEN_GO_GRPC_VERSION="${PROTOC_GEN_GO_GRPC_VERSION:-v1.3.0}"

GO_BUILD_TAGS="${GO_BUILD_TAGS:-netgo osusergo}"

# grpcio-tools генерирует ui_pb2_grpc.py с проверкой минимальной версии grpcio.
# Если builder использует grpcio-tools новее, чем grpcio из репозитория Tumbleweed,
# opensnitch-ui падает с требованием обновить grpcio. Поэтому по умолчанию
# фиксируем Python gRPC генератор на версии, совместимой с текущими пакетами Tumbleweed.
PY_GRPCIO_VERSION="${PY_GRPCIO_VERSION:-1.80.0}"
PY_GRPCIO_TOOLS_VERSION="${PY_GRPCIO_TOOLS_VERSION:-${PY_GRPCIO_VERSION}}"
PY_PROTOBUF_VERSION="${PY_PROTOBUF_VERSION:-}"

say() {
  echo "[INFO] $*"
}

warn() {
  echo "[WARN] $*" >&2
}

die() {
  echo "[ERROR] $*" >&2
  exit 1
}

as_root() {
  if [[ "${EUID}" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Не найдена команда: $1"
}

prepare_workdir() {
  mkdir -p "${WORKDIR}"
  WORKDIR="$(cd "${WORKDIR}" && pwd -P)"

  mkdir -p "${WORKDIR}"/{out,cache,gomod,gocache,gopath,home}

  if [[ ! -w "${WORKDIR}" ]]; then
    warn "Каталог ${WORKDIR} недоступен на запись текущему пользователю, исправляю владельца"
    as_root chown -R "$(id -u):$(id -g)" "${WORKDIR}"
  fi

  chmod -R u+rwX "${WORKDIR}" 2>/dev/null || true

  if [[ ! -w "${WORKDIR}" ]]; then
    die "Каталог ${WORKDIR} всё ещё недоступен на запись"
  fi
}

require_cmd docker

if [[ "${INSTALL}" == "1" ]]; then
  require_cmd zypper
fi

host_python_flavor() {
  python3 - <<'PY'
import sys
print(f"python{sys.version_info.major}{sys.version_info.minor}")
PY
}

zypper_install_ui_runtime_deps() {
  local flavor
  flavor="$(host_python_flavor 2>/dev/null || echo python3)"

  say "Пробую поставить runtime-зависимости UI для ${flavor}"

  as_root zypper -n install --no-recommends \
    "${flavor}-PyQt6" \
    "${flavor}-grpcio" \
    "${flavor}-protobuf" \
    "${flavor}-packaging" \
    qt6-sql-sqlite || warn "Не все основные UI-зависимости поставились по versioned-именам"

  for p in \
    "${flavor}-python-slugify" \
    "${flavor}-slugify" \
    python3-python-slugify \
    python3-slugify; do
    as_root zypper -n install --no-recommends "$p" && break || true
  done

  for p in \
    "${flavor}-pyinotify" \
    python3-pyinotify \
    python3-inotify; do
    as_root zypper -n install --no-recommends "$p" && break || true
  done

  for p in \
    "${flavor}-notify2" \
    python3-notify2; do
    as_root zypper -n install --no-recommends "$p" && break || true
  done
}

case "${STATIC_DAEMON}" in
  auto|0|1) ;;
  *) die "STATIC_DAEMON должен быть auto, 0 или 1" ;;
esac

case "${PROCESS_MONITOR_METHOD}" in
  ebpf|audit|proc) ;;
  *) die "PROCESS_MONITOR_METHOD должен быть ebpf, audit или proc" ;;
esac

if [[ "${PROCESS_MONITOR_METHOD}" == "ebpf" && "${SKIP_EBPF}" == "1" ]]; then
  die "PROCESS_MONITOR_METHOD=ebpf требует SKIP_EBPF=0, иначе eBPF-модуль не будет собран и упакован"
fi

prepare_workdir

{
  printf 'FROM %s\n\n' "${DOCKER_FROM_IMAGE}"
  cat <<'DOCKERFILE'
ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8

SHELL ["/bin/bash", "-lc"]

RUN set -eux; \
    zypper -n ref; \
    install_required() { \
      zypper -n in --no-recommends "$@"; \
    }; \
    install_one_of() { \
      local label="$1"; \
      shift; \
      local p; \
      for p in "$@"; do \
        if zypper -n in --no-recommends "$p"; then \
          return 0; \
        fi; \
      done; \
      echo "[ERROR] Не удалось установить ни один вариант для ${label}: $*" >&2; \
      return 1; \
    }; \
    install_optional() { \
      local p; \
      for p in "$@"; do \
        zypper -n in --no-recommends "$p" || true; \
      done; \
    }; \
    install_required \
      ca-certificates \
      tar \
      gzip \
      xz \
      wget \
      curl \
      make \
      gcc \
      gcc-c++ \
      rpm-build \
      go \
      python3 \
      clang \
      llvm \
      flex \
      bison \
      bc \
      rsync \
      patch \
      diffutils \
      findutils \
      grep \
      sed \
      gawk \
      file \
      binutils; \
    install_one_of "git" \
      git-core \
      git; \
    install_one_of "python3-pip" \
      python3-pip \
      python311-pip \
      python312-pip \
      python313-pip; \
    install_one_of "python setuptools" \
      python3-setuptools \
      python311-setuptools \
      python312-setuptools \
      python313-setuptools; \
    install_one_of "python wheel" \
      python-wheel \
      python3-wheel \
      python311-wheel \
      python312-wheel \
      python313-wheel; \
    install_one_of "python devel" \
      python3-devel \
      python311-devel \
      python312-devel \
      python313-devel; \
    install_one_of "pkg-config" \
      pkg-config \
      pkgconf-pkg-config; \
    install_one_of "libpcap-devel" \
      libpcap-devel; \
    install_one_of "libnetfilter_queue-devel" \
      libnetfilter_queue-devel; \
    install_one_of "openssl-devel" \
      libopenssl-devel \
      libopenssl-3-devel \
      openssl-devel; \
    install_one_of "libelf-devel" \
      libelf-devel \
      elfutils-libelf-devel; \
    install_optional \
      glibc-devel-static \
      libpcap-devel-static \
      libnetfilter_queue-devel-static \
      libnfnetlink-devel \
      libnfnetlink-devel-static \
      libmnl-devel \
      libmnl-devel-static \
      zlib-devel \
      zlib-devel-static \
      libbpf-devel \
      libbpf-devel-static \
      bpftool \
      dwarves \
      protobuf-devel \
      protobuf-source \
      kernel-default-devel \
      kernel-devel \
      kernel-source; \
    zypper clean -a

RUN set -eux; \
    for p in \
      qt6-tools \
      qt6-tools-linguist \
      qt6-base-devel \
      python313-PyQt6 \
      python312-PyQt6 \
      python311-PyQt6 \
      python313-grpcio \
      python312-grpcio \
      python311-grpcio \
      python313-grpcio-tools \
      python312-grpcio-tools \
      python311-grpcio-tools \
      python313-protobuf \
      python312-protobuf \
      python311-protobuf \
      python313-packaging \
      python312-packaging \
      python311-packaging \
      python313-notify2 \
      python312-notify2 \
      python311-notify2 \
      python313-python-slugify \
      python312-python-slugify \
      python311-python-slugify \
      python313-slugify \
      python312-slugify \
      python311-slugify \
      python313-pyinotify \
      python312-pyinotify \
      python311-pyinotify \
      python3-grpcio \
      python3-grpcio-tools \
      python3-protobuf \
      python3-qt6 \
      python3-PyQt6 \
      python3-pyqt6 \
      python3-pyinotify \
      python3-inotify \
      python3-notify2 \
      python3-python-slugify \
      python3-slugify \
      python3-packaging \
      qt6-sql-sqlite \
      qgnomeplatform-qt6 \
      QGnomePlatform-qt6 \
      gtk3-tools; \
    do \
      zypper -n in --no-recommends "$p" || true; \
    done; \
    zypper clean -a

ARG PY_GRPCIO_VERSION=1.80.0
ARG PY_GRPCIO_TOOLS_VERSION=1.80.0
ARG PY_PROTOBUF_VERSION=

RUN set -eux; \
    if [[ -n "${PY_PROTOBUF_VERSION}" ]]; then \
      protobuf_spec="protobuf==${PY_PROTOBUF_VERSION}"; \
    else \
      protobuf_spec="protobuf"; \
    fi; \
    python3 -m pip install --break-system-packages --upgrade \
      pip \
      setuptools \
      wheel \
      "${protobuf_spec}" \
      "grpcio==${PY_GRPCIO_VERSION}" \
      "grpcio-tools==${PY_GRPCIO_TOOLS_VERSION}" || \
    python3 -m pip install --upgrade \
      pip \
      setuptools \
      wheel \
      "${protobuf_spec}" \
      "grpcio==${PY_GRPCIO_VERSION}" \
      "grpcio-tools==${PY_GRPCIO_TOOLS_VERSION}"; \
    python3 -c 'import grpc, google.protobuf; print("builder python grpcio:", grpc.__version__); print("builder python protobuf:", google.protobuf.__version__)'; \
    printf '%s\n' \
      '#!/usr/bin/env bash' \
      'exec python3 -m grpc_tools.protoc "$@"' \
      > /usr/local/bin/protoc; \
    chmod +x /usr/local/bin/protoc; \
    protoc --version
DOCKERFILE
} > "${WORKDIR}/Dockerfile"

say "Базовый Docker image: ${DOCKER_FROM_IMAGE}"
say "Python gRPC generator: grpcio=${PY_GRPCIO_VERSION}, grpcio-tools=${PY_GRPCIO_TOOLS_VERSION}, protobuf=${PY_PROTOBUF_VERSION:-auto}"

if [[ "${REBUILD_BUILDER}" == "1" ]] || ! docker image inspect "${BUILDER_IMAGE}" >/dev/null 2>&1; then
  say "Собираю Docker image для сборки: ${BUILDER_IMAGE}"
  docker build \
    --build-arg "PY_GRPCIO_VERSION=${PY_GRPCIO_VERSION}" \
    --build-arg "PY_GRPCIO_TOOLS_VERSION=${PY_GRPCIO_TOOLS_VERSION}" \
    --build-arg "PY_PROTOBUF_VERSION=${PY_PROTOBUF_VERSION}" \
    -t "${BUILDER_IMAGE}" \
    -f "${WORKDIR}/Dockerfile" \
    "${WORKDIR}"
else
  say "Использую существующий Docker image: ${BUILDER_IMAGE}"
fi

say "Запускаю сборку OpenSnitch в контейнере"

DOCKER_USER_ARGS=()

if [[ "${RUN_AS_USER}" == "1" ]]; then
  DOCKER_USER_ARGS=(
    --user "$(id -u):$(id -g)"
    -e "HOME=/work/home"
  )
else
  DOCKER_USER_ARGS=(
    -e "HOME=/root"
  )
fi

DOCKER_EBPF_MOUNTS=()
if [[ "${SKIP_EBPF}" != "1" ]]; then
  if [[ -d "/lib/modules/${HOST_KERNEL}" ]]; then
    DOCKER_EBPF_MOUNTS+=( -v "/lib/modules/${HOST_KERNEL}:/lib/modules/${HOST_KERNEL}:ro" )
  else
    warn "На хосте не найден /lib/modules/${HOST_KERNEL}; eBPF-сборка может не пройти"
  fi

  if [[ -d "/usr/src" ]]; then
    DOCKER_EBPF_MOUNTS+=( -v "/usr/src:/usr/src:ro" )
  fi

  if [[ -d "/sys/kernel/btf" ]]; then
    DOCKER_EBPF_MOUNTS+=( -v "/sys/kernel/btf:/sys/kernel/btf:ro" )
  fi
fi

docker run --rm -i \
  "${DOCKER_USER_ARGS[@]}" \
  -e "REPO_URL=${REPO_URL}" \
  -e "DOCKER_BASE_IMAGE=${DOCKER_BASE_IMAGE}" \
  -e "DOCKER_REGISTRY_PREFIX=${DOCKER_REGISTRY_PREFIX}" \
  -e "DOCKER_FROM_IMAGE=${DOCKER_FROM_IMAGE}" \
  -e "REF=${REF}" \
  -e "RPM_RELEASE=${RPM_RELEASE}" \
  -e "HOST_KERNEL=${HOST_KERNEL}" \
  -e "SKIP_EBPF=${SKIP_EBPF}" \
  -e "PROCESS_MONITOR_METHOD=${PROCESS_MONITOR_METHOD}" \
  -e "BUILD_UI=${BUILD_UI}" \
  -e "STATIC_DAEMON=${STATIC_DAEMON}" \
  -e "GO_BUILD_TAGS=${GO_BUILD_TAGS}" \
  -e "PROTOC_GEN_GO_VERSION=${PROTOC_GEN_GO_VERSION}" \
  -e "PROTOC_GEN_GO_GRPC_VERSION=${PROTOC_GEN_GO_GRPC_VERSION}" \
  -e "PY_GRPCIO_VERSION=${PY_GRPCIO_VERSION}" \
  -e "PY_GRPCIO_TOOLS_VERSION=${PY_GRPCIO_TOOLS_VERSION}" \
  -e "PY_PROTOBUF_VERSION=${PY_PROTOBUF_VERSION}" \
  -e "HOST_UID=$(id -u)" \
  -e "HOST_GID=$(id -g)" \
  -v "${WORKDIR}:/work:${DOCKER_MOUNT_SUFFIX}" \
  "${DOCKER_EBPF_MOUNTS[@]}" \
  "${BUILDER_IMAGE}" \
  /bin/bash <<'CONTAINER_SCRIPT'
set -Eeuo pipefail

say() {
  echo "[BUILD] $*"
}

warn() {
  echo "[WARN] $*" >&2
}

die() {
  echo "[ERROR] $*" >&2
  exit 1
}

REPO_URL="${REPO_URL:?}"
DOCKER_BASE_IMAGE="${DOCKER_BASE_IMAGE:-}"
DOCKER_REGISTRY_PREFIX="${DOCKER_REGISTRY_PREFIX:-}"
DOCKER_FROM_IMAGE="${DOCKER_FROM_IMAGE:-}"
REF="${REF:?}"
RPM_RELEASE="${RPM_RELEASE:?}"
HOST_KERNEL="${HOST_KERNEL:?}"
SKIP_EBPF="${SKIP_EBPF:-0}"
PROCESS_MONITOR_METHOD="${PROCESS_MONITOR_METHOD:-ebpf}"
BUILD_UI="${BUILD_UI:-1}"
STATIC_DAEMON="${STATIC_DAEMON:-auto}"
GO_BUILD_TAGS="${GO_BUILD_TAGS:-netgo osusergo}"

# grpcio-tools генерирует ui_pb2_grpc.py с проверкой минимальной версии grpcio.
# Если builder использует grpcio-tools новее, чем grpcio из репозитория Tumbleweed,
# opensnitch-ui падает с требованием обновить grpcio. Поэтому по умолчанию
# фиксируем Python gRPC генератор на версии, совместимой с текущими пакетами Tumbleweed.
PY_GRPCIO_VERSION="${PY_GRPCIO_VERSION:-1.80.0}"
PY_GRPCIO_TOOLS_VERSION="${PY_GRPCIO_TOOLS_VERSION:-${PY_GRPCIO_VERSION}}"
PY_PROTOBUF_VERSION="${PY_PROTOBUF_VERSION:-}"
PROTOC_GEN_GO_VERSION="${PROTOC_GEN_GO_VERSION:-v1.31.0}"
PROTOC_GEN_GO_GRPC_VERSION="${PROTOC_GEN_GO_GRPC_VERSION:-v1.3.0}"
HOST_UID="${HOST_UID:-0}"
HOST_GID="${HOST_GID:-0}"

SRC_DIR="/work/src"
OUT_DIR="/work/out"
PAYLOAD_DIR="/work/payload"
FILELIST_DIR="/work/filelists"
RPM_TOP="/work/rpmbuild"

say "Проверяю доступ к /work"
say "uid=$(id -u) gid=$(id -g) home=${HOME:-}"

mkdir -p "${HOME:-/work/home}" || true

if ! touch /work/.rw-test 2>/dev/null; then
  die "Нет прав на запись в /work. Попробуйте: sudo chown -R $(id -u):$(id -g) <WORKDIR> или DOCKER_MOUNT_SUFFIX=rw"
fi

rm -f /work/.rw-test

rm -rf "${SRC_DIR}" "${PAYLOAD_DIR}" "${FILELIST_DIR}" "${RPM_TOP}" "${OUT_DIR:?}"/*
mkdir -p "${OUT_DIR}" "${PAYLOAD_DIR}" "${FILELIST_DIR}" "${RPM_TOP}"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}

resolve_ref() {
  local ref="$1"

  if [[ "${ref}" != "latest" ]]; then
    echo "${ref}"
    return 0
  fi

  git ls-remote --tags --refs "${REPO_URL}" 'v*' \
    | awk '{print $2}' \
    | sed 's#refs/tags/##' \
    | sort -V \
    | tail -n 1
}

clone_repo() {
  local repo="$1"
  local ref="$2"
  local dst="$3"

  if git ls-remote --exit-code --tags "${repo}" "refs/tags/${ref}" >/dev/null 2>&1; then
    git clone --recursive --depth 1 --branch "${ref}" "${repo}" "${dst}"
    return 0
  fi

  if git ls-remote --exit-code --heads "${repo}" "refs/heads/${ref}" >/dev/null 2>&1; then
    git clone --recursive --depth 1 --branch "${ref}" "${repo}" "${dst}"
    return 0
  fi

  git clone --recursive "${repo}" "${dst}"
  cd "${dst}"
  git checkout "${ref}"
  git submodule update --init --recursive
}

binary_is_static() {
  local bin="$1"
  local file_out
  local ldd_out

  file_out="$(file "${bin}" 2>&1 || true)"
  say "file ${bin}: ${file_out}"

  if grep -qi 'statically linked' <<< "${file_out}"; then
    return 0
  fi

  ldd_out="$(ldd "${bin}" 2>&1 || true)"
  say "ldd ${bin}:"
  printf '%s\n' "${ldd_out}"

  if grep -Eqi 'not a dynamic executable|statically linked' <<< "${ldd_out}"; then
    return 0
  fi

  return 1
}

save_binary_link_report() {
  local bin="$1"
  local prefix="$2"

  file "${bin}" > "${OUT_DIR}/${prefix}.file.txt" 2>&1 || true
  ldd "${bin}" > "${OUT_DIR}/${prefix}.ldd.txt" 2>&1 || true

  {
    echo "# ${prefix} dynamic libraries"
    echo "# generated at $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo
    cat "${OUT_DIR}/${prefix}.ldd.txt"
  } > "${OUT_DIR}/${prefix}.link-report.txt"
}

build_daemon_static_try() {
  say "Пробую статически собрать opensnitchd"
  say "GO_BUILD_TAGS=${GO_BUILD_TAGS}"

  export CGO_ENABLED=1
  export CGO_CPPFLAGS="${CGO_CPPFLAGS:-} -fcf-protection"
  export CGO_CFLAGS="${CGO_CFLAGS:-} -fcf-protection"
  export CGO_CXXFLAGS="${CGO_CXXFLAGS:-} -fcf-protection"

  rm -f ./opensnitchd

  go build \
    -trimpath \
    -tags "${GO_BUILD_TAGS}" \
    -ldflags "-s -w -linkmode external -extldflags '-static'" \
    -o opensnitchd .
}

build_daemon_dynamic() {
  say "Собираю opensnitchd динамически"

  export CGO_ENABLED=1
  export CGO_CPPFLAGS="${CGO_CPPFLAGS:-} -fcf-protection"
  export CGO_CFLAGS="${CGO_CFLAGS:-} -fcf-protection"
  export CGO_CXXFLAGS="${CGO_CXXFLAGS:-} -fcf-protection"

  rm -f ./opensnitchd
  go build -trimpath -ldflags "-s -w" -o opensnitchd .
}

build_daemon_minimal_deps() {
  cd daemon
  go mod download || true

  case "${STATIC_DAEMON}" in
    0)
      build_daemon_dynamic
      ;;
    1)
      build_daemon_static_try
      if ! binary_is_static ./opensnitchd; then
        die "STATIC_DAEMON=1, но opensnitchd не получился статическим"
      fi
      ;;
    auto)
      if build_daemon_static_try; then
        if binary_is_static ./opensnitchd; then
          say "opensnitchd собран статически: внешних библиотек у бинарника нет"
        else
          warn "Статическая сборка завершилась, но бинарник выглядит динамическим. Пересобираю динамически и оставляю зависимости rpm auto-requires."
          build_daemon_dynamic
        fi
      else
        warn "Статическая сборка opensnitchd не удалась. Собираю динамически; rpm сам добавит зависимости на оставшиеся внешние библиотеки."
        build_daemon_dynamic
      fi
      ;;
    *)
      die "STATIC_DAEMON должен быть auto, 0 или 1"
      ;;
  esac

  save_binary_link_report ./opensnitchd opensnitchd
}

apply_process_monitor_method_to_config() {
  local file="$1"
  local method="$2"

  [[ -f "${file}" ]] || return 0

  python3 - "${file}" "${method}" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
method = sys.argv[2]

try:
    data = json.loads(path.read_text(encoding="utf-8"))
except Exception as exc:
    raise SystemExit(f"cannot read JSON config {path}: {exc}")

found = False

def walk(obj):
    global found
    if isinstance(obj, dict):
        for key in list(obj.keys()):
            if key.lower() == "procmonitormethod":
                obj[key] = method
                found = True
            else:
                walk(obj[key])
    elif isinstance(obj, list):
        for item in obj:
            walk(item)

walk(data)

if not found and isinstance(data, dict):
    data["ProcMonitorMethod"] = method

path.write_text(json.dumps(data, indent=4, ensure_ascii=False) + "\n", encoding="utf-8")
PY
}

apply_process_monitor_method_to_service() {
  local service_file="$1"
  local method="$2"

  [[ -f "${service_file}" ]] || return 0

  if grep -q '^ExecStart=' "${service_file}"; then
    sed -i -E "s#^ExecStart=.*opensnitchd.*#ExecStart=/usr/bin/opensnitchd -process-monitor-method ${method}#" "${service_file}"
  else
    cat >> "${service_file}" <<EOF

# Added by local RPM builder
ExecStart=/usr/bin/opensnitchd -process-monitor-method ${method}
EOF
  fi
}

make_filelist() {
  local root="$1"
  local out="$2"

  : > "${out}"

  find "${root}" -type d | sed "s#^${root}##" | sort | while read -r p; do
    [[ -n "${p}" ]] || continue

    case "${p}" in
      /etc|/etc/logrotate.d|/etc/xdg|/etc/xdg/autostart)
        continue
        ;;
      /usr|/usr/bin|/usr/lib|/usr/lib64|/usr/lib/systemd|/usr/lib/systemd/system)
        continue
        ;;
      /usr/share|/usr/share/applications|/usr/share/icons|/usr/share/icons/hicolor|/usr/share/metainfo|/usr/share/kservices5)
        continue
        ;;
    esac

    echo "%dir ${p}" >> "${out}"
  done

  find "${root}" \( -type f -o -type l \) | sed "s#^${root}##" | sort | while read -r p; do
    [[ -n "${p}" ]] || continue

    case "${p}" in
      /etc/opensnitchd/*|/etc/logrotate.d/opensnitch)
        echo "%config(noreplace) ${p}" >> "${out}"
        ;;
      *)
        echo "${p}" >> "${out}"
        ;;
    esac
  done
}

RESOLVED_REF="$(resolve_ref "${REF}")"
[[ -n "${RESOLVED_REF}" ]] || die "Не удалось определить git tag для REF=${REF}"

say "Клонирую ${REPO_URL}, ref=${RESOLVED_REF}"
clone_repo "${REPO_URL}" "${RESOLVED_REF}" "${SRC_DIR}"

cd "${SRC_DIR}"

VERSION="$(
python3 - <<'PY'
import pathlib
import re
import sys

candidates = [
    pathlib.Path("ui/opensnitch/version.py"),
    pathlib.Path("daemon/core/version.go"),
]

for path in candidates:
    if not path.exists():
        continue

    text = path.read_text(encoding="utf-8", errors="replace")

    patterns = [
        r"version\s*=\s*['\"]([^'\"]+)['\"]",
        r'Version\s*=\s*"([^"]+)"',
    ]

    for pattern in patterns:
        m = re.search(pattern, text)
        if m:
            print(m.group(1).lstrip("v"))
            sys.exit(0)

print("0.0.0+git")
PY
)"

[[ -n "${VERSION}" ]] || die "Не удалось определить версию OpenSnitch"

RPM_VERSION="${VERSION//+/_}"

say "Версия OpenSnitch: ${VERSION}"
say "RPM Version: ${RPM_VERSION}"
say "RPM Release: ${RPM_RELEASE}"
say "STATIC_DAEMON=${STATIC_DAEMON}"
say "PROCESS_MONITOR_METHOD=${PROCESS_MONITOR_METHOD}"
say "BUILD_UI=${BUILD_UI}"

PY_FLAVOR="$(python3 - <<'PY'
import sys
print(f"python{sys.version_info.major}{sys.version_info.minor}")
PY
)"
say "Python flavor for UI RPM dependencies: ${PY_FLAVOR}"

export GOPATH="/work/gopath"
export GOMODCACHE="/work/gomod"
export GOCACHE="/work/gocache"
export PATH="${PATH}:${GOPATH}/bin"

say "Python gRPC generator versions: grpcio=${PY_GRPCIO_VERSION}, grpcio-tools=${PY_GRPCIO_TOOLS_VERSION}, protobuf=${PY_PROTOBUF_VERSION:-auto}"
python3 - <<'PYINNER2' || true
import grpc, google.protobuf
print(f'python grpcio in builder runtime: {grpc.__version__}')
print(f'python protobuf in builder runtime: {google.protobuf.__version__}')
PYINNER2

say "Устанавливаю protoc Go plugins"
say "protoc-gen-go=${PROTOC_GEN_GO_VERSION}"
say "protoc-gen-go-grpc=${PROTOC_GEN_GO_GRPC_VERSION}"

go install "google.golang.org/protobuf/cmd/protoc-gen-go@${PROTOC_GEN_GO_VERSION}"
go install "google.golang.org/grpc/cmd/protoc-gen-go-grpc@${PROTOC_GEN_GO_GRPC_VERSION}"

say "Проверяю protoc"
protoc --version

say "Генерирую protobuf-код"
make -C proto

say "Собираю daemon с минимизацией зависимостей"
build_daemon_minimal_deps
cd "${SRC_DIR}"

DAEMON_PAYLOAD="${PAYLOAD_DIR}/opensnitch"
UI_PAYLOAD="${PAYLOAD_DIR}/opensnitch-ui"

mkdir -p \
  "${DAEMON_PAYLOAD}/usr/bin" \
  "${DAEMON_PAYLOAD}/usr/lib/systemd/system" \
  "${DAEMON_PAYLOAD}/usr/lib/opensnitchd/ebpf" \
  "${DAEMON_PAYLOAD}/etc/opensnitchd/rules" \
  "${DAEMON_PAYLOAD}/etc/opensnitchd/tasks" \
  "${DAEMON_PAYLOAD}/etc/logrotate.d"

install -m 0755 daemon/opensnitchd "${DAEMON_PAYLOAD}/usr/bin/opensnitchd"

if [[ -f daemon/data/init/opensnitchd.service ]]; then
  sed \
    -e 's#/usr/local/bin/opensnitchd#/usr/bin/opensnitchd#g' \
    -e 's#ExecStart=/usr/bin/opensnitchd#ExecStart=/usr/bin/opensnitchd#g' \
    daemon/data/init/opensnitchd.service \
    > "${DAEMON_PAYLOAD}/usr/lib/systemd/system/opensnitch.service"
else
  cat > "${DAEMON_PAYLOAD}/usr/lib/systemd/system/opensnitch.service" <<'EOF'
[Unit]
Description=OpenSnitch application firewall daemon
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/opensnitchd
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
fi

apply_process_monitor_method_to_service "${DAEMON_PAYLOAD}/usr/lib/systemd/system/opensnitch.service" "${PROCESS_MONITOR_METHOD}"

for f in \
  daemon/data/default-config.json \
  daemon/data/system-fw.json \
  daemon/data/network_aliases.json; do
  if [[ -f "${f}" ]]; then
    install -m 0644 "${f}" "${DAEMON_PAYLOAD}/etc/opensnitchd/"
  fi
done

apply_process_monitor_method_to_config "${DAEMON_PAYLOAD}/etc/opensnitchd/default-config.json" "${PROCESS_MONITOR_METHOD}"

if compgen -G "daemon/data/rules/*.json" >/dev/null; then
  install -m 0600 daemon/data/rules/*.json "${DAEMON_PAYLOAD}/etc/opensnitchd/rules/"
fi

if [[ -f daemon/data/tasks/tasks.json ]]; then
  install -m 0600 daemon/data/tasks/tasks.json "${DAEMON_PAYLOAD}/etc/opensnitchd/tasks/tasks.json"
fi

if [[ -f utils/packaging/daemon/deb/debian/opensnitch.logrotate ]]; then
  install -m 0644 utils/packaging/daemon/deb/debian/opensnitch.logrotate \
    "${DAEMON_PAYLOAD}/etc/logrotate.d/opensnitch"
fi

if [[ "${SKIP_EBPF}" != "1" ]]; then
  if [[ "${PROCESS_MONITOR_METHOD}" == "ebpf" && ! -e "/lib/modules/${HOST_KERNEL}/build" ]]; then
    die "Для PROCESS_MONITOR_METHOD=ebpf нужны заголовки текущего ядра: /lib/modules/${HOST_KERNEL}/build. Установите kernel-default-devel для текущего ядра или используйте PROCESS_MONITOR_METHOD=proc."
  fi

  if [[ -x utils/packaging/build_modules.sh || -f utils/packaging/build_modules.sh ]]; then
    KERNEL_SHORT="$(printf '%s\n' "${HOST_KERNEL}" | sed -E 's/^([0-9]+\.[0-9]+).*/\1/')"
    [[ -n "${KERNEL_SHORT}" ]] || die "Не удалось определить major.minor версию ядра из HOST_KERNEL=${HOST_KERNEL}"

    say "Собираю eBPF-модули OpenSnitch для Linux ${HOST_KERNEL} (${KERNEL_SHORT})"
    chmod +x utils/packaging/build_modules.sh

    if ./utils/packaging/build_modules.sh "${KERNEL_SHORT}"; then
      if compgen -G "ebpf_prog/modules/opensnitch*.o" >/dev/null; then
        install -m 0644 ebpf_prog/modules/opensnitch*.o "${DAEMON_PAYLOAD}/usr/lib/opensnitchd/ebpf/"
        say "eBPF-модули упакованы в ${DAEMON_PAYLOAD}/usr/lib/opensnitchd/ebpf/"
      else
        if [[ "${PROCESS_MONITOR_METHOD}" == "ebpf" ]]; then
          die "eBPF build завершился без ebpf_prog/modules/opensnitch*.o, а PROCESS_MONITOR_METHOD=ebpf требует eBPF-модуль"
        fi
        warn "eBPF build завершился без opensnitch*.o, продолжаю без eBPF-модулей"
      fi
    else
      if [[ "${PROCESS_MONITOR_METHOD}" == "ebpf" ]]; then
        die "Не удалось собрать eBPF-модули, а PROCESS_MONITOR_METHOD=ebpf требует рабочий eBPF-модуль. Для обхода используйте PROCESS_MONITOR_METHOD=proc."
      fi
      warn "Не удалось собрать eBPF-модули, продолжаю без них"
    fi
  else
    if [[ "${PROCESS_MONITOR_METHOD}" == "ebpf" ]]; then
      die "utils/packaging/build_modules.sh не найден, а PROCESS_MONITOR_METHOD=ebpf требует eBPF-модуль"
    fi
    warn "utils/packaging/build_modules.sh не найден, eBPF-модули пропущены"
  fi
else
  if [[ "${PROCESS_MONITOR_METHOD}" == "ebpf" ]]; then
    die "SKIP_EBPF=1 несовместим с PROCESS_MONITOR_METHOD=ebpf"
  fi
  warn "SKIP_EBPF=1: eBPF-модули не будут включены в RPM"
fi

if [[ "${BUILD_UI}" == "1" ]]; then
  say "Готовлю UI"

  LRELEASE_BIN="$(
    command -v lrelease 2>/dev/null || \
    command -v lrelease6 2>/dev/null || \
    command -v lrelease-qt6 2>/dev/null || \
    find /usr/lib /usr/lib64 -path '*/qt6/bin/lrelease*' -type f -executable 2>/dev/null | head -n 1 || true
  )"

  if [[ -n "${LRELEASE_BIN}" && -d ui/i18n ]]; then
    export LRELEASE="${LRELEASE_BIN}"
    say "Собираю переводы UI через ${LRELEASE}"
    make -C ui/i18n || warn "Не удалось собрать переводы UI, продолжаю сборку"
  else
    warn "lrelease или каталог ui/i18n не найден, переводы UI не пересобираются"
  fi

  find ui/opensnitch/proto/ -name 'ui_pb2_grpc.py' \
    -exec sed -i 's/^import ui_pb2/from . import ui_pb2/' {} \; 2>/dev/null || true

  UI_INSTALL_ROOT="/work/ui-installroot"
  rm -rf "${UI_INSTALL_ROOT}"
  mkdir -p "${UI_INSTALL_ROOT}" "${UI_PAYLOAD}"

  (
    cd ui

    python3 setup.py build

    python3 setup.py install \
      --root="${UI_INSTALL_ROOT}" \
      --prefix=/usr \
      --single-version-externally-managed \
      --record=/work/opensnitch-ui-installed-files.txt
  )

  cp -a "${UI_INSTALL_ROOT}/." "${UI_PAYLOAD}/"
else
  say "BUILD_UI=0: сборка opensnitch-ui пропущена"
fi

make_filelist "${DAEMON_PAYLOAD}" "${FILELIST_DIR}/opensnitch.files"

DAEMON_AUDIT_REQUIRES=""
if [[ "${PROCESS_MONITOR_METHOD}" == "audit" ]]; then
  DAEMON_AUDIT_REQUIRES="Requires:       audit"
fi

cat > "${RPM_TOP}/SPECS/opensnitch.spec" <<EOF
Name:           opensnitch
Version:        ${RPM_VERSION}
Release:        ${RPM_RELEASE}%{?dist}
Summary:        OpenSnitch interactive application firewall daemon
License:        GPL-3.0-or-later
URL:            https://github.com/evilsocket/opensnitch

# Библиотечные зависимости opensnitchd намеренно не прописываются вручную:
# rpmbuild сам добавит auto-requires по фактически динамически связанным .so.
# Если opensnitchd собрался статически, этих зависимостей почти не будет.
Requires:       nftables
${DAEMON_AUDIT_REQUIRES}
Requires(post): systemd
Requires(preun): systemd
Requires(postun): systemd
Recommends:     logrotate

%description
OpenSnitch is an interactive application firewall for GNU/Linux.
This package contains the daemon and systemd service.

%prep

%build

%install
rm -rf %{buildroot}
mkdir -p %{buildroot}
cp -a ${DAEMON_PAYLOAD}/. %{buildroot}/

%post
if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload >/dev/null 2>&1 || true
    if [ "\$1" -eq 1 ]; then
        systemctl enable --now opensnitch.service >/dev/null 2>&1 || true
    else
        systemctl try-restart opensnitch.service >/dev/null 2>&1 || true
    fi
fi

%preun
if [ "\$1" -eq 0 ] && command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now opensnitch.service >/dev/null 2>&1 || true
fi

%postun
if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload >/dev/null 2>&1 || true
    if [ "\$1" -eq 1 ]; then
        systemctl try-restart opensnitch.service >/dev/null 2>&1 || true
    fi
fi

%files -f ${FILELIST_DIR}/opensnitch.files

%changelog
* $(date -u '+%a %b %d %Y') Local Builder <root@localhost> - ${RPM_VERSION}-${RPM_RELEASE}
- Local Docker build from ${RESOLVED_REF}
- Try static opensnitchd build first; let rpm auto-requires capture remaining dynamic libraries
EOF

say "Формирую RPM opensnitch"
rpmbuild -bb --define "_topdir ${RPM_TOP}" "${RPM_TOP}/SPECS/opensnitch.spec"

if [[ "${BUILD_UI}" == "1" ]]; then
  make_filelist "${UI_PAYLOAD}" "${FILELIST_DIR}/opensnitch-ui.files"

  cat > "${RPM_TOP}/SPECS/opensnitch-ui.spec" <<EOF
Name:           opensnitch-ui
Version:        ${RPM_VERSION}
Release:        ${RPM_RELEASE}%{?dist}
Summary:        OpenSnitch graphical user interface
License:        GPL-3.0-or-later
URL:            https://github.com/evilsocket/opensnitch
BuildArch:      noarch

# UI — Python/PyQt-приложение, его нельзя практически упаковать как один
# статический ELF-бинарник. Поэтому здесь оставлены только необходимые runtime-зависимости.
Requires:       python3
# На Tumbleweed Python-модули часто собираются как versioned-пакеты,
# например python313-PyQt6, а не как installable package python-PyQt6.
# Поэтому фиксируем зависимости UI на flavor текущего python3 из builder-контейнера.
Requires:       ${PY_FLAVOR}-PyQt6
Requires:       ${PY_FLAVOR}-grpcio
Requires:       ${PY_FLAVOR}-protobuf
Requires:       ${PY_FLAVOR}-packaging
Requires:       (${PY_FLAVOR}-python-slugify or ${PY_FLAVOR}-slugify or python3-python-slugify or python3-slugify)
Requires:       (${PY_FLAVOR}-pyinotify or python3-pyinotify or python3-inotify)
Requires:       (${PY_FLAVOR}-notify2 or python3-notify2)
Requires:       qt6-sql-sqlite
Recommends:     (qgnomeplatform-qt6 or QGnomePlatform-qt6)

%description
Graphical user interface and prompt service for OpenSnitch.

%prep

%build

%install
rm -rf %{buildroot}
mkdir -p %{buildroot}
cp -a ${UI_PAYLOAD}/. %{buildroot}/

%post
if [ "\$1" -ge 1 ]; then
    if command -v gtk-update-icon-cache >/dev/null 2>&1; then
        gtk-update-icon-cache /usr/share/icons/hicolor >/dev/null 2>&1 || true
    fi

    if [ -d /etc/xdg/autostart ] && [ ! -e /etc/xdg/autostart/opensnitch_ui.desktop ]; then
        ln -s /usr/share/applications/opensnitch_ui.desktop /etc/xdg/autostart/opensnitch_ui.desktop 2>/dev/null || true
    fi
fi

%postun
if [ "\$1" -eq 0 ]; then
    rm -f /etc/xdg/autostart/opensnitch_ui.desktop
    pkill -15 opensnitch-ui >/dev/null 2>&1 || true

    if command -v gtk-update-icon-cache >/dev/null 2>&1; then
        gtk-update-icon-cache /usr/share/icons/hicolor >/dev/null 2>&1 || true
    fi
fi

%files -f ${FILELIST_DIR}/opensnitch-ui.files

%changelog
* $(date -u '+%a %b %d %Y') Local Builder <root@localhost> - ${RPM_VERSION}-${RPM_RELEASE}
- Local Docker build from ${RESOLVED_REF}
- Explicit runtime dependencies for Python/PyQt UI
EOF

  say "Формирую RPM opensnitch-ui"
  rpmbuild -bb --define "_topdir ${RPM_TOP}" "${RPM_TOP}/SPECS/opensnitch-ui.spec"
fi

find "${RPM_TOP}/RPMS" -type f -name '*.rpm' -exec cp -v {} "${OUT_DIR}/" \;

cat > "${OUT_DIR}/manifest.txt" <<EOF
repo=${REPO_URL}
docker_base_image=${DOCKER_BASE_IMAGE}
docker_registry_prefix=${DOCKER_REGISTRY_PREFIX}
docker_from_image=${DOCKER_FROM_IMAGE}
ref=${RESOLVED_REF}
version=${VERSION}
rpm_version=${RPM_VERSION}
release=${RPM_RELEASE}
host_kernel=${HOST_KERNEL}
skip_ebpf=${SKIP_EBPF}
process_monitor_method=${PROCESS_MONITOR_METHOD}
build_ui=${BUILD_UI}
static_daemon=${STATIC_DAEMON}
go_build_tags=${GO_BUILD_TAGS}
protoc_gen_go=${PROTOC_GEN_GO_VERSION}
protoc_gen_go_grpc=${PROTOC_GEN_GO_GRPC_VERSION}
py_grpcio=${PY_GRPCIO_VERSION}
py_grpcio_tools=${PY_GRPCIO_TOOLS_VERSION}
py_protobuf=${PY_PROTOBUF_VERSION}
built_at_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
EOF

chown -R "${HOST_UID}:${HOST_GID}" "${OUT_DIR}" /work/cache /work/gomod /work/gocache /work/gopath 2>/dev/null || true

say "Готово. RPM лежат в ${OUT_DIR}"
CONTAINER_SCRIPT

mapfile -t RPM_FILES < <(find "${WORKDIR}/out" -maxdepth 1 -type f -name '*.rpm' | sort)

if [[ "${#RPM_FILES[@]}" -eq 0 ]]; then
  die "RPM-пакеты не найдены в ${WORKDIR}/out"
fi

say "Собранные RPM:"
printf '  %s\n' "${RPM_FILES[@]}"

if [[ -f "${WORKDIR}/out/opensnitchd.link-report.txt" ]]; then
  say "Отчёт по линковке daemon: ${WORKDIR}/out/opensnitchd.link-report.txt"
fi

if [[ "${INSTALL}" == "1" ]]; then
  if [[ "${BUILD_UI}" == "1" ]]; then
    zypper_install_ui_runtime_deps
  fi

  say "Устанавливаю/обновляю OpenSnitch через zypper"

  ZYPPER_ARGS=(install --allow-unsigned-rpm --force)

  if [[ "${MINIMAL_INSTALL}" == "1" ]]; then
    ZYPPER_ARGS+=(--no-recommends)
  fi

  as_root zypper -n "${ZYPPER_ARGS[@]}" "${RPM_FILES[@]}"

  say "Включаю и запускаю службу opensnitch.service"
  as_root systemctl daemon-reload
  as_root systemctl enable --now opensnitch.service

  say "Проверка службы:"
  systemctl --no-pager --full status opensnitch.service || true

  if [[ "${BUILD_UI}" == "1" ]]; then
    say "GUI можно запустить командой:"
    echo "  opensnitch-ui"
  fi
else
  say "INSTALL=0: установка пропущена"
fi

say "Готово"