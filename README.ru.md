# Fluxer Self-Hosting Installer

Single-shot, полностью non-interactive installer для развёртывания [Fluxer](https://github.com/fluxerapp/fluxer) на чистом Ubuntu 24.04 VPS. Скопируй скрипт в root-shell, укажи домен, у которого A-запись уже указывает на этот хост, и через ~10 минут на выходе рабочий инстанс с TLS, голосом, файловым хранилищем и админ-доступом.

[English README](README.md)

## TL;DR

```bash
curl -fsSL https://raw.githubusercontent.com/<your-fork>/fluxer-installer/main/install.sh \
  -o install.sh
bash install.sh --domain chat.example.com --email admin@example.com
```

По завершении открой `https://chat.example.com` и зарегистрируйся. Первый созданный аккаунт становится админом.

## Требования

| Компонент        | Минимум                                                                                                                                    |
| ---------------- | ------------------------------------------------------------------------------------------------------------------------------------------ |
| ОС               | Ubuntu 24.04 LTS (Noble), x86_64                                                                                                           |
| Привилегии       | `root` (скрипт вызывает `apt`, правит `/etc/sysctl.d/`, управляет systemd-юнитами)                                                         |
| CPU / RAM / Диск | 4 vCPU, 8 GiB RAM, 80 GiB NVMe (Для SeaweedFS)                                                                                             |
| Сеть             | Публичный IPv4, порты 22 / 80 / 443 / 7881-tcp / 7882-udp снаружи открыты                                                                  |
| DNS              | A-запись для `--domain` смотрит на этот хост, пропагировалась (без CDN-прокси перед сервером, иначе Let's Encrypt HTTP-01 может не пройти) |

## Использование

```text
bash install.sh [options]

Обязательные:
  --domain DOMAIN         Публичный FQDN с A-записью на этот сервер.
  --email EMAIL           Контактный email для регистрации VAPID (web-push).

Опциональные:
  --branch BRANCH         Ветка fluxerapp/fluxer для deploy-шаблонов (по умолчанию: main).
  --server-ip IP          Переопределить автоопределённый публичный IP для LiveKit node_ip.
  --skip-upgrade          Пропустить полный apt upgrade.
  --skip-firewall         Пропустить настройку ufw (если фильтр делает провайдер).
  --clean                 docker-compose down + rm -rf /opt/fluxer перед установкой.
  -h, --help
```

Скрипт **идемпотентен**. Повторный запуск на уже развёрнутом хосте не регенерирует секреты, не перезаписывает данные в `livekit.yaml` и сделает (`docker compose pull` / `up -d`) только если апстрим-образы изменились.

## Что устанавливается

| Стадия | Компонент | Заметки |
| --- | --- | --- |
| 1 | apt full upgrade (skippable) | `DEBIAN_FRONTEND=noninteractive`, `Dpkg::--force-confold` — существующие конфиги не перезаписываются. |
| 2 | Базовые пакеты | `ca-certificates curl gnupg ufw fail2ban unattended-upgrades jq` |
| 3 | `fail2ban` | Enabled + started через systemd. |
| 4 | UFW | Дефолт deny incoming / allow outgoing; правила `22/tcp 80/tcp 443/tcp 7881/tcp 7882/udp`; `ufw --force enable`. |
| 5 | Docker CE + Compose v2 | Официальный репо `download.docker.com/linux/ubuntu`, GPG-запинен, `docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin`. |
| 6 | Fluxer deploy-шаблоны | `docker-compose.yml`, `Caddyfile`, `livekit.yaml`, `.env.example` скачиваются из `fluxerapp/fluxer@<branch>/deploy/self-hosting/`. |
| 7 | `.env` (публичная часть) | `FLUXER_DOMAIN`, `*_SCHEME=https`, `*_PORT=443`, `*_CADDY_SITE_ADDRESS`, `*_VAPID_EMAIL`, email-подсистема отключена. |
| 8 | `.env` (секреты) | Десять 256-битных hex-секретов через `openssl rand -hex 32`, один 256-битный base64 (`UPLOAD_RELAY`), пара VAPID-ключей генерируется в эфемерном контейнере `node:24-alpine`. Заменяет только значения, оставшиеся как `CHANGE_ME`. |
| 9 | `livekit.yaml` | Полностью перезаписывается известно-рабочим конфигом: `use_external_ip: false`, `node_ip` = детектированный/указанный публичный IP, RTC-порты `7881-tcp` / `7882-udp`. |
| 10 | `/etc/sysctl.d/99-livekit.conf` | `net.core.rmem_max = net.core.wmem_max = 5_000_000` для UDP-пропускной способности LiveKit; `sysctl --system` применяет сразу. |
| 11 | Voice env + override | `FLUXER_LIVEKIT_URL=wss://$DOMAIN/livekit` и JSON `FLUXER_LIVEKIT_DEFAULT_REGION` дописываются в `.env`; `docker-compose.override.yml` пробрасывает обе переменные в сервисы `api` и `worker`. |
| 12 | `docker compose pull && up -d` | 17 образов, ~7 GiB суммарно. |
| 13 | Бакеты SeaweedFS | `fluxer`, `fluxer-uploads`, `fluxer-downloads`, `fluxer-reports`, `fluxer-harvests` создаются через `weed shell` внутри `docker compose exec -T` (апстрим-контейнер `seaweedfs-init` известен race-condition с мастером — иногда молча ничего не делает). |
| 14 | Проверка | `docker compose ps`, последние строки certificate-логов Caddy, пять HTTPS-пробингов `/_health` против `--domain`. |

## Как обеспечивается non-interactivity

Обычный `apt upgrade` на свежем Ubuntu 24.04 VPS рано или поздно вылезет с TUI в трёх местах:

1. **`debconf`** (самое частое — `openssh-server`, `grub-pc` и т.п. спрашивают "оставить локальную версию / поставить maintainer's"). Подавляется через `DEBIAN_FRONTEND=noninteractive` + `Dpkg::Options::=--force-confold` — локальная копия всегда. Именно это удерживает SSH-сессию живой через upgrade.
2. **`needrestart`** (после установки — TUI-выбор какие сервисы рестартить). Подавляется через `NEEDRESTART_MODE=a` и in-place правку `/etc/needrestart/needrestart.conf` с установкой `$nrconf{restart} = 'a'`. Сервисы рестартятся автоматически; вопрос про kernel-restart пропускается.
3. **`ufw enable`** (диалог подтверждения). Подавляется через `ufw --force enable`.

Других интерактивных точек в pipeline нет.

## Конфигурация

Всё настраиваемое живёт в `/opt/fluxer/.env`. После завершения установщика можешь править файл и делать `cd /opt/fluxer && docker compose up -d` для применения.

Самые частые follow-ups:

- **SMTP**: поставь `FLUXER_EMAIL_ENABLED=true`, `FLUXER_EMAIL_PROVIDER=smtp`, дальше провайдер-специфичный блок `SMTP_*`.
- **Брендинг**: залогинься на `https://$DOMAIN/admin` после первой регистрации; Instance Setup wizard даст поля для лого и названия.
- **Retention**: та же админка, секция "Retention".

`livekit.yaml` перезаписывается на каждом запуске установщика — если ты его кастомизируешь, либо храни патченый файл рядом со скриптом в системе контроля версий, либо удали соответствующий `cat > livekit.yaml <<EOF` блок.

## Верификация

Установщик печатает:

```
==> container status:
NAME                       STATUS              PORTS
fluxer-api-1               Up                  ...
fluxer-caddy-1             Up                  0.0.0.0:80, 0.0.0.0:443
fluxer-livekit-1           Up                  0.0.0.0:7881, 0.0.0.0:7882/udp
...

==> caddy TLS status:
  ... certificate obtained successfully ...

==> health checks against https://chat.example.com :
  /_health             200
  /api/_health         200
  /gateway/_health     200
  /media/_health       200
  /admin/_health       200
```

Все пять `200` означают что каждая подсистема Fluxer отвечает end-to-end через Caddy. Если проба возвращает `000` или `FAIL` — смотри раздел troubleshooting ниже.

## Troubleshooting

| Симптом | Вероятная причина | Что делать |
| --- | --- | --- |
| `apt install` висит с `Waiting for cache lock` | Параллельный цикл `unattended-upgrades` держит `/var/lib/dpkg/lock-frontend`. | Дождаться, либо `systemctl stop unattended-upgrades.service && fuser -k /var/lib/dpkg/lock-frontend`, потом перезапустить. |
| `dpkg was interrupted, you must manually run 'dpkg --configure -a'` | Предыдущий apt был убит на полпути. | `DEBIAN_FRONTEND=noninteractive dpkg --configure -a --force-confold`, потом перезапустить установщик. |
| Health-чеки возвращают `000` или TLS alert | DNS A-запись указывает на CDN/anti-DDoS прокси, а не на хост; Let's Encrypt не может достучаться до порта 80 напрямую. | Обойти прокси или сделать выделенный поддомен с A-записью напрямую на VPS. |
| Контейнер `livekit` в цикле `Restarting` | Неправильный `node_ip` или снова включён `use_external_ip: true`. | Проверь `/opt/fluxer/livekit.yaml`: должно быть `use_external_ip: false` и `node_ip: <публичный IPv4>`. |
| Голосовой канал в клиенте висит | `FLUXER_LIVEKIT_URL` / `FLUXER_LIVEKIT_DEFAULT_REGION` нет в `.env`, либо override не пробросил их в `api` / `worker`. | `grep FLUXER_LIVEKIT /opt/fluxer/.env`, дальше `docker compose up -d --force-recreate api worker`. |
| `fs.ls /buckets` пусто после установки | Сработала race между `seaweedfs-init` и мастером SeaweedFS. | Установщик создаёт пять бакетов защитно; перезапусти установщик или запусти create-цикл руками (см. шаг 13). |
| `error: beginning MaxStartups throttling` в `journalctl -u ssh` | sshd дропает параллельные unauthenticated-коннекты. | Уменьшить параллельные SSH-пробинги; если реально нужны много параллельных логинов — поднять `MaxStartups 30:60:200` в `sshd_config`. |

## Безопасность

- Все секреты в `.env` генерируются локально через `openssl rand`; ничего никуда не отправляется.
- `.env` получает `chmod 600` сразу после скачивания.
- Установщик **не** харденит SSH (password auth, root login, порт). Это тема следующего шага — рекомендуемый минимум: положить свой публичный ключ в `~/.ssh/authorized_keys`, поставить `PasswordAuthentication no` и `PermitRootLogin prohibit-password` в `/etc/ssh/sshd_config.d/10-hardening.conf`, потом `systemctl reload ssh`.
- UFW по-умолчанию не защищает Docker-published порты — правила `iptables`, добавленные Docker-ом, обходят цепочки UFW. Для defense-in-depth настрой firewall в панели провайдера (aeza, Hetzner и т.д.) с тем же allow-листом.

## Лицензия

Сам установщик — обычный bash; считать как MIT. Fluxer апстрим лицензирован по своим условиям — смотри [fluxerapp/fluxer](https://github.com/fluxerapp/fluxer).
