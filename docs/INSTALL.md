# Установка

## 1. Создайте бота

1. В Telegram откройте [@BotFather](https://t.me/BotFather) и выполните `/newbot`.
2. Сохраните **токен** (вид `123456789:AA...`). Он даёт полный контроль над ботом, храните его как пароль.
3. Откройте своего бота и нажмите **Start**, затем отправьте любое сообщение. Это нужно, чтобы определить ваш `chat_id`.

## 2. Доступ к роутеру по SSH

Скрипты ставятся по SSH с ключом (без пароля):

```sh
ls ~/.ssh/id_ed25519.pub || ssh-keygen -t ed25519
ssh-copy-id root@192.168.8.1
```

Пароль root на GL.iNet совпадает с паролем админки.

> На OpenWrt нет `sftp-server`, поэтому для копирования файлов нужен `scp -O`
> (старый протокол). Установочный скрипт делает это сам.

## 3. Автоматическая установка

```sh
git clone <адрес репозитория>
cd flint2-telegram-bot
./install.sh root@192.168.8.1
```

Скрипт:
1. проверяет вход по SSH и наличие `curl`, `jq`, `lua` на роутере;
2. копирует файлы в `/usr/bin`, `/usr/lib`, `/etc/init.d`;
3. спрашивает токен (ввод скрыт), находит ваш `chat_id` и записывает `/etc/tgbot.conf` с правами `600`;
4. запускает бота (`tgbot-ctl on`).

После установки напишите боту `/help`.

## 4. Ручная установка

```sh
# с компьютера
cd flint2-telegram-bot/router
scp -O usr/bin/tgbot.sh usr/bin/tgbot-poll.sh usr/bin/tgbot-wol.lua usr/bin/tgbot-ctl root@192.168.8.1:/usr/bin/
scp -O usr/lib/tgbot-lib.sh root@192.168.8.1:/usr/lib/
scp -O etc/init.d/tgbot root@192.168.8.1:/etc/init.d/

# на роутере
ssh root@192.168.8.1
chmod 755 /usr/bin/tgbot*.sh /usr/bin/tgbot-wol.lua /usr/bin/tgbot-ctl /etc/init.d/tgbot
umask 077
cat > /etc/tgbot.conf <<'EOF'
TOKEN=ваш_токен
CHAT_ID=ваш_chat_id
EOF
tgbot-ctl on
```

Как узнать `chat_id` вручную: отправьте сообщение боту и откройте
`https://api.telegram.org/bot<ТОКЕН>/getUpdates`, значение лежит в `message.chat.id`.

## 5. Включите журнал запросов AdGuard Home (для отчётов и аномалий)

Отчёт `/report` и уведомления о всплесках читают файл `/etc/AdGuardHome/data/querylog.json`.
В `/etc/AdGuardHome/config.yaml`:

```yaml
querylog:
  enabled: true
  file_enabled: true      # писать журнал в файл
  interval: 2160h         # хранить 90 дней
  size_memory: 50         # сбрасывать на диск каждые 50 записей (по умолчанию 1000 даёт большую задержку)
```

Затем `/etc/init.d/adguardhome restart`. Без этого бот работает, но `/report` и
уведомления об аномалиях будут пустыми.

## 6. Необязательно: бэкап и VPN-адрес

В `/etc/tgbot.conf` можно добавить:

```
BACKUP_PASS=длинная_случайная_фраза   # включает зашифрованный бэкап, см. BACKUP.md
VPN_ENDPOINT=vpn.example.com          # адрес роутера для VPN-конфигов (по умолчанию берётся WAN IP)
```

`HC_URL=https://hc-ping.com/<uuid>`: бот раз в минуту пингует healthchecks.io. Бот не может сообщить, что роутер выключился или пропал интернет, а этот сервис пришлёт уведомление, когда пинги прекратятся.

Для `/vpn add` нужен пакет `qrencode` (`opkg install qrencode`, установщик делает это сам). Штатный `qrencode` не умеет PNG,
поэтому картинку QR-кода рисует `tgbot-png.lua`.

## Обновление

```sh
git pull && ./update.sh            # или ./update.sh root@192.168.8.1
```

Скрипт проверяет синтаксис, копирует файлы, перезапускает слушатель; `/etc/tgbot.conf` и данные не трогаются. Если копируете файлы вручную, после этого выполните `tgbot-ctl on`: слушатель сам новые файлы не подхватывает.

## Удаление

```sh
tgbot-ctl remove --purge     # на роутере: удалить бота вместе с токеном и данными
```

И обязательно отзовите токен: **@BotFather → `/revoke`**.
