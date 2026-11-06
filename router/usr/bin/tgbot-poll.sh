#!/bin/sh
# Слушатель команд и кнопок Telegram (long polling): отвечает мгновенно.
# Принцип «чистого чата»: команда пользователя и сообщение с плитками удаляются после использования.
. /usr/lib/tgbot-lib.sh
OFFSET=/tmp/tgbot.offset

# после перезагрузки/перезапуска: отбросить накопившиеся старые сообщения и нажатия кнопок,
# чтобы старая команда (например, «Перезагрузить») не выполнилась повторно
if [ ! -s "$OFFSET" ]; then
    last=$(curl -s -m 15 "$API/getUpdates?offset=-1&timeout=0" 2>/dev/null | jq -r '.result[-1].update_id // empty' 2>/dev/null)
    [ -n "$last" ] && echo $((last + 1)) > "$OFFSET"
fi
off=$(cat "$OFFSET" 2>/dev/null || echo 0)
set_commands   # подсказки команд при вводе «/»

while true; do
    upd=$(curl -s -m 65 "$API/getUpdates?offset=$off&timeout=50" 2>/dev/null)
    if [ -z "$upd" ]; then sleep 5; continue; fi
    echo "$upd" | jq -r '.result[]? | if .callback_query then [.update_id, (.callback_query.message.chat.id|tostring), "c", (.callback_query.data // ""), .callback_query.id, (.callback_query.message.message_id|tostring)] else [.update_id, (.message.chat.id|tostring), "m", (.message.text // ""), "-", (.message.message_id|tostring)] end | @tsv' > /tmp/tgbot.upd 2>/dev/null
    while IFS="$(printf '\t')" read id chat kind data cbid mid; do
        [ -n "$id" ] || continue
        off=$((id + 1)); echo "$off" > "$OFFSET"
        [ "$chat" = "$CHAT_ID" ] || continue
        if [ "$kind" = "c" ]; then
            answer_cb "$cbid"
            CB_MID=$mid
            # исходный текст сообщения с кнопкой (нужен, чтобы дописать результат)
            echo "$upd" | jq -r --arg id "$cbid" '.result[] | select(.callback_query.id==$id) | .callback_query.message.text // ""' > /tmp/tgbot.cbtext 2>/dev/null
            handle_cb "$data"
            CB_MID=""
        else
            handle "$data"
            # «чистый чат»: сама команда пользователя после обработки удаляется
            case "$data" in /*) tg_delete "$mid" ;; esac
        fi
    done < /tmp/tgbot.upd
    sleep 1
done
