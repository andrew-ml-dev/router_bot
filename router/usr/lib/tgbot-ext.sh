#!/bin/sh
# Расширения бота: присутствие, слежение за устройствами, мониторинг сайтов,
# VPN-пользователи из бота, бэкап, история скорости, трафик, недельный дайджест.
# Подключается из tgbot-lib.sh.

WATCH=/etc/tgbot.watch        # mac=home|alive
SITES=/etc/tgbot.sites        # по одной цели в строке (https://... или tcp://host:port)
SPEED=/etc/tgbot.speed        # epoch,загрузка,отдача,пинг
EVENTS=/etc/tgbot.events      # epoch|тип|текст
TRAFFIC=/etc/tgbot.traffic    # epoch,rx,tx (суточные снимки счётчиков WAN)
export BACKUP_PASS

PAUSE=/etc/tgbot.pause        # mac=epoch_конца (пауза интернета)
HOME_LEAVE_MIN=6              # минут без сигнала, чтобы считать «ушёл»
ALIVE_DOWN_MIN=60             # минут без сигнала у «живых» устройств до тревоги

# ---------- вспомогательное ----------
log_event() {   # тип текст
    echo "$(date +%s)|$1|$2" >> "$EVENTS"
    if [ "$(wc -l < "$EVENTS")" -gt 600 ]; then
        tail -n 400 "$EVENTS" > "$EVENTS.tmp" && mv "$EVENTS.tmp" "$EVENTS"
    fi
}

fmt_dur() {     # секунды -> «2д 3ч 5м»
    s=$1; [ "$s" -lt 0 ] && s=0
    d=$((s / 86400)); h=$(( (s % 86400) / 3600 )); m=$(( (s % 3600) / 60 ))
    o=""; [ "$d" -gt 0 ] && o="${d}д "; [ "$h" -gt 0 ] && o="$o${h}ч "
    echo "$o${m}м"
}

fmt_gb() { awk -v b="$1" 'BEGIN {printf "%.1f", b/1073741824}'; }

trim_file() {   # файл максимум_строк
    [ "$(wc -l < "$1" 2>/dev/null || echo 0)" -gt "$2" ] && { tail -n "$2" "$1" > "$1.tmp" && mv "$1.tmp" "$1"; }
}

# ---------- присутствие и слежение ----------
is_present() {
    m=$(lc "$1")
    for i in ra0 rax0 ra1 rax1; do
        iwinfo "$i" assoclist 2>/dev/null | grep -qi "^$m " && return 0
    done
    ip=$(mac2ip "$m")
    [ -n "$ip" ] && ping -c1 -W1 "$ip" >/dev/null 2>&1 && return 0
    return 1
}

watch_add() {   # устройство [home|alive]
    mode=${2:-home}
    case "$mode" in home|alive) ;; *) echo "Режим: home (человек: пришёл/ушёл) или alive (устройство: пропало на час)"; return ;; esac
    m=$(target_mac "$1")
    [ -n "$m" ] || { echo "Не нашёл устройство: $1"; return; }
    [ -f "$WATCH" ] && sed -i "/^$m=/d" "$WATCH"
    echo "$m=$mode" >> "$WATCH"
    rm -f "/tmp/tgbot.w.$(echo "$m" | tr -d :)"
    echo "Слежу за $(devname "$m") ($m), режим: $mode"
}

# ---------- интерфейс: плитки и редактирование сообщений ----------
send_kb_mid() {    # файл_для_message_id текст разметка
    r=$(curl -s -m 15 --data-urlencode "chat_id=$CHAT_ID" --data-urlencode "text=$2" \
        --data-urlencode "reply_markup=$3" "$API/sendMessage")
    echo "$r" | jq -r '.result.message_id // empty' > "$1"
    echo "$r" | grep -q '"ok":true'
}

# строки "подпись<TAB>callback[<TAB>подпись<TAB>callback]" -> inline-клавиатура (одна строка плиток на строку ввода)
json_kb() {
    jq -Rn '[inputs | split("\t") | [range(0; length; 2) as $i | {text: .[$i], callback_data: .[$i+1]}]]
            | {inline_keyboard: .}'
}

# ---- «чистый чат»: выбор сделан, сообщение с плитками удаляется, итог показывается ненадолго ----
UI_TOAST=${UI_TOAST:-6}   # сколько секунд показывать итог (0 = не удалять)

tg_delete() {   # message_id
    [ -n "$1" ] && [ "$1" != "-" ] || return 0
    curl -s -m 10 --data-urlencode "chat_id=$CHAT_ID" --data-urlencode "message_id=$1" \
        "$API/deleteMessage" >/dev/null 2>&1
}

