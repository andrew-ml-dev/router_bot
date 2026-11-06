#!/bin/sh
# Установка Telegram-бота на роутер GL.iNet / OpenWrt с Mac или Linux.
# Использование: ./install.sh [user@host]      (по умолчанию root@192.168.8.1)
#
# Требования: SSH-доступ к роутеру по ключу (ssh-copy-id), curl на этом компьютере,
# бот, созданный через @BotFather.
set -e

HOST="${1:-root@192.168.8.1}"
DIR="$(cd "$(dirname "$0")" && pwd)/router"
SSH="ssh -o BatchMode=yes $HOST"

echo "==> Проверка SSH-доступа к $HOST"
$SSH 'echo ok' >/dev/null || {
    echo "Не удалось войти по ключу. Выполните: ssh-copy-id $HOST"
    exit 1
}

echo "==> Проверка нужных пакетов на роутере (curl, jq, lua)"
$SSH 'for b in curl jq lua; do command -v $b >/dev/null || echo "НЕТ: $b"; done' | tee /tmp/tgbot-check.$$
if grep -q "НЕТ" /tmp/tgbot-check.$$; then
    echo "Установите недостающее: opkg update && opkg install curl jq"
    rm -f /tmp/tgbot-check.$$
    exit 1
fi
rm -f /tmp/tgbot-check.$$

echo "==> Копирование файлов"
# -O: старый протокол scp (на OpenWrt нет sftp-server)
scp -O -q "$DIR/usr/bin/tgbot.sh"        "$HOST:/usr/bin/tgbot.sh"
scp -O -q "$DIR/usr/bin/tgbot-poll.sh"   "$HOST:/usr/bin/tgbot-poll.sh"
scp -O -q "$DIR/usr/bin/tgbot-wol.lua"   "$HOST:/usr/bin/tgbot-wol.lua"
scp -O -q "$DIR/usr/bin/tgbot-png.lua"   "$HOST:/usr/bin/tgbot-png.lua"
scp -O -q "$DIR/usr/bin/tgbot-scan.lua"  "$HOST:/usr/bin/tgbot-scan.lua"
scp -O -q "$DIR/usr/bin/tgbot-ctl"       "$HOST:/usr/bin/tgbot-ctl"
scp -O -q "$DIR/usr/lib/tgbot-lib.sh"    "$HOST:/usr/lib/tgbot-lib.sh"
scp -O -q "$DIR/usr/lib/tgbot-ext.sh"    "$HOST:/usr/lib/tgbot-ext.sh"
scp -O -q "$DIR/etc/init.d/tgbot"        "$HOST:/etc/init.d/tgbot"
$SSH 'chmod 755 /usr/bin/tgbot.sh /usr/bin/tgbot-poll.sh /usr/bin/tgbot-wol.lua /usr/bin/tgbot-png.lua /usr/bin/tgbot-scan.lua /usr/bin/tgbot-ctl /etc/init.d/tgbot; chmod 644 /usr/lib/tgbot-lib.sh /usr/lib/tgbot-ext.sh'

echo "==> QR-коды для /vpn add (пакет qrencode)"
$SSH 'command -v qrencode >/dev/null || { opkg update >/dev/null 2>&1; opkg install qrencode >/dev/null 2>&1; }; command -v qrencode >/dev/null && echo "qrencode: ok" || echo "ВНИМАНИЕ: qrencode не установился, команда /vpn add работать не будет (opkg install qrencode)"'

echo "==> Сохранение бота при обновлении прошивки (sysupgrade.conf)"
$SSH 'for f in /usr/bin/tgbot.sh /usr/bin/tgbot-poll.sh /usr/bin/tgbot-ctl /usr/bin/tgbot-wol.lua /usr/bin/tgbot-png.lua /usr/bin/tgbot-scan.lua /usr/lib/tgbot-lib.sh /usr/lib/tgbot-ext.sh /etc/init.d/tgbot /etc/tgbot.conf /etc/tgbot.known /etc/tgbot.names /etc/tgbot.watch /etc/tgbot.sites /etc/tgbot.speed /etc/tgbot.events /etc/tgbot.traffic; do grep -qxF "$f" /etc/sysupgrade.conf 2>/dev/null || echo "$f" >> /etc/sysupgrade.conf; done'

if $SSH 'test -s /etc/tgbot.conf'; then
    echo "==> /etc/tgbot.conf уже есть, оставляю как есть"
else
    echo "==> Настройка бота"
    printf "Токен бота (от @BotFather): "
    stty -echo 2>/dev/null || true
    read -r TOKEN
    stty echo 2>/dev/null || true
    echo
    echo "Откройте своего бота в Telegram, нажмите Start и отправьте ему любое сообщение."
    printf "Когда отправите, нажмите Enter... "
    read -r _
    CHAT_ID=$(curl -s -m 15 "https://api.telegram.org/bot$TOKEN/getUpdates" \
        | grep -o '"chat":{"id":[0-9-]*' | head -n1 | grep -o '[0-9-]*$' || true)
    if [ -z "$CHAT_ID" ]; then
        echo "Не нашёл chat_id. Проверьте токен и что вы написали боту, затем запустите скрипт снова."
        exit 1
    fi
    echo "Найден chat_id: $CHAT_ID"
    # токен и chat_id передаются через stdin, а не в аргументах команды
    printf 'TOKEN=%s\nCHAT_ID=%s\n' "$TOKEN" "$CHAT_ID" | $SSH 'umask 077; cat > /etc/tgbot.conf; chmod 600 /etc/tgbot.conf'
fi

echo "==> Запуск"
$SSH 'tgbot-ctl on; sleep 2; tgbot-ctl status'

echo
echo "Готово. Напишите боту /help."
echo "Для зашифрованного бэкапа задайте BACKUP_PASS в /etc/tgbot.conf (см. docs/BACKUP.md)."
