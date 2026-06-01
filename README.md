# OpenSnitch RPM builder for openSUSE Tumbleweed

Проект содержит скрипт локальной сборки OpenSnitch в Docker и, при наличии рядом, скрипт очистки сборочного окружения.

Основной сценарий:

- `build-opensnitch-rpm-tw.sh` получает исходный код OpenSnitch из Git;
- собирает `opensnitchd` и `opensnitch-ui` внутри Docker-контейнера на базе openSUSE Tumbleweed;
- формирует локальные RPM-пакеты;
- при `INSTALL=1` устанавливает или обновляет их через `zypper`;
- не устанавливает сборочное окружение в основную систему.

Сборщик рассчитан на openSUSE Tumbleweed.

## Что собирается

По умолчанию формируются два RPM-пакета:

```text
opensnitch
opensnitch-ui
```

`opensnitch` содержит демон `opensnitchd`, systemd unit, конфигурационные файлы, правила, задачи и, при выбранном `PROCESS_MONITOR_METHOD=ebpf`, eBPF-модули.

`opensnitch-ui` содержит графический интерфейс OpenSnitch. UI является Python/PyQt-приложением, поэтому он не собирается в один статический ELF-бинарник. Зависимости UI вынесены в RPM-зависимости и подбираются под versioned Python-пакеты Tumbleweed, например `python313-PyQt6`.

## Ключевые особенности текущего сборщика

Текущий `build-opensnitch-rpm-tw.sh` делает следующее:

- генерирует Dockerfile динамически;
- позволяет задать альтернативный registry или полностью заменить базовый Docker-образ;
- сначала пробует собрать `opensnitchd` статически;
- если статическая линковка не удалась, собирает демон динамически;
- оставшиеся динамические `.so`-зависимости отдаёт на обработку `rpmbuild` auto-requires;
- прописывает явные versioned Python/Qt-зависимости для UI;
- использует совместимые версии генераторов protobuf/gRPC;
- запускает Docker-контейнер с `-i`, с UID/GID текущего пользователя и с `HOME=/work/home`;
- по умолчанию использует bind mount `rw,Z`, что полезно на системах с SELinux;
- параметризует метод мониторинга процессов через `PROCESS_MONITOR_METHOD`;
- для eBPF-сборки пробрасывает в контейнер `/lib/modules/<текущее-ядро>`, `/usr/src` и `/sys/kernel/btf`, если они есть;
- сохраняет отчёты о линковке демона в `opensnitch-rpm-work/out/`;
- сохраняет сведения о сборке в `opensnitch-rpm-work/out/manifest.txt`.

## Требования на хосте

Минимально нужны Docker, `zypper` и `sudo`:

```bash
sudo zypper in docker sudo
sudo systemctl enable --now docker
```

Если пользователь не входит в группу `docker`, добавьте его и перелогиньтесь:

```bash
sudo usermod -aG docker "$USER"
```

Для установки собранных RPM нужны права `sudo`.

Для режима `PROCESS_MONITOR_METHOD=ebpf` также нужны заголовки текущего ядра. На Tumbleweed обычно это пакет вида:

```bash
sudo zypper in kernel-default-devel
```

Проверьте, что ссылка на build-каталог ядра существует:

```bash
ls -l "/lib/modules/$(uname -r)/build"
```

## Быстрый старт

Сделайте скрипт исполняемым:

```bash
chmod +x build-opensnitch-rpm-tw.sh
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
2. сформирует Dockerfile;
3. соберёт локальный Docker image `local/opensnitch-rpm-builder:tumbleweed`;
4. клонирует OpenSnitch;
5. сгенерирует protobuf-код;
6. соберёт daemon и UI;
7. сформирует RPM;
8. установит их через `zypper`, если `INSTALL=1`;
9. включит и запустит `opensnitch.service`.

Собранные RPM и отчёты будут здесь:

```bash
ls -lh opensnitch-rpm-work/out/
```

## Альтернативный Docker registry или базовый образ

По умолчанию сборщик использует базовый образ:

```text
opensuse/tumbleweed
```

### Registry mirror / proxy

Если Docker Hub недоступен или нужно использовать корпоративный proxy/mirror:

```bash
DOCKER_REGISTRY_PREFIX=harbor.example.org/docker-hub-proxy \
  REBUILD_BUILDER=1 ./build-opensnitch-rpm-tw.sh