toast() {       # текст [секунд] -- краткое сообщение, которое исчезает само
    secs=${2:-$UI_TOAST}
    r=$(curl -s -m 15 --data-urlencode "chat_id=$CHAT_ID" --data-urlencode "text=$1" "$API/sendMessage")
    tmid=$(echo "$r" | jq -r '.result.message_id // empty')
    echo "$tmid" > /tmp/tgbot.lastmid
    if [ -n "$tmid" ] && [ "$secs" -gt 0 ]; then delete_later "$tmid" "$secs"; fi
}

ui_done() {     # итог действия: убрать сообщение с плитками и показать итог
    [ -n "$CB_MID" ] && tg_delete "$CB_MID"
    CB_MID=""
    toast "$1" "$2"
}

# --- слежение: выбор устройства
watch_lines() {   # устройства, которые можно добавить: сначала активные, потом известные DHCP
    rmac=$(router_mac)
    { awk 'NR>1 && $3=="0x2" && $6=="br-lan" {print tolower($4)}' /proc/net/arp
      awk '{print tolower($2)}' /tmp/dhcp.leases 2>/dev/null; } | awk 'NF && !seen[$0]++' | while read -r m; do
        [ "$m" = "$rmac" ] && continue
        grep -qi "^$m=" "$WATCH" 2>/dev/null && continue
        n=$(devname "$m"); ip=$(mac2ip "$m")
        if [ "$n" = "безымянное" ]; then n="безымянное (.${ip##*.})"; [ -z "$ip" ] && n="безымянное ($m)"; fi
        printf 'Дом: %s\tw:home:%s\tЖивое: %s\tw:alive:%s\n' "$n" "$m" "$n" "$m"
    done | head -30
}
WATCH_TEXT="Выберите устройство для слежения.
Дом: человек (уведомлю, когда придёт и уйдёт)
Живое: принтер, пылесос и т.п. (уведомлю, если пропадёт больше чем на час)"
watch_menu() {
    l=$(watch_lines)
    if [ -z "$l" ]; then send "Все известные устройства уже под слежением. Список: /home"; return; fi
    send_kb "$WATCH_TEXT" "$(printf '%s\n' "$l" | json_kb)"
}
watch_tap() {   # режим mac
    ui_done "✓ $(watch_add "$2" "$1")"
}

# --- снять слежение
unwatch_lines() {
    [ -s "$WATCH" ] || return
    while IFS='=' read -r mac mode; do
        [ -n "$mac" ] || continue
        l="дом"; [ "$mode" = "alive" ] && l="живое"
        printf 'Убрать: %s [%s]\tuw:%s\n' "$(devname "$mac")" "$l" "$mac"
    done < "$WATCH"
}
unwatch_menu() {
    l=$(unwatch_lines)
    if [ -z "$l" ]; then send "Ни за чем не слежу. Добавить: /watch"; return; fi
    send_kb "Что убрать из слежения?" "$(printf '%s\n' "$l" | json_kb)"
}

# --- блокировка
block_lines() {   # активные устройства, которые ещё не заблокированы
    rmac=$(router_mac)
    awk 'NR>1 && $3=="0x2" && $6=="br-lan" {print tolower($4)}' /proc/net/arp | while read -r m; do
        [ "$m" = "$rmac" ] && continue
        is_blocked "$m" && continue
        printf 'Блок: %s\tbk:%s\n' "$(devname "$m")" "$m"
    done
}
block_menu() {
    l=$(block_lines)
    if [ -z "$l" ]; then send "Нет активных устройств для блокировки."; return; fi
    send_kb "Какое устройство заблокировать? (потребуется подтверждение)" "$(printf '%s\n' "$l" | json_kb)"
}
unblock_lines() {
    for m in $(uci -q get gl_block.block_mac.mac); do
        printf 'Вернуть: %s\tub:%s\n' "$(devname "$m")" "$(lc "$m")"
    done
}
unblock_menu() {
    l=$(unblock_lines)
    if [ -z "$l" ]; then send "Заблокированных устройств нет."; return; fi
    send_kb "Кого разблокировать?" "$(printf '%s\n' "$l" | json_kb)"
}

