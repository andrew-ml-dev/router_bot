#!/bin/sh
# Общая библиотека Telegram-бота для роутера
. /etc/tgbot.conf
API="https://api.telegram.org/bot$TOKEN"
NAMES=/etc/tgbot.names          # свои имена устройств: mac=Имя
QLOG=/etc/AdGuardHome/data/querylog.json

# ---------- отправка ----------
# Важность: без второго аргумента сообщение приходит со звуком (тревоги, ответы на команды);
# с аргументом q — без звука (информационные: VPN, интернет вернулся, сводки).
send() {   # текст [q]
    curl -s -m 15 --data-urlencode "chat_id=$CHAT_ID" --data-urlencode "text=$1" \
        --data-urlencode "disable_notification=$([ "$2" = q ] && echo true || echo false)" \
        "$API/sendMessage" | grep -q '"ok":true'
}

# send_kb "текст" '{"inline_keyboard":[...]}' [q]
send_kb() {
    curl -s -m 15 --data-urlencode "chat_id=$CHAT_ID" --data-urlencode "text=$1" \
        --data-urlencode "disable_notification=$([ "$3" = q ] && echo true || echo false)" \
        --data-urlencode "reply_markup=$2" "$API/sendMessage" | grep -q '"ok":true'
}

# отредактировать сообщение на месте (навигация по меню, фильтры журнала)
edit_msg() {   # message_id текст [разметка]
    curl -s -m 15 --data-urlencode "chat_id=$CHAT_ID" --data-urlencode "message_id=$1" \
        --data-urlencode "text=$2" ${3:+--data-urlencode "reply_markup=$3"} \
        "$API/editMessageText" >/dev/null 2>&1
}

night() {   # 23:00–07:00
    h=$(date +%H); h=${h#0}; [ -z "$h" ] && h=0
    [ "$h" -ge 23 ] || [ "$h" -lt 7 ]
}

answer_cb() {
    curl -s -m 10 --data-urlencode "callback_query_id=$1" "$API/answerCallbackQuery" >/dev/null 2>&1
}

# ---------- имена и адреса ----------
lc() { echo "$1" | tr 'A-Z' 'a-z'; }

devname() {   # MAC -> имя
    m=$(lc "$1")
    n=$(grep -i "^$m=" "$NAMES" 2>/dev/null | head -n1 | cut -d= -f2-)
    [ -z "$n" ] && n=$(awk -v m="$m" 'tolower($2)==m && $4!="*" {print $4; exit}' /tmp/dhcp.leases 2>/dev/null)
    echo "${n:-безымянное}"
}

ip2mac() { awk -v ip="$1" '$1==ip {print tolower($4); exit}' /proc/net/arp; }
mac2ip() { awk -v m="$(lc "$1")" 'tolower($4)==m {print $1; exit}' /proc/net/arp; }

ipname() {    # IP -> имя (или сам IP)
    m=$(ip2mac "$1")
    if [ -n "$m" ]; then echo "$(devname "$m")"; else v=$(vpn_ipname "$1"); echo "${v:-$1}"; fi
}

target_mac() {   # IP | MAC | часть имени -> MAC
    a=$(lc "$1")
    case "$a" in
        *:*:*:*:*:*) echo "$a" ;;
        *.*.*.*)     ip2mac "$a" ;;
        *)
            m=$(awk -F= -v n="$a" 'index(tolower($2), n) {print tolower($1); exit}' "$NAMES" 2>/dev/null)
            [ -z "$m" ] && m=$(awk -v n="$a" '$4!="*" && index(tolower($4), n) {print tolower($2); exit}' /tmp/dhcp.leases 2>/dev/null)
            echo "$m" ;;
    esac
}

router_mac() { cat /sys/class/net/br-lan/address 2>/dev/null | tr 'A-Z' 'a-z'; }

is_blocked() { ipset test GL_MAC_BLOCK "$1" >/dev/null 2>&1; }

# ---------- блокировка (нативный механизм GL.iNet, виден в админке) ----------
do_block() {
    m=$(echo "$1" | tr 'a-z' 'A-Z')
    uci -q get gl_block.block_mac >/dev/null || uci set gl_block.block_mac=block_mac
    uci -q get gl_block.block_mac.mac | grep -qi "$m" || uci add_list gl_block.block_mac.mac="$m"
    uci commit gl_block
    ipset create GL_MAC_BLOCK hash:mac 2>/dev/null
    ipset add GL_MAC_BLOCK "$m" -exist 2>/dev/null
    ip=$(mac2ip "$m"); [ -n "$ip" ] && conntrack -D -s "$ip" >/dev/null 2>&1
}

