# awg — AmneziaWG 3.1 сервер в Docker

Сервер [AmneziaWG](https://docs.amnezia.org/ru/documentation/amnezia-wg) 3.1: WireGuard с обфускацией
(защита заголовков, junk-пакеты, случайные хвосты, маскировка первого пакета под DNS-ответ).
Клиенты: приложение Amnezia (Android/iOS/desktop), Keenetic с KeeneticOS 5.2 Alpha 11+.

На сервере нужны только Docker, `docker-compose.yml` и `.env`. Всё состояние сервера (ключи,
параметры, пиры, конфиги клиентов) лежит в одной папке `data/`, она переживает рестарты,
пересоздание контейнера и переезд на другой VPS.

```
docker-compose.yml   как запускать
.env                 endpoint и порт (без секретов), образец: .env.example
data/                СЕКРЕТ, создаётся при первом запуске
  awg0.conf            ключ сервера, параметры обфускации, все пиры
  clients/<name>.conf  конфиги клиентов
```

## 0. Собрать и запушить образ (на своей машине)

```bash
docker build -t ekalkutin/tunnel:latest .
docker push ekalkutin/tunnel:latest
```

Сервер на ARM? Тогда `docker buildx build --platform linux/amd64,linux/arm64 -t ekalkutin/tunnel:latest --push .`

## 1. Подготовить сервер

```bash
mkdir ~/awg && cd ~/awg
# положить сюда docker-compose.yml и .env (из .env.example)
nano .env          # AWG_ENDPOINT = IP или домен сервера, AWG_PORT = случайный UDP-порт
```

Если у провайдера VPS есть свой файрвол, откройте в нём этот UDP-порт. ufw трогать не нужно:
Docker открывает опубликованные порты в обход ufw.

## 2. Запустить

```bash
docker compose pull
docker compose up -d
docker compose logs     # "new server generated" при первом запуске, затем "ready: udp/<порт>"
```

`restart: unless-stopped`: контейнер сам поднимается после перезагрузки VPS и падений.

## 3. Добавить пира (получить .conf)

```bash
docker exec awg peer add keenetic > keenetic.conf     # конфиг -> файл
docker exec awg peer qr phone                         # QR-код для приложения Amnezia
```

Изменения применяются на лету, остальные клиенты не отключаются. Имя: латиница, цифры, `.`, `_`, `-`.

Конфиг можно выгрузить ещё раз в любой момент (он хранится в `data/clients/`):

```bash
docker exec awg peer show keenetic > keenetic.conf
```

Скачать файл на свою машину: `scp user@server:awg/keenetic.conf .`

**Keenetic:** Интернет → Другие подключения → WireGuard → «Загрузить из файла» → выбрать `.conf`.
Затем включить «Использовать для выхода в интернет», если весь трафик должен идти через VPN.

## 4. Удалить пира

```bash
docker exec awg peer remove phone
```

Посмотреть всех пиров, последний handshake и трафик:

```bash
docker exec awg peer list
```

## 5. Переезд на другой VPS / восстановление

Сервер целиком — это папка `data/`. Перенесли её, и сервер тот же: те же ключи, параметры и пиры,
клиентские конфиги остаются рабочими.

```bash
# на старом сервере (или из бэкапа)
cd ~/awg && sudo tar czf awg-backup.tgz .env data

# на новом сервере: шаг 1 (Docker), затем
tar xzf awg-backup.tgz && docker compose up -d
```

- `AWG_ENDPOINT` — домен: достаточно поменять DNS-запись, клиентам ничего делать не надо.
- `AWG_ENDPOINT` — IP: поменять его в `.env`, затем `docker exec awg peer show <name>` и переимпортировать
  конфиги (или поправить только Endpoint в клиенте).

**Бэкап обязателен.** Одного клиентского `.conf` для восстановления не хватит: в нём нет приватного ключа
сервера. Без `data/` придётся поднимать новый сервер и раздавать всем новые конфиги.

```bash
sudo tar czf awg-backup-$(date +%F).tgz .env data      # data/ принадлежит root, отсюда sudo
```

## Обновление образа

```bash
docker compose pull && docker compose up -d     # data/ не трогается
```

## Параметры

Сгенерированы при первом запуске в `[Interface]` файла `data/awg0.conf` по умолчаниям официального
клиента Amnezia (AWG 3.1). Их можно править руками, затем `docker compose restart`. Но любой параметр
из списка «должны совпадать» ломает старые клиентские конфиги: после правки выгрузите их заново
(`peer show`) и переимпортируйте.

| Должны совпадать на сервере и клиенте | |
|---|---|
| `HeaderProtectionKey` | случайный ключ, шифрует заголовки пакетов (ChaCha20) |
| `S1`–`S4` = 12 | случайный префикс пакетов; для защиты заголовков нужен ≥ 12 |
| `H1`–`H4` = 1 2 3 4 | типы пакетов; заголовки всё равно зашифрованы |
| `RandomTrailers`, `DisableCookies` = on | случайный хвост у пакетов / без cookie-механизма |

Остальные (`Jc/Jmin/Jmax`, `I1`, `ContentPaddingAddition`, тайминги `Rekey*`, `KeepaliveTimeout`,
`MaxHandshakeAttempts`) влияют только на отправляющую сторону; `peer add/show` копирует их в
клиентский конфиг как есть.

Настройки клиентских конфигов в `.env` (применяются к `peer add` и `peer show`):

| Переменная | По умолчанию |
|---|---|
| `AWG_CLIENT_DNS` | `1.1.1.1, 1.0.0.1` |
| `AWG_CLIENT_MTU` | `1280` |
| `AWG_CLIENT_ALLOWED_IPS` | `0.0.0.0/0, ::/0` (весь трафик) |
| `AWG_CLIENT_PERSISTENT_KEEPALIVE` | `25-35` |
| `AWG_ADDRESS` | `10.8.3.1/24`, учитывается только при первом запуске |

Порт можно поменять в `.env` в любой момент (`docker compose up -d`), затем выгрузить конфиги заново.

## Устройство

- `entrypoint.sh`: при первом запуске генерирует `data/awg0.conf`, поднимает `awg0` (userspace
  `amneziawg-go`), включает NAT.
- `peer.sh` (в контейнере `peer`): пиры = секции `[Peer]` в `awg0.conf` со строкой `# Name = <имя>`.
  Новый пир получает следующий свободный адрес, свой ключ и свой PresharedKey.
- Базовый образ `amneziavpn/amneziawg-go:3.1.20260828` закреплён по digest.
