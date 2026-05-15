#!/usr/bin/env bash
set -Eeuo pipefail

# clean-opensnitch-build.sh
#
# Очистка локальной сборки OpenSnitch RPM:
#   - рабочий каталог проекта
#   - Docker-контейнеры сборщика
#   - Docker image сборщика
#   - Docker volumes по заданному префиксу
#   - опционально BuildKit/build cache
#
# Примеры:
#   ./clean-opensnitch-build.sh
#   YES=1 ./clean-opensnitch-build.sh
#   WORKDIR=/path/to/opensnitch-rpm-work YES=1 ./clean-opensnitch-build.sh
#   PRUNE_BUILD_CACHE=1 YES=1 ./clean-opensnitch-build.sh
#
# Переменные:
#   WORKDIR             каталог проекта/сборки
#   BUILDER_IMAGE       Docker image сборщика
#   VOLUME_PREFIX       префикс томов, которые можно удалить
#   REMOVE_VOLUMES      1 = удалить volumes с VOLUME_PREFIX
#   PRUNE_BUILD_CACHE   1 = почистить Docker build cache
#   YES                 1 = не спрашивать подтверждение

WORKDIR="${WORKDIR:-$PWD/opensnitch-rpm-work}"
BUILDER_IMAGE="${BUILDER_IMAGE:-local/opensnitch-rpm-builder:tumbleweed}"
VOLUME_PREFIX="${VOLUME_PREFIX:-opensnitch-rpm}"
REMOVE_VOLUMES="${REMOVE_VOLUMES:-1}"
PRUNE_BUILD_CACHE="${PRUNE_BUILD_CACHE:-0}"
YES="${YES:-0}"

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

confirm() {
  local prompt="$1"

  if [[ "${YES}" == "1" ]]; then
    return 0
  fi

  echo
  warn "${prompt}"
  read -r -p "Введите YES для продолжения: " answer

  [[ "${answer}" == "YES" ]]
}

safe_abs_path() {
  local path="$1"

  if command -v realpath >/dev/null 2>&1; then
    realpath -m -- "${path}"
  else
    python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "${path}"
  fi
}

check_safe_dir() {
  local dir="$1"
  local abs

  abs="$(safe_abs_path "${dir}")"

  case "${abs}" in
    /|/home|/root|/usr|/usr/local|/var|/etc|/opt|/tmp|"$HOME")
      die "Отказываюсь удалять опасный каталог: ${abs}"
      ;;
  esac

  if [[ "${abs}" == "/"* ]]; then
    printf '%s\n' "${abs}"
  else
    die "Не удалось получить абсолютный путь для: ${dir}"
  fi
}

remove_workdir() {
  local abs_workdir

  abs_workdir="$(check_safe_dir "${WORKDIR}")"

  if [[ ! -e "${abs_workdir}" ]]; then
    say "Каталог сборки уже отсутствует: ${abs_workdir}"
    return 0
  fi

  confirm "Будет удалён каталог сборки: ${abs_workdir}" || die "Отменено пользователем"

  say "Удаляю каталог сборки: ${abs_workdir}"
  as_root rm -rf --one-file-system -- "${abs_workdir}"
}

docker_available() {
  command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1
}

remove_builder_containers() {
  local containers=()

  if ! docker image inspect "${BUILDER_IMAGE}" >/dev/null 2>&1; then
    say "Docker image не найден, контейнеры по ancestor искать не буду: ${BUILDER_IMAGE}"
    return 0
  fi

  mapfile -t containers < <(docker ps -aq --filter "ancestor=${BUILDER_IMAGE}" || true)

  if [[ "${#containers[@]}" -eq 0 ]]; then
    say "Контейнеры от ${BUILDER_IMAGE} не найдены"
    return 0
  fi

  say "Найдены контейнеры от ${BUILDER_IMAGE}:"
  printf '  %s\n' "${containers[@]}"

  confirm "Будут принудительно удалены эти контейнеры" || die "Отменено пользователем"

  docker rm -f "${containers[@]}"
}

remove_builder_image() {
  if ! docker image inspect "${BUILDER_IMAGE}" >/dev/null 2>&1; then
    say "Docker image уже отсутствует: ${BUILDER_IMAGE}"
    return 0
  fi

  say "Найден Docker image:"
  docker image ls "${BUILDER_IMAGE}"

  confirm "Будет удалён Docker image: ${BUILDER_IMAGE}" || die "Отменено пользователем"

  docker image rm -f "${BUILDER_IMAGE}"
}

remove_named_volumes() {
  local volumes=()

  if [[ "${REMOVE_VOLUMES}" != "1" ]]; then
    say "REMOVE_VOLUMES=${REMOVE_VOLUMES}: удаление Docker volumes пропущено"
    return 0
  fi

  mapfile -t volumes < <(
    docker volume ls -q \
      | grep -E "^${VOLUME_PREFIX}([_-].*)?$" || true
  )

  if [[ "${#volumes[@]}" -eq 0 ]]; then
    say "Docker volumes с префиксом '${VOLUME_PREFIX}' не найдены"
    return 0
  fi

  say "Найдены Docker volumes для удаления:"
  printf '  %s\n' "${volumes[@]}"

  confirm "Будут удалены только volumes с префиксом '${VOLUME_PREFIX}'" || die "Отменено пользователем"

  docker volume rm -f "${volumes[@]}"
}

prune_build_cache() {
  if [[ "${PRUNE_BUILD_CACHE}" != "1" ]]; then
    say "PRUNE_BUILD_CACHE=${PRUNE_BUILD_CACHE}: Docker build cache не очищается"
    return 0
  fi

  confirm "Будет очищен Docker build cache. Это может затронуть кэш сборки других проектов" || die "Отменено пользователем"

  docker builder prune -af
}

main() {
  say "Параметры очистки:"
  echo "  WORKDIR=${WORKDIR}"
  echo "  BUILDER_IMAGE=${BUILDER_IMAGE}"
  echo "  VOLUME_PREFIX=${VOLUME_PREFIX}"
  echo "  REMOVE_VOLUMES=${REMOVE_VOLUMES}"
  echo "  PRUNE_BUILD_CACHE=${PRUNE_BUILD_CACHE}"
  echo "  YES=${YES}"

  remove_workdir

  if docker_available; then
    remove_builder_containers
    remove_builder_image
    remove_named_volumes
    prune_build_cache
  else
    warn "Docker недоступен или демон не запущен. Docker-очистка пропущена."
  fi

  say "Очистка завершена"
}

main "$@"