do_unblock() {
    m=$(echo "$1" | tr 'a-z' 'A-Z'); l=$(lc "$1")
    uci -q del_list gl_block.block_mac.mac="$m"
    uci -q del_list gl_block.block_mac.mac="$l"
    uci commit gl_block
    ipset del GL_MAC_BLOCK "$m" 2>/dev/null
    [ -f "$PAUSE" ] && sed -i "/^$l=/d" "$PAUSE"
}

# ---------- информация ----------
clients() {
    awk 'NR>1 && $3=="0x2" && $6=="br-lan" {print $1, $4}' /proc/net/arp | while read ip mac; do
        flag=""; is_blocked "$mac" && flag="  [ЗАБЛОКИРОВАНО]"
        echo "$ip  $(devname "$mac")  ($mac)$flag"
    done
}

status() {
    up=$(awk '{d=int($1/86400); h=int(($1%86400)/3600); m=int(($1%3600)/60); printf "%dд %dч %dм", d, h, m}' /proc/uptime)
    load=$(cut -d' ' -f1-3 /proc/loadavg)
    mem=$(free -m | awk '/Mem:/ {printf "%d/%d МБ", $3, $2}')
    t=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null)
    [ -n "$t" ] && t="$((t/1000)) °C" || t="?"
    wan=$(ubus call network.interface.wan status 2>/dev/null | jq -r '.["ipv4-address"][0].address // "нет"' 2>/dev/null)
    n=$(clients | wc -l)
    printf 'Роутер GL-MT6000\nАптайм: %s\nНагрузка: %s\nПамять: %s\nТемпература: %s\nWAN IP: %s\nУстройств в сети: %s' \
        "$up" "$load" "$mem" "$t" "$wan" "$n"
}

vpn() {
    now=$(date +%s)
    out=""
    for sec in $(uci -q show wireguard_server | grep -o 'peer_[0-9]*=peers' | cut -d= -f1); do
        name=$(uci -q get wireguard_server.$sec.name)
        pub=$(uci -q get wireguard_server.$sec.public_key)
        hs=$(wg show wgserver latest-handshakes 2>/dev/null | grep "^$pub" | cut -f2)
        if [ -z "$hs" ] || [ "$hs" = "0" ]; then
            st="не подключался"
        else
            age=$((now - hs))
            if [ $age -lt 240 ]; then st="онлайн"; else st="был $((age/60)) мин назад"; fi
        fi
        out="$out$name: $st
"
    done
    printf 'WireGuard:\n%s' "$out"
}

named_top() {   # stdin: "N IP" -> "  Имя (N)"
    while read c ip; do
        [ -n "$ip" ] && echo "  $(ipname "$ip") ($c)"
    done
}

report() {   # [секунд, по умолчанию 86400]
    secs=${1:-86400}
    if [ "$secs" -ge 604800 ]; then label="DNS за $((secs / 86400)) дней"; else label="DNS за 24 часа"; fi
    if [ ! -s "$QLOG" ]; then
        echo "Журнал запросов AdGuard пока пуст."
        return
    fi
    cutoff=$(date -u -d "@$(( $(date +%s) - secs ))" +%Y-%m-%dT%H:%M 2>/dev/null)
    tmp=/tmp/tgbot.ql
    jq -c --arg c "$cutoff" 'select(.T > $c)' "$QLOG" 2>/dev/null > "$tmp"
    total=$(wc -l < "$tmp")
    blocked=$(jq -c 'select(.Result.IsFiltered==true)' "$tmp" 2>/dev/null | wc -l)
    pct=0; [ "$total" -gt 0 ] && pct=$((blocked * 100 / total))
    topb=$(jq -r 'select(.Result.IsFiltered==true) | .QH' "$tmp" 2>/dev/null | sort | uniq -c | sort -rn | head -5 | awk '{print "  "$2" ("$1")"}')
    topc=$(jq -r '.IP' "$tmp" 2>/dev/null | sort | uniq -c | sort -rn | head -5 | named_top)
    rm -f "$tmp"
    printf '%s\nЗапросов: %s\nЗаблокировано: %s (%s%%)\n\nТоп заблокированных:\n%s\n\nТоп устройств по запросам:\n%s' \
        "$label" "$total" "$blocked" "$pct" "$topb" "$topc"
}

