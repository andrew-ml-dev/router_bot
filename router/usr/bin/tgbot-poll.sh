#!/bin/sh
# Слушатель команд и кнопок Telegram (long polling): отвечает мгновенно
. /usr/lib/tgbot-lib.sh
OFFSET=/tmp/tgbot.offset

# после перезагрузки/перезапуска: отбросить накопившиеся старые сообщения и нажатия кнопок,
# чтобы старая команда (например, «Перезагрузить») не выполнилась повторно
if [ ! -s "$OFFSET" ]; then
    last=$(curl -s -m 15 "$API/getUpdates?offset=-1&timeout=0" 2>/dev/null | jq -r '.result[-1].update_id // empty' 2>/dev/null)
    [ -n "$last" ] && echo $((last + 1)) > "$OFFSET"
fi
off=$(cat "$OFFSET" 2>/dev/null || echo 0)

while true; do
    upd=$(curl -s -m 65 "$API/getUpdates?offset=$off&timeout=50" 2>/dev/null)
    if [ -z "$upd" ]; then sleep 5; continue; fi
    echo "$upd" | jq -r '.result[]? | if .callback_query then [.update_id, (.callback_query.message.chat.id|tostring), "c", (.callback_query.data // ""), .callback_query.id] else [.update_id, (.message.chat.id|tostring), "m", (.message.text // ""), "-"] end | @tsv' > /tmp/tgbot.upd 2>/dev/null
    while IFS="$(printf '\t')" read id chat kind data cbid; do
        [ -n "$id" ] || continue
        off=$((id + 1)); echo "$off" > "$OFFSET"
        [ "$chat" = "$CHAT_ID" ] || continue
        if [ "$kind" = "c" ]; then
            answer_cb "$cbid"
            handle_cb "$data"
        else
            handle "$data"
        fi
    done < /tmp/tgbot.upd
    sleep 1
done