```

В таком режиме Dockerfile будет начинаться с:

```Dockerfile
FROM harbor.example.org/docker-hub-proxy/opensuse/tumbleweed
```

### Полная замена базового образа

Если нужен полностью квалифицированный образ:

```bash
DOCKER_BASE_IMAGE=registry.example.org/opensuse/tumbleweed \
  REBUILD_BUILDER=1 ./build-opensnitch-rpm-tw.sh
```

В таком режиме Dockerfile будет начинаться с:

```Dockerfile
FROM registry.example.org/opensuse/tumbleweed
```

### Важные замечания

`DOCKER_REGISTRY_PREFIX` влияет только на образ, из которого строится локальный builder image.

Он не меняет:

- URL исходников OpenSnitch;
- репозитории `zypper` внутри контейнера;
- источники Go-модулей;
- Python/PyPI-источники, если они понадобятся внутри контейнера.

Если нужно изменить openSUSE-репозитории внутри контейнера, используйте собственный `DOCKER_BASE_IMAGE`, где уже настроены нужные репозитории.

Не задавайте одновременно `DOCKER_REGISTRY_PREFIX` и уже полностью квалифицированный `DOCKER_BASE_IMAGE`, иначе можно получить путь вида:

```text
mirror.example/registry.example.org/opensuse/tumbleweed
```

Итоговый локальный builder image по умолчанию остаётся:

```text
local/opensnitch-rpm-builder:tumbleweed
```

Изменить его можно переменной `BUILDER_IMAGE`.

## Основные режимы сборки

Собрать, но не устанавливать:

```bash
INSTALL=0 ./build-opensnitch-rpm-tw.sh
```

Собрать конкретный tag OpenSnitch:

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

Пересобрать Docker image сборщика:

```bash
REBUILD_BUILDER=1 ./build-opensnitch-rpm-tw.sh
```

Отключить SELinux-релабелинг bind mount, если Docker ругается на `:Z`:

```bash
DOCKER_MOUNT_SUFFIX=rw ./build-opensnitch-rpm-tw.sh
```

Запустить сборку внутри контейнера от root, а не от UID/GID пользователя:

```bash
RUN_AS_USER=0 ./build-opensnitch-rpm-tw.sh
```

## Режим линковки daemon

По умолчанию:

```bash
STATIC_DAEMON=auto
```

Доступные режимы:

| Значение | Поведение |
|---|---|
| `auto` | сначала пробует статическую линковку, при неудаче собирает динамически |
| `1` | требует строго статический `opensnitchd`, при неудаче завершает сборку ошибкой |
| `0` | сразу собирает `opensnitchd` динамически |

Примеры:

```bash
STATIC_DAEMON=auto ./build-opensnitch-rpm-tw.sh
STATIC_DAEMON=1 ./build-opensnitch-rpm-tw.sh
STATIC_DAEMON=0 ./build-opensnitch-rpm-tw.sh
```

Отчёты по линковке:

```bash
cat opensnitch-rpm-work/out/opensnitchd.file.txt
cat opensnitch-rpm-work/out/opensnitchd.ldd.txt
cat opensnitch-rpm-work/out/opensnitchd.link-report.txt
```

Если демон собрался статически, `ldd` обычно покажет:

```text
not a dynamic executable
```

Если демон собрался динамически, оставшиеся `.so` попадут в RPM auto-requires.

## Метод мониторинга процессов

OpenSnitch поддерживает несколько методов мониторинга процессов. Сборщик параметризует их через:

```bash
PROCESS_MONITOR_METHOD=ebpf
```

Допустимые значения:

| Метод | Что делает | Когда использовать |
|---|---|---|
| `ebpf` | Использует eBPF-модуль OpenSnitch | Режим по умолчанию. Лучший вариант, если модуль успешно собирается и загружается |
| `proc` | Использует `/proc` | Практичный fallback для новых ядер, если eBPF-модуль не загружается |
| `audit` | Использует audit subsystem | Альтернатива, если в системе уже используется audit |

Примеры:

```bash
PROCESS_MONITOR_METHOD=ebpf ./build-opensnitch-rpm-tw.sh
PROCESS_MONITOR_METHOD=proc ./build-opensnitch-rpm-tw.sh
PROCESS_MONITOR_METHOD=audit ./build-opensnitch-rpm-tw.sh
```

### Поведение `SKIP_EBPF`

Если `SKIP_EBPF` не задан явно, сборщик выбирает значение автоматически:

| `PROCESS_MONITOR_METHOD` | Значение `SKIP_EBPF` по умолчанию |
|---|---:|
| `ebpf` | `0` |
| `proc` | `1` |
| `audit` | `1` |

При `PROCESS_MONITOR_METHOD=ebpf` нельзя использовать `SKIP_EBPF=1`: сборщик остановится, потому что eBPF-режим требует собранный и упакованный eBPF-модуль.

### Что делает сборщик для выбранного метода

Сборщик:

- прописывает `-process-monitor-method <method>` в systemd unit;
- обновляет `ProcMonitorMethod` в `default-config.json`;
- при `audit` добавляет зависимость RPM на пакет `audit`;
- при `ebpf` требует наличие `/lib/modules/<kernel>/build` и успешную сборку eBPF-модуля;
- при `proc` или `audit` по умолчанию не собирает eBPF-модули.

Проверить фактический метод после установки:

```bash
systemctl cat opensnitch.service | grep ExecStart
grep -i ProcMonitorMethod /etc/opensnitchd/default-config.json
```

Если после установки появляется предупреждение:

```text
[eBPF] Error loading opensnitch.o: unable to load eBPF module
```

пересоберите пакет с fallback-методом:

```bash
PROCESS_MONITOR_METHOD=proc ./build-opensnitch-rpm-tw.sh
```

## Переменные сборщика

| Переменная | По умолчанию | Назначение |
|---|---:|---|
| `REPO_URL` | `https://github.com/evilsocket/opensnitch.git` | URL репозитория OpenSnitch |
| `REF` | `latest` | Git tag, branch или commit |
| `DOCKER_BASE_IMAGE` | `opensuse/tumbleweed` | Базовый образ Dockerfile |
| `DOCKER_REGISTRY_PREFIX` | пусто | Префикс альтернативного registry/mirror для базового образа |
| `WORKDIR` | `$PWD/opensnitch-rpm-work` | Рабочий каталог сборки |
| `BUILDER_IMAGE` | `local/opensnitch-rpm-builder:tumbleweed` | Локальный Docker image сборщика |
| `INSTALL` | `1` | Устанавливать RPM после сборки |
| `REBUILD_BUILDER` | `0` | Пересобрать Docker image сборщика |
| `BUILD_UI` | `1` | Собирать `opensnitch-ui` |
| `STATIC_DAEMON` | `auto` | Режим линковки daemon: `auto`, `1`, `0` |
| `MINIMAL_INSTALL` | `1` | Использовать `zypper --no-recommends` при установке локальных RPM |
| `PROCESS_MONITOR_METHOD` | `ebpf` | Метод мониторинга процессов: `ebpf`, `audit`, `proc` |
| `SKIP_EBPF` | зависит от `PROCESS_MONITOR_METHOD` | Пропустить eBPF-модули |
| `RPM_RELEASE` | `1.local<UTC timestamp>` | Release RPM-пакета |
| `HOST_KERNEL` | `$(uname -r)` | Версия ядра хоста для eBPF-сборки |
| `DOCKER_MOUNT_SUFFIX` | `rw,Z` | Суффикс Docker bind mount для `/work` |
| `RUN_AS_USER` | `1` | Запускать сборку в контейнере от UID/GID текущего пользователя |
| `PROTOC_GEN_GO_VERSION` | `v1.31.0` | Версия `protoc-gen-go` |
| `PROTOC_GEN_GO_GRPC_VERSION` | `v1.3.0` | Версия `protoc-gen-go-grpc` |
| `GO_BUILD_TAGS` | `netgo osusergo` | Go build tags |
| `PY_GRPCIO_VERSION` | `1.80.0` | Версия `grpcio` в builder image для генерации Python gRPC-кода |
| `PY_GRPCIO_TOOLS_VERSION` | равно `PY_GRPCIO_VERSION` | Версия `grpcio-tools`; должна быть не выше runtime `grpcio` из репозитория |
| `PY_PROTOBUF_VERSION` | пусто | Опциональная фиксация версии `protobuf` в builder image |