# ---------- действия ----------
wake() {
    m=$(target_mac "$1")
    [ -n "$m" ] || { echo "Не нашёл устройство: $1"; return; }
    lua /usr/bin/tgbot-wol.lua "$m" 2>&1 && echo "Отправил Wake-on-LAN для $(devname "$m") ($m)"
}

speedtest_raw() {   # печатает: загрузка отдача пинг (Мбит/с, мс)
    dl=$(curl -s -m 30 -o /dev/null -w '%{speed_download}' "https://speed.cloudflare.com/__down?bytes=50000000" 2>/dev/null)
    ul=$(head -c 20000000 /dev/zero | curl -s -m 30 -o /dev/null -w '%{speed_upload}' --data-binary @- "https://speed.cloudflare.com/__up" 2>/dev/null)
    png=$(ping -c4 -W2 1.1.1.1 2>/dev/null | awk -F'/' '/^round-trip|^rtt/ {printf "%.0f", $4}')
    awk -v d="${dl:-0}" -v u="${ul:-0}" -v p="${png:-0}" 'BEGIN {printf "%.0f %.0f %s", d*8/1000000, u*8/1000000, p}'
}

speedtest() {
    set -- $(speedtest_raw)
    printf 'Скорость (Cloudflare)\nЗагрузка: %s Мбит/с\nОтдача: %s Мбит/с\nПинг: %s мс' "$1" "$2" "$3"
}

set_name() {   # $1 = mac, $2.. = имя
    m=$(lc "$1"); shift
    [ -f "$NAMES" ] && sed -i "/^$m=/d" "$NAMES"
    echo "$m=$*" >> "$NAMES"
}

. /usr/lib/tgbot-ext.sh