# --- панель команд и подсказки при вводе «/»
menu_panel() {
    send_kb "Меню" "$(printf '%s\n' \
        "Статус	cmd:status	Кто в сети	cmd:clients" \
        "Кто дома	cmd:home	VPN	cmd:vpn" \
        "Скорость	cmd:speedtest	Отчёт DNS	cmd:report" \
        "Слежение	cmd:watch	Пауза	cmd:pause" \
        "Сайты	cmd:sites	История скорости	cmd:speedhist" \
        "Что открывают	cmd:who	Блокировка	cmd:block" \
        "Помощь	cmd:help	Итоги недели	cmd:digest" | json_kb)"
}

set_commands() {
    curl -s -m 15 -H 'Content-Type: application/json' -d '{"commands":[
{"command":"menu","description":"Панель быстрых команд"},
{"command":"status","description":"Состояние роутера"},
{"command":"clients","description":"Кто в сети"},
{"command":"home","description":"Кто дома"},
{"command":"vpn","description":"VPN: кто подключён, /vpn add Имя"},
{"command":"speedtest","description":"Замер скорости интернета"},
{"command":"speedhist","description":"История скорости"},
{"command":"report","description":"DNS и блокировки за 24 часа"},
{"command":"watch","description":"Выбрать устройство для слежения"},
{"command":"unwatch","description":"Убрать устройство из слежения"},
{"command":"block","description":"Заблокировать устройство"},
{"command":"unblock","description":"Разблокировать устройство"},
{"command":"pause","description":"Интернет устройству на паузу"},
{"command":"who","description":"Какие сайты открывает устройство"},
{"command":"scan","description":"Открытые порты устройства"},
{"command":"wake","description":"Включить устройство по сети"},
{"command":"site","description":"Мониторинг сайтов: add / del"},
{"command":"sites","description":"Статус сайтов"},
{"command":"name","description":"Задать имя устройству"},
{"command":"backup","description":"Зашифрованный бэкап настроек"},
{"command":"digest","description":"Итоги недели"},
{"command":"reboot","description":"Перезагрузить роутер"},
{"command":"help","description":"Список команд"}]}' "$API/setMyCommands" >/dev/null 2>&1
}

watch_del() {
    m=$(target_mac "$1")
    [ -n "$m" ] || { echo "Не нашёл устройство: $1"; return; }
    [ -f "$WATCH" ] && sed -i "/^$m=/d" "$WATCH"
    rm -f "/tmp/tgbot.w.$(echo "$m" | tr -d :)"
    echo "Больше не слежу за $(devname "$m")"
}

who_home() {
    [ -s "$WATCH" ] || { echo "Слежение не настроено. Нажмите /watch и выберите устройства."; return; }
    now=$(date +%s); ppl=""; dev=""
    while IFS='=' read -r mac mode; do
        [ -n "$mac" ] || continue
        sf="/tmp/tgbot.w.$(echo "$mac" | tr -d :)"
        state=""; since=""
        [ -f "$sf" ] && read state _ since < "$sf"
        name=$(devname "$mac")
        dur=""; [ -n "$since" ] && [ "$since" -gt 0 ] && dur=", $(fmt_dur $((now - since)))"
        if [ "$mode" = "home" ]; then
            case "$state" in
                here) l="✓ $name: дома$dur" ;;
                away) l="✗ $name: нет дома$dur" ;;
                *)    l="… $name: проверяю" ;;
            esac
            ppl="$ppl$l
"
        else
            case "$state" in
                here) l="✓ $name: в сети$dur" ;;
                away) l="✗ $name: нет в сети$dur" ;;
                *)    l="… $name: проверяю" ;;
            esac
            dev="$dev$l
"
        fi
    done < "$WATCH"
    out="Кто дома
"
    if [ -n "$ppl" ]; then out="$out$ppl"
    else out="${out}Людей под слежением нет. Нажмите /watch и выберите «Дом: ...».
"; fi
    [ -n "$dev" ] && out="$out
Устройства
$dev"
    printf '%s' "$out"
}

