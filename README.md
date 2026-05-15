# OpenSnitch RPM builder for openSUSE Tumbleweed

Этот каталог содержит два вспомогательных скрипта для локальной сборки и установки OpenSnitch на openSUSE Tumbleweed:

- `build-opensnitch-rpm-tw.sh` — получает исходный код OpenSnitch, собирает его внутри Docker-контейнера на базе `opensuse/tumbleweed`, формирует локальные RPM-пакеты и, при необходимости, устанавливает их через `zypper`.
- `clean-opensnitch-build.sh` — очищает рабочий каталог сборки, Docker image сборщика, контейнеры и опционально Docker build cache.

Сборочное окружение не устанавливается в основную систему: Go, Python build-зависимости, Qt-инструменты, `rpmbuild` и прочие пакеты ставятся только внутрь Docker image.

## Что собирается

По умолчанию собираются два пакета:

```text
opensnitch
opensnitch-ui
```

`opensnitch` содержит демон `opensnitchd`, systemd unit, конфигурационные файлы и правила.

`opensnitch-ui` содержит графический интерфейс OpenSnitch. Это Python/PyQt-приложение, поэтому оно не может быть превращено в один полностью статический ELF-бинарник. Runtime-зависимости UI вынесены в RPM-зависимости и подбираются под versioned Python-пакеты Tumbleweed, например `python313-PyQt6`.

## Особенности текущей версии

Текущий вариант сборочного скрипта делает следующее:

- сначала пробует собрать `opensnitchd` статически;
- если статическая линковка не удалась, собирает демон динамически;
- оставшиеся динамические `.so`-зависимости не прописывает вручную, а отдаёт на обработку `rpmbuild` auto-requires;
- для UI прописывает явные versioned Python/Qt зависимости;
- использует совместимую версию `protoc-gen-go-grpc`, чтобы не получить ошибки вида `undefined: grpc.SupportPackageIsVersion9`;
- запускает Docker-контейнер с `-i`, с UID/GID текущего пользователя и с отдельным `HOME=/work/home`;
- по умолчанию использует bind mount с суффиксом `rw,Z`, что помогает на системах с SELinux-контекстами;
- оставляет отчёт по линковке демона в `opensnitch-rpm-work/out/opensnitchd.link-report.txt`.

## Требования на хосте

На основной системе нужны только:

```bash
sudo zypper in docker zypper sudo
sudo systemctl enable --now docker
```

Если пользователь не входит в группу `docker`, запускайте скрипт через пользователя, которому доступен Docker, или добавьте пользователя в группу и перелогиньтесь:

```bash
sudo usermod -aG docker "$USER"
```

Для установки RPM нужен `zypper` и права `sudo`.

## Быстрый старт

Сделайте скрипты исполняемыми:

```bash
chmod +x build-opensnitch-rpm-tw.sh clean-opensnitch-build.sh
```

Первая сборка с пересозданием Docker image:

```bash
REBUILD_BUILDER=1 ./build-opensnitch-rpm-tw.sh
```

Обычный повторный запуск:

```bash
./build-opensnitch-rpm-tw.sh
```

Скрипт сам:

1. создаст рабочий каталог `opensnitch-rpm-work`;
2. соберёт Docker image `local/opensnitch-rpm-builder:tumbleweed`;
3. клонирует OpenSnitch;
4. сгенерирует protobuf-код;
5. соберёт daemon и UI;
6. сформирует RPM;
7. установит их через `zypper`, если `INSTALL=1`.

Собранные пакеты будут лежать здесь:

```bash
ls -lh opensnitch-rpm-work/out/
```

## Основные режимы сборки

Собрать, но не устанавливать:

```bash
INSTALL=0 ./build-opensnitch-rpm-tw.sh
```

Собрать конкретную версию OpenSnitch:

```bash
REF=v1.8.0 ./build-opensnitch-rpm-tw.sh
```

Собрать ветку `master`:

```bash
REF=master ./build-opensnitch-rpm-tw.sh
```

Собрать только демон без UI:

```bash
BUILD_UI=0 ./build-opensnitch-rpm-tw.sh
```

Принудительно динамическая сборка демона:

```bash
STATIC_DAEMON=0 ./build-opensnitch-rpm-tw.sh
```

Требовать строго статическую сборку демона и падать при неудаче:

```bash
STATIC_DAEMON=1 ./build-opensnitch-rpm-tw.sh
```

Автоматический режим, используемый по умолчанию:

```bash
STATIC_DAEMON=auto ./build-opensnitch-rpm-tw.sh
```

Пропустить сборку eBPF-модулей:

```bash
SKIP_EBPF=1 ./build-opensnitch-rpm-tw.sh
```

Отключить SELinux-релабелинг bind mount, если Docker ругается на `:Z`:

```bash
DOCKER_MOUNT_SUFFIX=rw ./build-opensnitch-rpm-tw.sh
```

## Важные переменные

| Переменная | По умолчанию | Назначение |
|---|---:|---|
| `REPO_URL` | `https://github.com/evilsocket/opensnitch.git` | URL репозитория OpenSnitch |
| `REF` | `latest` | Git tag, branch или commit |
| `WORKDIR` | `$PWD/opensnitch-rpm-work` | Рабочий каталог сборки |
| `BUILDER_IMAGE` | `local/opensnitch-rpm-builder:tumbleweed` | Docker image сборщика |
| `INSTALL` | `1` | Устанавливать RPM после сборки |
| `REBUILD_BUILDER` | `0` | Пересобрать Docker image |
| `BUILD_UI` | `1` | Собирать `opensnitch-ui` |
| `STATIC_DAEMON` | `auto` | `auto`, `1` или `0` для режима линковки демона |
| `MINIMAL_INSTALL` | `1` | Использовать `zypper --no-recommends` |
| `SKIP_EBPF` | `0` | Пропустить eBPF-модули |
| `DOCKER_MOUNT_SUFFIX` | `rw,Z` | Суффикс Docker bind mount |
| `RUN_AS_USER` | `1` | Запускать сборку внутри контейнера от UID/GID пользователя |
| `PROTOC_GEN_GO_VERSION` | `v1.31.0` | Версия `protoc-gen-go` |
| `PROTOC_GEN_GO_GRPC_VERSION` | `v1.3.0` | Версия `protoc-gen-go-grpc` |
| `GO_BUILD_TAGS` | `netgo osusergo` | Go build tags |

## Ручная установка собранных RPM

Если сборка выполнялась с `INSTALL=0`, установите пакеты вручную через `zypper`, а не через `rpm -Uvh`, чтобы зависимости искались в репозиториях:

```bash
cd opensnitch-rpm-work/out
sudo zypper ref
sudo zypper install --allow-unsigned-rpm ./*.rpm
```

Для минимальной установки без рекомендуемых пакетов:

```bash
sudo zypper install --no-recommends --allow-unsigned-rpm ./*.rpm
```

Посмотреть зависимости пакетов:

```bash
rpm -qpR ./*.rpm | sort -u
```

Найти пакет, который предоставляет зависимость:

```bash
zypper wp 'libexample.so.1()(64bit)'
zypper search --provides 'python3dist(PyQt6)'
```

## Проверка после установки