# ---------- обработка команд ----------
handle() {
    text="$1"
    cmd=${text%% *}; cmd=${cmd%%@*}
    args=""; case "$text" in *" "*) args=${text#* } ;; esac
    case "$cmd" in
        /status)    send "$(status)" ;;
        /clients)   send "$(printf 'Устройства в сети:\n%s' "$(clients)")" ;;
        /vpn)
            sub=${args%% *}; rest=""; case "$args" in *" "*) rest=${args#* } ;; esac
            case "$sub" in
                add)
                    vpn_name_ok "$rest" || { send "Использование: /vpn add Имя (латиница, цифры, - и _, до 24 символов)"; return; }
                    id=$(date +%s); echo "$rest" > "/tmp/tgbot.pend.$id"
                    send_kb "Создать VPN-пользователя «$rest» с полным доступом (весь трафик через дом)? QR-код с приватным ключом придёт в чат и удалится через 2 минуты." \
                        "{\"inline_keyboard\":[[{\"text\":\"Создать\",\"callback_data\":\"vpnadd:$id\"},{\"text\":\"Отмена\",\"callback_data\":\"cancel:$id\"}]]}" ;;
                del)
                    [ -n "$(vpn_find "$rest")" ] || { send "Нет VPN-пользователя: $rest. Есть: $(vpn_names | tr '\n' ' ')"; return; }
                    id=$(date +%s); echo "$rest" > "/tmp/tgbot.pend.$id"
                    send_kb "Удалить VPN-пользователя «$rest»? Его конфиг перестанет работать." \
                        "{\"inline_keyboard\":[[{\"text\":\"Удалить\",\"callback_data\":\"vpndel:$id\"},{\"text\":\"Отмена\",\"callback_data\":\"cancel:$id\"}]]}" ;;
                *) send "$(vpn)" ;;
            esac ;;
        /watch)
            [ -n "$args" ] || { watch_menu; return; }
            t=${args%% *}; md=""; case "$args" in *" "*) md=${args#* } ;; esac
            send "$(watch_add "$t" "$md")" ;;
        /unwatch)   if [ -n "$args" ]; then send "$(watch_del "$args")"; else unwatch_menu; fi ;;
        /menu)      menu_panel ;;
        /pause)
            [ -n "$args" ] || { pause_menu; return; }
            t=${args%% *}; pmin=""; case "$args" in *" "*) pmin=${args#* } ;; esac
            pm=$(target_mac "$t")
            if [ -z "$pm" ]; then send "Не нашёл устройство: $t"; else send "$(pause_start "$pm" "$pmin")"; fi ;;
        /log)       log_show "$args" ;;
        /sensors)   send "$(sensors_view)" ;;
        /heat)
            [ -x "$HOOKS/heat" ] || { send "Отопление не подключено: нет /etc/tgbot.hooks/heat (см. docs/HOME-ASSISTANT.md)."; return; }
            "$HOOKS/heat" status >/dev/null 2>&1 || send "Home Assistant не отвечает." ;;
        /who)
            if [ -n "$args" ]; then send "$(who_dev "$args")"
            else send_kb "Чьи запросы показать?" "$(who_lines | json_kb)"; fi ;;
        /home)      send "$(who_home)" ;;
        /scan)      [ -n "$args" ] || { send "Использование: /scan <устройство>"; return; }
                    send "Проверяю порты, это займёт несколько секунд..."; send "$(scan_device "$args")" ;;
        /site)
            sub=${args%% *}; rest=""; case "$args" in *" "*) rest=${args#* } ;; esac
            case "$sub" in
                add) send "$(site_add "$rest")" ;;
                del) send "$(site_del "$rest")" ;;
                *)   send "Использование: /site add <адрес> | /site del <адрес> | /sites" ;;
            esac ;;
        /sites)     send "$(sites_list)" ;;
        /speedhist) send "$(speedhist)" ;;
        /backup)    send "Делаю бэкап..."; r=$(do_backup); [ -n "$r" ] && send "$r" ;;
        /digest)    send "$(digest)" ;;
        /report)    send "$(report)" ;;
        /speedtest) send "Меряю скорость, это займёт около 20 секунд..."; send "$(speedtest)" ;;
        /block)
            [ -n "$args" ] || { block_menu; return; }
            m=$(target_mac "$args")
            if [ -z "$m" ]; then send "Не нашёл устройство: $args"
            elif [ "$m" = "$(router_mac)" ]; then send "Сам роутер блокировать нельзя."
            else do_block "$m"; send "Заблокировано: $(devname "$m") ($m). Вернуть: /unblock $(devname "$m")"; fi ;;
        /unblock)
            [ -n "$args" ] || { unblock_menu; return; }
            m=$(target_mac "$args")
            if [ -z "$m" ]; then send "Не нашёл устройство: $args"
            else do_unblock "$m"; send "Разблокировано: $(devname "$m") ($m)"; fi ;;
        /wake)
            [ -n "$args" ] || { send "Использование: /wake <IP | MAC | имя>"; return; }
            send "$(wake "$args")" ;;
        /name)
            t=${args%% *}; nm=""; case "$args" in *" "*) nm=${args#* } ;; esac
            m=$(target_mac "$t")
            if [ -z "$t" ] || [ -z "$nm" ]; then send "Использование: /name <IP | MAC | имя> <новое имя>"
            elif [ -z "$m" ]; then send "Не нашёл устройство: $t"
            else set_name "$m" "$nm"; send "Теперь $m называется: $nm"; fi ;;
        /reboot)
            send_kb "Перезагрузить роутер? Интернет пропадёт примерно на 2 минуты." \
                '{"inline_keyboard":[[{"text":"Да, перезагрузить","callback_data":"reboot:yes"},{"text":"Отмена","callback_data":"reboot:no"}]]}' ;;
        /start|/help)
            send "$(printf '%s\n' \
'Удобнее всего — /menu: там всё по разделам.' '' \
'🏠 Дом' '/heat — отопление' '/sensors — температура, влажность, батареи' '/log [дом|сеть|люди] — журнал событий' '/home — кто дома' '' \
'🌐 Сеть' '/status — роутер' '/clients — кто в сети' '/speedtest, /speedhist — скорость и её история' '/report — DNS за сутки' '/site add|del, /sites — мониторинг сайтов' '' \
'📱 Устройства' '/watch, /unwatch — слежение' '/pause <устройство> [минут] — пауза интернета' '/block, /unblock — блокировка' '/who <устройство> — какие сайты открывает' '/wake <устройство> — включить по сети' '/scan <устройство> — открытые порты' '/name <устройство> <имя> — переименовать' '' \
'⚙️ Сервис' '/vpn [add|del Имя] — VPN' '/digest — итоги недели' '/backup — бэкап роутера' '/reboot — перезагрузка')" ;;
        *) send "Не понял. Список команд: /help" ;;
    esac
}