## Установка собранных RPM вручную

Если сборка выполнялась с `INSTALL=0`, устанавливайте через `zypper`, а не через `rpm -Uvh`, чтобы зависимости искались в подключённых репозиториях:

```bash
cd opensnitch-rpm-work/out
sudo zypper ref
sudo zypper install --allow-unsigned-rpm ./*.rpm
```

Минимальная установка без рекомендуемых пакетов:

```bash
sudo zypper install --no-recommends --allow-unsigned-rpm ./*.rpm
```

Посмотреть зависимости RPM:

```bash
rpm -qpR ./*.rpm | sort -u
```

Найти пакет, который предоставляет зависимость:

```bash
zypper wp 'libexample.so.1()(64bit)'
zypper search --provides 'python3dist(PyQt6)'
```

## Проверка после установки

Проверить daemon:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now opensnitch.service
systemctl status opensnitch.service --no-pager
```

Проверить, как запущен daemon:

```bash
systemctl cat opensnitch.service | grep ExecStart
```

Запустить UI:

```bash
opensnitch-ui
```

Проверить импорт PyQt6:

```bash
python3 -c 'from PyQt6 import QtWidgets, QtCore; print("PyQt6 OK")'
```

Посмотреть итоговый manifest сборки:

```bash
cat opensnitch-rpm-work/out/manifest.txt
```

В manifest сохраняются, среди прочего:

- `repo`;
- `docker_base_image`;
- `docker_registry_prefix`;
- `docker_from_image`;
- `ref`;
- `version`;
- `host_kernel`;
- `skip_ebpf`;
- `process_monitor_method`;
- `build_ui`;
- `static_daemon`.

## Если UI не стартует из-за PyQt6

Типичная ошибка:

```text
ModuleNotFoundError: No module named 'PyQt6'
```

На Tumbleweed пакет обычно называется versioned-именем вроде `python313-PyQt6`.

Узнать flavor текущего `python3`:

```bash
python3 - <<'PY'
import sys
print(f"python{sys.version_info.major}{sys.version_info.minor}")
PY
```

Если команда вывела `python313`, установите:

```bash
sudo zypper in python313-PyQt6
```

Можно искать поставщика так:

```bash
zypper se -s python313-PyQt6
zypper search --provides 'python3dist(PyQt6)'
zypper search --provides 'python3dist(pyqt6)'
```

Дополнительные UI-зависимости:

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

## Диагностика protobuf/gRPC

Если при сборке daemon появляются ошибки вида:

```text
undefined: grpc.SupportPackageIsVersion9
undefined: grpc.BidiStreamingClient
```

значит сгенерированный Go gRPC-код не совместим с версией `grpc-go`, зафиксированной в OpenSnitch.

По умолчанию используются:

```bash
PROTOC_GEN_GO_VERSION=v1.31.0
PROTOC_GEN_GO_GRPC_VERSION=v1.3.0
```

Можно попробовать более старый генератор:

```bash
PROTOC_GEN_GO_GRPC_VERSION=v1.2.0 ./build-opensnitch-rpm-tw.sh
```

## Проблемы с eBPF

Проверить наличие заголовков текущего ядра:

```bash
ls -l "/lib/modules/$(uname -r)/build"
```

Если eBPF не собирается или не загружается, используйте fallback:

```bash
PROCESS_MONITOR_METHOD=proc ./build-opensnitch-rpm-tw.sh
```

Если хотите строго собрать eBPF и не продолжать при ошибке, используйте режим по умолчанию:

```bash
PROCESS_MONITOR_METHOD=ebpf ./build-opensnitch-rpm-tw.sh
```

При `ebpf` сборщик завершится ошибкой, если модуль не собрался или не попал в пакет.

## Проблемы с правами на `/work`

Если внутри контейнера появляется ошибка вида:

```text
mkdir: cannot create directory '/work/payload': Permission denied
```

исправьте владельца рабочего каталога:

```bash
sudo chown -R "$(id -u):$(id -g)" opensnitch-rpm-work
./build-opensnitch-rpm-tw.sh
```

Если Docker ругается на `:Z`:

```bash
DOCKER_MOUNT_SUFFIX=rw ./build-opensnitch-rpm-tw.sh
```

## Очистка сборочных артефактов

Если рядом есть `clean-opensnitch-build.sh`, обычная очистка запускается так:

```bash
./clean-opensnitch-build.sh
```

Без вопросов:

```bash
YES=1 ./clean-opensnitch-build.sh
```

С очисткой Docker build cache:

```bash
PRUNE_BUILD_CACHE=1 YES=1 ./clean-opensnitch-build.sh
```

Скрипт очистки должен удалять рабочий каталог, builder image, контейнеры сборщика и, если включено, build cache.

## Удаление установленных пакетов

Остановить службу и удалить пакеты:

```bash
sudo systemctl disable --now opensnitch.service
sudo zypper rm opensnitch opensnitch-ui
```

После этого можно удалить сборочные артефакты:

```bash
YES=1 ./clean-opensnitch-build.sh
```

## Безопасность и подпись RPM

Собранные RPM являются локальными и неподписанными. Для установки используется:

```bash
sudo zypper install --allow-unsigned-rpm ./*.rpm
```

Для личного локального использования это нормально. Для распространения пакетов лучше настроить собственную подпись RPM и локальный репозиторий.


## Ошибка grpcio / grpcio-tools в opensnitch-ui

Если `opensnitch-ui` падает с сообщением вида:

```text
The grpc package installed is at version 1.80.0, but the generated code in ui_pb2_grpc.py depends on grpcio>=1.81.0
```

значит Python gRPC-код был сгенерирован в Docker builder более новой версией `grpcio-tools`, чем версия `grpcio`, доступная в репозиториях Tumbleweed на итоговой системе.

В исправленном сборщике Python gRPC-генератор зафиксирован параметрами:

```bash
PY_GRPCIO_VERSION=1.80.0
PY_GRPCIO_TOOLS_VERSION=1.80.0
```

При изменении этих параметров нужно пересобирать Docker image сборщика, потому что `grpcio-tools` устанавливается внутрь builder image:

```bash
PY_GRPCIO_VERSION=1.80.0 \
PY_GRPCIO_TOOLS_VERSION=1.80.0 \
REBUILD_BUILDER=1 \
./build-opensnitch-rpm-tw.sh
```

Если в репозиториях Tumbleweed обновится `python313-grpcio`, можно поднять версии генератора, но `PY_GRPCIO_TOOLS_VERSION` должен быть не выше runtime-версии `grpcio`, установленной в системе.

Проверить runtime-версию можно так:

```bash
python3 - <<'PY'
import grpc
print(grpc.__version__)
PY
```