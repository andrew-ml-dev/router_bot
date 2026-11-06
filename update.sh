#!/bin/sh
# Обновление бота на роутере одной командой (конфиг и данные не трогаются).
# Использование: git pull && ./update.sh [user@host]      (по умолчанию root@192.168.8.1)
set -e
HOST="${1:-root@192.168.8.1}"
DIR="$(cd "$(dirname "$0")" && pwd)/router"

for f in "$DIR"/usr/bin/*.sh "$DIR"/usr/lib/*.sh; do sh -n "$f" || { echo "Синтаксическая ошибка в $f, обновление отменено"; exit 1; }; done

echo "==> Копирование файлов на $HOST"
for f in tgbot.sh tgbot-poll.sh tgbot-wol.lua tgbot-png.lua tgbot-scan.lua tgbot-ctl; do
    scp -O -q "$DIR/usr/bin/$f" "$HOST:/usr/bin/$f"
done
scp -O -q "$DIR/usr/lib/tgbot-lib.sh" "$DIR/usr/lib/tgbot-ext.sh" "$HOST:/usr/lib/"
scp -O -q "$DIR/etc/init.d/tgbot" "$HOST:/etc/init.d/tgbot"
ssh "$HOST" 'chmod 755 /usr/bin/tgbot*.sh /usr/bin/tgbot*.lua /usr/bin/tgbot-ctl /etc/init.d/tgbot
for f in /etc/tgbot.pause; do grep -qxF "$f" /etc/sysupgrade.conf 2>/dev/null || echo "$f" >> /etc/sysupgrade.conf; done
tgbot-ctl on; sleep 2; tgbot-ctl status'
echo "Готово. Слушатель перезапущен."