# нажатия на кнопки. CB_MID: id сообщения с плитками. Принцип «чистого чата»:
# сообщение с плитками удаляется, итог показывается несколько секунд (UI_TOAST) и исчезает.
handle_cb() {
    data="$1"
    case "$data" in
        allow:*)  m=${data#allow:}; ui_done "✓ Известное устройство: $(devname "$m")" ;;
        bk:*)
            m=${data#bk:}
            tg_delete "$CB_MID"; CB_MID=""
            send_kb "Заблокировать $(devname "$m") ($m)? Устройство потеряет интернет." \
                "{\"inline_keyboard\":[[{\"text\":\"Да, заблокировать\",\"callback_data\":\"block:$m\"},{\"text\":\"Отмена\",\"callback_data\":\"cancel:0\"}]]}" ;;
        block:*)
            m=${data#block:}
            if [ "$m" = "$(router_mac)" ]; then ui_done "Сам роутер блокировать нельзя."
            else do_block "$m"; ui_done "✗ Заблокировано: $(devname "$m"). Вернуть: /unblock"; fi ;;
        ub:*)     m=${data#ub:}; do_unblock "$m"; ui_done "✓ Разблокировано: $(devname "$m")" ;;
        uw:*)     m=${data#uw:}; ui_done "✓ $(watch_del "$m")" ;;
        w:home:*|w:alive:*)
            md=${data#w:}; md=${md%%:*}; m=${data#w:$md:}
            watch_tap "$md" "$m" ;;
        reboot:yes) ui_done "✓ Перезагружаюсь, напишу, когда вернусь." 10; ( sleep 3; reboot ) >/dev/null 2>&1 & ;;
        reboot:no)  ui_done "Отмена, роутер не перезагружаю." ;;
        vpnadd:*)
            id=${data#vpnadd:}; n=$(cat "/tmp/tgbot.pend.$id" 2>/dev/null); rm -f "/tmp/tgbot.pend.$id"
            tg_delete "$CB_MID"; CB_MID=""
            if vpn_name_ok "$n"; then
                if vpn_add "$n"; then toast "✓ VPN-пользователь $n создан: QR и конфиг выше (удалятся через 2 минуты)." 15
                else toast "✗ Не удалось создать $n."; fi
            else toast "Запрос устарел, повторите /vpn add Имя."; fi ;;
        vpndel:*)
            id=${data#vpndel:}; n=$(cat "/tmp/tgbot.pend.$id" 2>/dev/null); rm -f "/tmp/tgbot.pend.$id"
            if vpn_name_ok "$n"; then ui_done "✓ $(vpn_del "$n")"; else ui_done "Запрос устарел, повторите /vpn del Имя."; fi ;;
        pz:*)     m=${data#pz:}; tg_delete "$CB_MID"; CB_MID=""; pause_dur_menu "$m" ;;
        pzm:*)    r=${data#pzm:}; m=${r%:*}; ui_done "$(pause_start "$m" "${r##*:}")" 12 ;;
        who:*)    m=${data#who:}; tg_delete "$CB_MID"; CB_MID=""; send "$(who_dev "$m")" ;;
        nav:*)    menu_panel "${data#nav:}" "$CB_MID" ;;
        log:*)    log_show "${data#log:}" "$CB_MID" ;;
        ask:off)  send_kb "Выключить свет, розетки, телевизор и кондиционеры?" '{"inline_keyboard":[[{"text":"Выключить","callback_data":"haoff:1"},{"text":"Отмена","callback_data":"cancel:0"}]]}' ;;
        heat:status) tg_delete "$CB_MID"; CB_MID=""
                  [ -x "$HOOKS/heat" ] && { "$HOOKS/heat" status >/dev/null 2>&1 || toast "Home Assistant не отвечает."; } ;;
        haoff:*)  [ -x "$HOOKS/off" ] && ( "$HOOKS/off" >/dev/null 2>&1 & ); ui_done "✓ Выключаю свет, розетки и телевизор." ;;
        heat:*)   m=${data#heat:}
                  case "$m" in
                      skip) ui_done "Ок, отопление не меняю." ;;
                      auto|eco|off|ecoaway)
                          [ -x "$HOOKS/heat" ] && ( "$HOOKS/heat" "$m" >/dev/null 2>&1 & )
                          case "$m" in auto) t="авто";; eco|ecoaway) t="эконом";; off) t="выкл";; esac
                          ui_done "✓ Отопление: $t." ;;
                  esac ;;
        haskip:*) ui_done "Ок, оставляю включённым." ;;
        imhome:*) echo home > "$HOUSE"; : > "$HOLD"
                  [ -x "$HOOKS/home" ] && ( "$HOOKS/home" >/dev/null 2>&1 & )
                  ui_done "✓ Принято: считаю, что дома кто-то есть." ;;
        cancel:*)   rm -f "/tmp/tgbot.pend.${data#cancel:}"; ui_done "Отменено." ;;
        cmd:*)      handle "/${data#cmd:}" ;;
    esac
}