# вызывается из cron раз в минуту
watch_tick() {
    [ -s "$WATCH" ] || return
    now=$(date +%s)
    while IFS='=' read -r mac mode; do
        [ -n "$mac" ] || continue
        sf="/tmp/tgbot.w.$(echo "$mac" | tr -d :)"
        name=$(devname "$mac")
        if is_present "$mac"; then cur=up; else cur=down; fi
        if [ ! -f "$sf" ]; then            # первый запуск: запомнить без уведомлений
            if [ "$cur" = "up" ]; then echo "here 0 0" > "$sf"; else echo "away 0 0" > "$sf"; fi
            continue
        fi
        read state miss since < "$sf"
        if [ "$cur" = "up" ]; then
            if [ "$state" = "away" ]; then
                gone=$(fmt_dur $((now - since)))
                if [ "$mode" = "home" ]; then qsend "$name пришёл домой (не было $gone)"
                else qsend "$name снова в сети (не было $gone)"; fi
                log_event presence "$name вернулся"
            fi
            [ "$state" != "here" ] && since=$now
            echo "here 0 $since" > "$sf"
        else
            miss=$((miss + 1))
            thr=$HOME_LEAVE_MIN; [ "$mode" = "alive" ] && thr=$ALIVE_DOWN_MIN
            if [ "$state" = "here" ] && [ "$miss" -ge "$thr" ]; then
                if [ "$mode" = "home" ]; then qsend "$name ушёл из дома"
                else qsend "$name не отвечает уже $thr мин. Проверьте питание и Wi-Fi."; fi
                log_event presence "$name пропал"
                state=away; since=$now
            fi
            echo "$state $miss $since" > "$sf"
        fi
    done < "$WATCH"
}

# ---------- проверка портов ----------
scan_device() {
    m=$(target_mac "$1")
    [ -n "$m" ] || { echo "Не нашёл устройство: $1"; return; }
    ip=$(mac2ip "$m")
    [ -n "$ip" ] || { echo "У $(devname "$m") нет IP: устройство не в сети."; return; }
    printf 'Проверка портов %s (%s)\n%s' "$(devname "$m")" "$ip" "$(lua /usr/bin/tgbot-scan.lua "$ip")"
}

# ---------- мониторинг сайтов ----------
site_id() { echo "$1" | md5sum | cut -c1-10; }