Проверьте daemon:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now opensnitch.service
systemctl status opensnitch.service --no-pager
```

Запустите UI:

```bash
opensnitch-ui
```

Проверьте, что PyQt6 импортируется системным Python:

```bash
python3 -c 'from PyQt6 import QtWidgets, QtCore; print("PyQt6 OK")'
```

## Если UI не стартует из-за PyQt6

Типичная ошибка:

```text
ModuleNotFoundError: No module named 'PyQt6'
```

На Tumbleweed пакет может называться не `python-PyQt6`, а versioned-именем вроде `python313-PyQt6`.

Узнайте flavor текущего `python3`:

```bash
python3 - <<'PY'
import sys
print(f"python{sys.version_info.major}{sys.version_info.minor}")
PY
```

Если команда вывела, например, `python313`, установите:

```bash
sudo zypper in python313-PyQt6
```

Можно искать поставщика так:

```bash
zypper se -s python313-PyQt6
zypper search --provides 'python3dist(PyQt6)'
zypper search --provides 'python3dist(pyqt6)'
```

Дополнительные UI-зависимости, которые могут понадобиться:

```bash
sudo zypper in \
  python313-PyQt6 \
  python313-grpcio \
  python313-protobuf \
  python313-packaging \
  python313-notify2 \
  python313-python-slugify \
  python313-pyinotify \
  qt6-sql-sqlite
```

Замените `python313` на flavor, который показал ваш `python3`.

## Диагностика линковки демона

Скрипт сохраняет отчёты:

```bash
cat opensnitch-rpm-work/out/opensnitchd.file.txt
cat opensnitch-rpm-work/out/opensnitchd.ldd.txt
cat opensnitch-rpm-work/out/opensnitchd.link-report.txt
```

Если `opensnitchd` собрался статически, `ldd` обычно покажет что-то вроде:

```text
not a dynamic executable
```

Если демон собрался динамически, оставшиеся `.so` будут видны в `ldd`, а RPM должен получить auto-requires на соответствующие библиотеки.

## Диагностика protobuf/grpc

Если при сборке daemon появляются ошибки вроде:

```text
undefined: grpc.SupportPackageIsVersion9
undefined: grpc.BidiStreamingClient
```

значит сгенерированный Go gRPC-код не совместим с версией `grpc-go`, зафиксированной в OpenSnitch.

По умолчанию используется:

```bash
PROTOC_GEN_GO_VERSION=v1.31.0
PROTOC_GEN_GO_GRPC_VERSION=v1.3.0
```

Можно попробовать более старый генератор:

```bash
PROTOC_GEN_GO_GRPC_VERSION=v1.2.0 ./build-opensnitch-rpm-tw.sh
```

## Очистка

Обычная очистка с подтверждениями:

```bash
./clean-opensnitch-build.sh
```

Очистка без вопросов:

```bash
YES=1 ./clean-opensnitch-build.sh
```

Очистка рабочего каталога и Docker image сборщика:

```bash
YES=1 ./clean-opensnitch-build.sh
```

Очистка вместе с Docker build cache:

```bash
PRUNE_BUILD_CACHE=1 YES=1 ./clean-opensnitch-build.sh
```

Скрипт очистки специально проверяет опасные пути и отказывается удалять `/`, `/home`, `/root`, `/usr`, `/var`, `/etc`, `/opt`, `/tmp` и сам `$HOME`.

## Что делать при проблемах с правами на `/work`

Если внутри контейнера появляется ошибка вида:

```text
mkdir: cannot create directory '/work/payload': Permission denied
```

попробуйте:

```bash
sudo chown -R "$(id -u):$(id -g)" opensnitch-rpm-work
./build-opensnitch-rpm-tw.sh
```

Если Docker ругается на `:Z` в bind mount:

```bash
DOCKER_MOUNT_SUFFIX=rw ./build-opensnitch-rpm-tw.sh
```

## Удаление установленных пакетов

Остановить службу и удалить пакеты:

```bash
sudo systemctl disable --now opensnitch.service
sudo zypper rm opensnitch opensnitch-ui
```

После удаления можно почистить сборочные артефакты:

```bash
YES=1 ./clean-opensnitch-build.sh
```

## Примечания по безопасности

Собранные RPM являются локальными и неподписанными. Для установки используется:

```bash
sudo zypper install --allow-unsigned-rpm ./*.rpm
```

Для личной локальной сборки это нормально. Для распространения пакетов лучше настроить собственную подпись RPM и локальный репозиторий.