site_norm() {   # ввод пользователя -> цель
    t=$1
    case "$t" in
        *[!A-Za-z0-9._:/?=\&%~+-]*|"") return 1 ;;
    esac
    case "$t" in
        http://*|https://*|tcp://*) echo "$t" ;;
        */*) echo "https://$t" ;;
        *:*) echo "tcp://$t" ;;
        *) echo "https://$t" ;;
    esac
}

site_ok() {
    t=$1
    case "$t" in
        tcp://*) hp=${t#tcp://}; lua /usr/bin/tgbot-scan.lua --tcp "${hp%:*}" "${hp##*:}" ;;
        *) code=$(curl -s -m 10 -o /dev/null -w '%{http_code}' -L "$t" 2>/dev/null)
           case "$code" in 2*|3*) return 0 ;; *) return 1 ;; esac ;;
    esac
}

site_add() {
    t=$(site_norm "$1") || { echo "Неверный адрес. Примеры: example.com, https://example.com/health, tcp://1.2.3.4:22"; return; }
    grep -qxF "$t" "$SITES" 2>/dev/null && { echo "Уже слежу: $t"; return; }
    echo "$t" >> "$SITES"
    echo "Добавлено: $t (проверка каждые 2 минуты, тревога после 2 неудач подряд)"
}

site_del() {
    t=$(site_norm "$1") || { echo "Неверный адрес."; return; }
    [ -f "$SITES" ] && grep -qxF "$t" "$SITES" || { echo "Не нашёл в списке: $t"; return; }
    grep -vxF "$t" "$SITES" > "$SITES.tmp"; mv "$SITES.tmp" "$SITES"
    rm -f "/tmp/tgbot.s.$(site_id "$t")"
    echo "Удалено: $t"
}

sites_list() {
    [ -s "$SITES" ] || { echo "Сайтов нет. Добавьте: /site add example.com"; return; }
    now=$(date +%s)
    while read -r t; do
        [ -n "$t" ] || continue
        sf="/tmp/tgbot.s.$(site_id "$t")"
        st="ещё не проверялся"
        if [ -f "$sf" ]; then
            read s _ since < "$sf"
            if [ "$s" = "down" ]; then st="НЕ РАБОТАЕТ уже $(fmt_dur $((now - since)))"; else st="работает"; fi
        fi
        echo "$t: $st"
    done < "$SITES"
}

sites_tick() {
    [ -s "$SITES" ] || return
    now=$(date +%s)
    while read -r t; do
        [ -n "$t" ] || continue
        sf="/tmp/tgbot.s.$(site_id "$t")"
        st=up; fails=0; since=$now
        [ -f "$sf" ] && read st fails since < "$sf"
        if site_ok "$t"; then
            if [ "$st" = "down" ]; then
                d=$(fmt_dur $((now - since)))
                qsend "Сайт снова работает: $t (не работал $d)"
                log_event site "$t вернулся после $d"
            fi
            echo "up 0 $now" > "$sf"
        else
            fails=$((fails + 1))
            if [ "$st" = "up" ] && [ "$fails" -ge 2 ]; then
                qsend "Сайт недоступен: $t"
                log_event site "$t упал"
                st=down; since=$now
            fi
            echo "$st $fails $since" > "$sf"
        fi
    done < "$SITES"
}

# ---------- история скорости ----------
speed_daily() {
    set -- $(speedtest_raw)
    dl=$1; ul=$2; pg=$3
    [ "${dl:-0}" -gt 0 ] || return          # интернета нет, замер не записываем
    avg=$(tail -n 7 "$SPEED" 2>/dev/null | awk -F, '{s+=$2; n++} END {if (n>=3) printf "%d", s/n}')
    echo "$(date +%s),$dl,$ul,$pg" >> "$SPEED"
    trim_file "$SPEED" 400
    if [ -n "$avg" ] && [ "$avg" -gt 0 ] && [ $((dl * 2)) -lt "$avg" ]; then
        qsend "Скорость упала: ночной замер $dl Мбит/с при обычных ~$avg. Проверьте провайдера."
        log_event speed "упала до $dl при $avg"
    fi
}

speedhist() {
    [ -s "$SPEED" ] || { echo "Истории скорости пока нет. Автозамер идёт ночью в 04:00."; return; }
    tail -n 14 "$SPEED" | awk -F, '
        BEGIN { split("▁ ▂ ▃ ▄ ▅ ▆ ▇ █", ch, " ") }
        { d[NR]=$2; if ($2>mx) mx=$2; if (mn=="" || $2<mn) mn=$2; s+=$2 }
        END {
            line=""
            for (i=1; i<=NR; i++) { k=(mx>0) ? int(d[i]/mx*7)+1 : 1; if (k>8) k=8; line=line ch[k] }
            printf "Скорость, последние %d замеров\n%s\nЗагрузка: мин %d, средняя %d, макс %d Мбит/с\n\n", NR, line, mn, s/NR, mx
        }'
    tail -n 7 "$SPEED" | while IFS=, read -r t d u p; do
        echo "$(date -d "@$t" +%d.%m)  вниз $d  вверх $u  пинг $p мс"
    done
}

# ---------- трафик WAN ----------
traffic_snap() {
    dev=$(ubus call network.interface.wan status 2>/dev/null | jq -r '.l3_device // .device // empty')
    [ -n "$dev" ] && [ -r "/sys/class/net/$dev/statistics/rx_bytes" ] || return
    echo "$(date +%s),$(cat "/sys/class/net/$dev/statistics/rx_bytes"),$(cat "/sys/class/net/$dev/statistics/tx_bytes")" >> "$TRAFFIC"
    trim_file "$TRAFFIC" 400
}

traffic_week() {   # печатает "rx tx" в байтах за 7 дней
    cut=$(( $(date +%s) - 604800 ))
    awk -F, -v c="$cut" 'NR>1 && $1>=c { dr = ($2>=pr) ? $2-pr : $2; dt = ($3>=pt) ? $3-pt : $3; r+=dr; t+=dt }
                         { pr=$2; pt=$3 } END { printf "%.0f %.0f", r, t }' "$TRAFFIC" 2>/dev/null
}

# ---------- недельный дайджест ----------
digest() {
    now=$(date +%s); cut=$((now - 604800))
    nd=$(awk -F'|' -v c="$cut" '$1>=c && $2=="new" {print $3}' "$EVENTS" 2>/dev/null)
    ncount=$(echo "$nd" | grep -c . )
    [ -z "$nd" ] && ncount=0
    wan=$(awk -F'|' -v c="$cut" '$1>=c && $2=="wan" {n++; s+=$3} END {printf "%d %d", n, s}' "$EVENTS" 2>/dev/null)
    set -- $wan; wn=${1:-0}; wm=${2:-0}
    sp=$(awk -F, -v c="$cut" '$1>=c {s+=$2; n++; if (mn==""||$2<mn) mn=$2} END {if (n) printf "средняя %d, минимум %d Мбит/с (%d замеров)", s/n, mn, n; else printf "нет данных"}' "$SPEED" 2>/dev/null)
    set -- $(traffic_week); rx=${1:-0}; tx=${2:-0}
    up=$(awk '{d=int($1/86400); h=int(($1%86400)/3600); printf "%dд %dч", d, h}' /proc/uptime)
    printf 'Итоги недели\n\n%s\n\nНовые устройства: %s\n%s\nСкорость: %s\nТрафик WAN: вниз %s ГБ, вверх %s ГБ\nПеребоев интернета: %s (всего %s мин)\nАптайм роутера: %s' \
        "$(report 604800)" "$ncount" "$(echo "$nd" | sed '/^$/d; s/^/  /')" "$sp" "$(fmt_gb "$rx")" "$(fmt_gb "$tx")" "$wn" "$wm" "$up"
}

# ---------- бэкап конфигурации ----------
do_backup() {
    [ -n "$BACKUP_PASS" ] || { echo "Бэкап выключен: задайте BACKUP_PASS в /etc/tgbot.conf (пароль шифрования бэкапа). Без пароля я не отправляю конфигурацию в Telegram."; return 1; }
    f="/tmp/router-backup-$(date +%Y%m%d).tar.gz"
    sysupgrade -b "$f" >/dev/null 2>&1 || { rm -f "$f"; echo "Не удалось создать бэкап."; return 1; }
    openssl enc -aes-256-cbc -pbkdf2 -iter 100000 -salt -pass env:BACKUP_PASS -in "$f" -out "$f.enc" 2>/dev/null \
        || { rm -f "$f" "$f.enc"; echo "Не удалось зашифровать бэкап."; return 1; }
    rm -f "$f"
    sz=$(wc -c < "$f.enc")
    if curl -s -m 90 -F "chat_id=$CHAT_ID" -F "document=@$f.enc" \
        -F "caption=Бэкап конфигурации роутера $(date +%d.%m.%Y), зашифрован вашим BACKUP_PASS (AES-256). Расшифровка описана в docs/BACKUP.md" \
        "$API/sendDocument" | grep -q '"ok":true'; then
        rm -f "$f.enc"; echo "Бэкап отправлен ($((sz / 1024)) КБ)."
    else
        rm -f "$f.enc"; echo "Не удалось отправить бэкап."; return 1
    fi
}

# ---------- VPN-пользователи из бота ----------
vpn_find() {    # имя -> секция uci
    for sec in $(uci -q show wireguard_server | grep -o 'peer_[0-9]*=peers' | cut -d= -f1); do
        [ "$(uci -q get wireguard_server.$sec.name)" = "$1" ] && { echo "$sec"; return; }
    done
}

vpn_name_ok() {
    case "$1" in ""|*[!A-Za-z0-9_-]*) return 1 ;; esac
    [ "${#1}" -le 24 ]
}

delete_later() {   # message_id секунд
    ( sleep "$2"; curl -s -m 10 --data-urlencode "chat_id=$CHAT_ID" --data-urlencode "message_id=$1" \
        "$API/deleteMessage" >/dev/null 2>&1 ) >/dev/null 2>&1 &
}

vpn_add() {     # имя; шлёт QR и конфиг в чат
    name=$1
    [ -z "$(vpn_find "$name")" ] || { send "Пользователь $name уже существует."; return 1; }
    base=$(uci -q get wireguard_server.main_server.address_v4 | cut -d/ -f1 | sed 's/\.[0-9]*$//')
    v6=$(uci -q get wireguard_server.main_server.address_v6 | cut -d/ -f1 | sed 's/::1$//')
    [ -n "$base" ] || { send "Не нашёл настройки WireGuard-сервера."; return 1; }
    used=$(uci -q show wireguard_server | grep "\.client_ip=" | grep -o "$base\.[0-9]*" | grep -o '[0-9]*$')
    n=2; while echo "$used" | grep -qx "$n"; do n=$((n + 1)); done
    [ "$n" -le 250 ] || { send "Нет свободных адресов в VPN-сети."; return 1; }
    id=$(( $(date +%s) % 9000 + 1000 ))
    while uci -q get "wireguard_server.peer_$id" >/dev/null; do id=$((id + 1)); done
    sec=peer_$id
    priv=$(wg genkey); pub=$(printf '%s' "$priv" | wg pubkey)
    cip="$base.$n/24"; dns="$base.1"
    if [ -n "$v6" ]; then cip="$cip,$v6::$n/64"; dns="$dns,$v6::1"; fi
    uci set "wireguard_server.$sec=peers"
    uci set "wireguard_server.$sec.name=$name"
    uci set "wireguard_server.$sec.peer_id=$id"
    uci set "wireguard_server.$sec.presharedkey_enable=0"
    uci set "wireguard_server.$sec.allowed_ips=0.0.0.0/0,::/0"
    uci set "wireguard_server.$sec.mtu=1420"
    uci set "wireguard_server.$sec.persistent_keepalive=25"
    uci set "wireguard_server.$sec.public_key=$pub"
    uci set "wireguard_server.$sec.private_key=$priv"
    uci set "wireguard_server.$sec.client_ip=$cip"
    uci set "wireguard_server.$sec.deprecated=0"
    uci set "wireguard_server.$sec.dns=$dns"
    uci commit wireguard_server
    wg set wgserver peer "$pub" allowed-ips "$base.$n/32"
    port=$(uci -q get wireguard_server.main_server.port)
    srvpub=$(wg show wgserver public-key)
    host=${VPN_ENDPOINT:-$(ubus call network.interface.wan status 2>/dev/null | jq -r '.["ipv4-address"][0].address // empty')}
    [ -n "$host" ] || { send "Не знаю внешний адрес роутера. Задайте VPN_ENDPOINT в /etc/tgbot.conf."; return 1; }
    umask 077
    conf="/tmp/vpn-$id.conf"; png="/tmp/vpn-$id.png"
    printf '[Interface]\nPrivateKey = %s\nAddress = %s/24\nDNS = %s\nMTU = 1420\n\n[Peer]\nPublicKey = %s\nEndpoint = %s:%s\nAllowedIPs = 0.0.0.0/0, ::/0\nPersistentKeepalive = 25\n' \
        "$priv" "$base.$n" "$base.1" "$srvpub" "$host" "$port" > "$conf"
    qrencode -t ASCII -m 0 -l M -o - < "$conf" | lua /usr/bin/tgbot-png.lua "$png" 6
    cap="VPN: $name. Адрес $base.$n. ПРИВАТНЫЙ КЛЮЧ внутри: сканируйте и удалите сообщение. Оно удалится само через 2 минуты."
    resp=$(curl -s -m 30 -F "chat_id=$CHAT_ID" -F "photo=@$png" -F "caption=$cap" "$API/sendPhoto")
    mid=$(echo "$resp" | jq -r '.result.message_id // empty'); [ -n "$mid" ] && delete_later "$mid" 120
    resp=$(curl -s -m 30 -F "chat_id=$CHAT_ID" -F "document=@$conf;filename=$name.conf" -F "caption=Конфиг для ноутбука: $name.conf (удалится через 2 минуты)" "$API/sendDocument")
    mid=$(echo "$resp" | jq -r '.result.message_id // empty'); [ -n "$mid" ] && delete_later "$mid" 120
    rm -f "$conf" "$png"
    log_event vpn "создан пользователь $name"
}

vpn_del() {
    sec=$(vpn_find "$1")
    [ -n "$sec" ] || { echo "Не нашёл VPN-пользователя: $1"; return 1; }
    pub=$(uci -q get "wireguard_server.$sec.public_key")
    [ -n "$pub" ] && wg set wgserver peer "$pub" remove 2>/dev/null
    uci delete "wireguard_server.$sec"
    uci commit wireguard_server
    log_event vpn "удалён пользователь $1"
    echo "VPN-пользователь $1 удалён."
}

vpn_names() {
    for sec in $(uci -q show wireguard_server | grep -o 'peer_[0-9]*=peers' | cut -d= -f1); do
        uci -q get "wireguard_server.$sec.name"
    done
}

# ---------- пауза интернета ----------
pause_start() {   # mac минут
    pm=$1; pmin=$2
    [ "$pm" = "$(router_mac)" ] && { echo "Сам роутер блокировать нельзя."; return; }
    case "$pmin" in ""|*[!0-9]*) pmin=30 ;; esac
    [ "$pmin" -ge 1 ] && [ "$pmin" -le 1440 ] || { echo "Минут от 1 до 1440."; return; }
    do_block "$pm"
    [ -f "$PAUSE" ] && sed -i "/^$pm=/d" "$PAUSE"
    echo "$pm=$(( $(date +%s) + pmin * 60 ))" >> "$PAUSE"
    echo "⏸ $(devname "$pm"): интернет на паузе $pmin мин, потом включу сам. Раньше: /unblock"
}

pause_tick() {   # cron: снять истёкшие паузы
    [ -s "$PAUSE" ] || return
    now=$(date +%s)
    while IFS='=' read -r pm end; do
        [ -n "$pm" ] || continue
        [ "$now" -ge "${end:-0}" ] || continue
        do_unblock "$pm"
        qsend "▶ $(devname "$pm"): пауза закончилась, интернет снова есть."
    done < "$PAUSE"
}

pause_lines() {
    rmac=$(router_mac)
    awk 'NR>1 && $3=="0x2" && $6=="br-lan" {print tolower($4)}' /proc/net/arp | while read -r m; do
        [ "$m" = "$rmac" ] && continue
        is_blocked "$m" && continue
        printf 'Пауза: %s\tpz:%s\n' "$(devname "$m")" "$m"
    done
}
pause_menu() {
    l=$(pause_lines)
    if [ -z "$l" ]; then send "Нет активных устройств."; return; fi
    send_kb "Кому поставить интернет на паузу?" "$(printf '%s\n' "$l" | json_kb)"
}
pause_dur_menu() {   # mac
    send_kb "На сколько поставить на паузу: $(devname "$1")?" \
        "{\"inline_keyboard\":[[{\"text\":\"15 мин\",\"callback_data\":\"pzm:$1:15\"},{\"text\":\"30 мин\",\"callback_data\":\"pzm:$1:30\"},{\"text\":\"1 час\",\"callback_data\":\"pzm:$1:60\"},{\"text\":\"2 часа\",\"callback_data\":\"pzm:$1:120\"}],[{\"text\":\"Отмена\",\"callback_data\":\"cancel:0\"}]]}"
}

# ---------- /who: что открывает устройство ----------
who_dev() {
    wm=$(target_mac "$1"); wip=""; wlbl=""
    if [ -n "$wm" ]; then wip=$(mac2ip "$wm"); wlbl=$(devname "$wm")
    else
        vs=$(vpn_find "$1")
        [ -n "$vs" ] && { wip=$(uci -q get "wireguard_server.$vs.client_ip" | cut -d/ -f1); wlbl="VPN $1"; }
    fi
    [ -n "$wlbl" ] || { echo "Не нашёл устройство: $1"; return; }
    [ -n "$wip" ] || { echo "У $wlbl нет IP: устройство не в сети."; return; }
    [ -s "$QLOG" ] || { echo "Журнал AdGuard пуст."; return; }
    wc=$(date -u -d "@$(( $(date +%s) - 86400 ))" +%Y-%m-%dT%H:%M 2>/dev/null)
    jq -c --arg c "$wc" --arg ip "$wip" 'select(.IP==$ip and .T > $c)' "$QLOG" 2>/dev/null > /tmp/tgbot.who
    wt=$(wc -l < /tmp/tgbot.who)
    wb=$(jq -c 'select(.Result.IsFiltered==true)' /tmp/tgbot.who 2>/dev/null | wc -l)
    wtop=$(jq -r '.QH' /tmp/tgbot.who 2>/dev/null | sort | uniq -c | sort -rn | head -10 | awk '{print "  "$2" ("$1")"}')
    rm -f /tmp/tgbot.who
    printf '%s (%s) за 24 часа\nЗапросов: %s, заблокировано: %s\n\nЧаще всего:\n%s' "$wlbl" "$wip" "$wt" "$wb" "${wtop:-  нет данных}"
}
who_lines() {
    awk 'NR>1 && $3=="0x2" && $6=="br-lan" {print tolower($4)}' /proc/net/arp | while read -r m; do
        printf '%s\twho:%s\n' "$(devname "$m")" "$m"
    done
    vpn_names | while read -r n; do printf 'VPN: %s\twho:%s\n' "$n" "$n"; done
}

vpn_ipname() {   # 10.0.0.x -> имя VPN-пользователя
    for sec in $(uci -q show wireguard_server | grep -o 'peer_[0-9]*=peers' | cut -d= -f1); do
        case "$(uci -q get "wireguard_server.$sec.client_ip")" in "$1"/*) echo "VPN $(uci -q get "wireguard_server.$sec.name")"; return ;; esac
    done
}

# ---------- очередь недоставленных уведомлений ----------
OUTBOX=/tmp/tgbot.outbox
qsend() {   # как send, но при неудаче кладёт в очередь (отправится позже из cron)
    send "$1" && return 0
    mkdir -p "$OUTBOX"; printf '%s' "$1" > "$OUTBOX/$(date +%s).$$.$RANDOM"
    return 1
}
flush_outbox() {
    [ -d "$OUTBOX" ] || return 0
    for f in $(ls "$OUTBOX" 2>/dev/null | sort); do
        [ -n "$(find "$OUTBOX/$f" -mmin +360 2>/dev/null)" ] && { rm -f "$OUTBOX/$f"; continue; }
        send "$(cat "$OUTBOX/$f")" && rm -f "$OUTBOX/$f" || break
    done
}
