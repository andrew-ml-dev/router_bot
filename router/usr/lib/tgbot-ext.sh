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

# --- панель команд: главное меню и разделы; переходы редактируют то же сообщение
menu_rows() {   # раздел -> первая строка: заголовок, дальше строки плиток
    case "$1" in
        home) printf '%s\n' "🏠 Дом" \
            "Кто дома	cmd:home	Датчики и батареи	cmd:sensors" \
            "📈 Графики	cmd:graph	Журнал дома	cmd:log дом" \
            "📅 Календарь	cmd:cal" \
            "👋 Ухожу	ask:leave	Выключить всё	ask:off" \
            "‹ Назад	nav:main" ;;
        net) printf '%s\n' "🌐 Сеть" \
            "Статус роутера	cmd:status	Кто в сети	cmd:clients" \
            "Скорость	cmd:speedtest	История скорости	cmd:speedhist" \
            "Отчёт DNS	cmd:report	Сайты	cmd:sites" \
            "‹ Назад	nav:main" ;;
        dev) printf '%s\n' "📱 Устройства" \
            "Следить	cmd:watch	Не следить	cmd:unwatch" \
            "Пауза интернета	cmd:pause	Что открывают	cmd:who" \
            "Заблокировать	cmd:block	Разблокировать	cmd:unblock" \
            "‹ Назад	nav:main" ;;
        svc) printf '%s\n' "⚙️ Сервис" \
            "VPN	cmd:vpn	Итоги недели	cmd:digest" \
            "Бэкап роутера	cmd:backup	Перезагрузка	cmd:reboot" \
            "Помощь	cmd:help	‹ Назад	nav:main" ;;
        *) printf '%s\n' "Меню" \
            "🏠 Дом	nav:home	🌡 Отопление	cmd:heat" \
            "📋 Журнал	cmd:log	🌐 Сеть	nav:net" \
            "📱 Устройства	nav:dev	⚙️ Сервис	nav:svc" ;;
    esac
}
menu_panel() {   # [раздел] [message_id для редактирования]
    r=$(menu_rows "$1")
    t=$(echo "$r" | head -n1); kb=$(echo "$r" | tail -n +2 | json_kb)
    if [ -n "$2" ]; then edit_msg "$2" "$t" "$kb"; else send_kb "$t" "$kb"; fi
}

# подсказки при вводе «/»: только частые команды, остальные доступны через /menu и работают, если их набрать
set_commands() {
    curl -s -m 15 -H 'Content-Type: application/json' -d '{"commands":[
{"command":"menu","description":"Меню: дом, сеть, устройства, сервис"},
{"command":"heat","description":"Отопление: температуры и режим"},
{"command":"sensors","description":"Датчики, температура, батареи"},
{"command":"log","description":"Журнал событий"},
{"command":"home","description":"Кто дома"},
{"command":"status","description":"Состояние роутера"},
{"command":"clients","description":"Кто в сети"},
{"command":"help","description":"Все команды"}]}' "$API/setMyCommands" >/dev/null 2>&1
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
                if [ "$mode" = "home" ]; then log_event presence "$name пришёл домой (не было $gone)"
                else log_event presence "$name снова в сети (не было $gone)"; fi
            fi
            [ "$state" != "here" ] && since=$now
            echo "here 0 $since" > "$sf"
        else
            miss=$((miss + 1))
            thr=$HOME_LEAVE_MIN; [ "$mode" = "alive" ] && thr=$ALIVE_DOWN_MIN
            if [ "$state" = "here" ] && [ "$miss" -ge "$thr" ]; then
                if [ "$mode" = "home" ]; then log_event presence "$name ушёл из дома"
                else log_event presence "$name не отвечает уже $thr мин"; fi
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
qsend() {   # текст [q]: как send, но при неудаче кладёт в очередь (отправится позже из cron, без звука)
    send "$1" "$2" && return 0
    mkdir -p "$OUTBOX"; printf '%s' "$1" > "$OUTBOX/$(date +%s).$$.$RANDOM"
    return 1
}
flush_outbox() {
    [ -d "$OUTBOX" ] || return 0
    for f in $(ls "$OUTBOX" 2>/dev/null | sort); do
        [ -n "$(find "$OUTBOX/$f" -mmin +360 2>/dev/null)" ] && { rm -f "$OUTBOX/$f"; continue; }
        send "$(cat "$OUTBOX/$f")" q && rm -f "$OUTBOX/$f" || break
    done
}

# ---------- состояние дома: «кто-то дома» / «никого нет» ----------
HOOKS=/etc/tgbot.hooks       # исполняемые файлы away и home: вызываются при смене состояния
HOUSE=/tmp/tgbot.house
HOLD=/tmp/tgbot.hold
house_tick() {   # cron: учитывает только устройства в режиме home; пока состояние неясно, молчит
    [ -s "$WATCH" ] || return
    hp=0; hh=0; hu=0
    while IFS='=' read -r hm hmode; do
        [ "$hmode" = "home" ] || continue
        hp=1
        hsf="/tmp/tgbot.w.$(echo "$hm" | tr -d :)"
        if [ -f "$hsf" ]; then read hst _ < "$hsf"; [ "$hst" = "here" ] && hh=1; else hu=1; fi
    done < "$WATCH"
    [ "$hp" = 1 ] && [ "$hu" = 0 ] || return
    hnew=home; [ "$hh" = 0 ] && hnew=empty
    hprev=$(cat "$HOUSE" 2>/dev/null)
    if [ "$hnew" = home ]; then rm -f "$HOLD"; elif [ -e "$HOLD" ]; then return; fi   # «Это я»: не считать пустым, пока Wi-Fi не вернётся
    echo "$hnew" > "$HOUSE"
    [ -n "$hprev" ] && [ "$hprev" != "$hnew" ] || return
    if [ "$hnew" = empty ]; then hk=away; else hk=home; fi
    log_event house "$hk"
    if [ -x "$HOOKS/$hk" ]; then ( "$HOOKS/$hk" >/dev/null 2>&1 & )      # решает и пишет Home Assistant
    elif [ "$hk" = away ]; then qsend "🏠 Из Wi-Fi пропали все, кто в режиме «Дом»." q
    else qsend "🏠 В Wi-Fi вернулся кто-то из режима «Дом»." q; fi
}


# ---- журнал: события роутера (/etc/tgbot.events) + важное из Home Assistant, с временем ----
HAENV=/etc/tgbot.ha            # HA_URL и HA_TOKEN (чтение журнала HA); без файла журнал только роутерный
log_ha() {   # строки «epoch<TAB>текст» за последние 24 ч
    [ -r "$HAENV" ] || return
    . "$HAENV"
    st=$(date -u -d "@$(( $(date +%s) - 86400 ))" +%Y-%m-%dT%H:%M:%SZ)
    ents="binary_sensor.koridor_otkrytiia_door,binary_sensor.tualet_dvizhenie_motion,binary_sensor.vibration_sensor_occupancy,input_boolean.house_empty,input_select.heat_mode"
    curl -s -m 20 -H "Authorization: Bearer $HA_TOKEN" "$HA_URL/api/history/period/$st?filter_entity_id=$ents&minimal_response&no_attributes" 2>/dev/null | jq -r '
      {"binary_sensor.koridor_otkrytiia_door":{"on":"🚪 Входная дверь открыта","off":"🚪 Входная дверь закрыта"},
       "binary_sensor.tualet_dvizhenie_motion":{"on":"🚽 Движение в туалете"},
       "binary_sensor.vibration_sensor_occupancy":{"on":"📳 Вибрация"},
       "input_boolean.house_empty":{"on":"🏠 Дом считается пустым","off":"🏠 Кто-то дома"},
       "input_select.heat_mode":{"auto":"🌡 Отопление: авто","eco":"🌡 Отопление: эконом","off":"🌡 Отопление: выкл"}} as $m
      | .[]? | (.[0].entity_id // "") as $e | .[1:][]? | select(.state != null) | (($m[$e] // {})[.state]) as $t | select($t != null)
      | "\((.last_changed[0:19] + "Z") | fromdateiso8601)\t\($t)"' 2>/dev/null
}
log_router() {   # [nopresence|presence] -> строки «epoch<TAB>текст» из журнала роутера за 24 ч
    cut=$(( $(date +%s) - 86400 ))
    awk -F'|' -v c="$cut" -v f="$1" '$1>=c && !(f=="nopresence" && $2=="presence") && !(f=="presence" && $2!="presence") {
        t=$3; e="•"
        if ($2=="presence") e="📶"; else if ($2=="new") {e="🆕"; t="Новое устройство: " $3}
        else if ($2=="wan") {e="🌐"; t="Интернета не было " $3 " мин"} else if ($2=="vpn") e="🔐"
        else if ($2=="site") e="🌍"; else if ($2=="speed") {e="⚡"; t="Скорость " $3}
        else if ($2=="house") {e="🏠"; t=($3=="away"?"Дом пуст":"Кто-то дома")}
        print $1 "\t" e " " t }' "$EVENTS" 2>/dev/null
}
log_src() {   # фильтр -> строки «epoch<TAB>текст»
    case "$1" in
        дом|home|dom) log_ha ;;
        сеть|net)     log_router nopresence ;;
        люди|ppl)     log_router presence ;;
        *)            printf '%s\n%s\n' "$(log_ha)" "$(log_router nopresence)" ;;
    esac
}
log_view() {   # [дом|сеть|люди] — новые сверху, по дням; одинаковые события подряд (в пределах 30 мин) схлопываются
    case "$1" in дом|home|dom) h="дом";; сеть|net) h="сеть";; люди|ppl) h="кто когда был в сети";; *) h="главное";; esac
    today=$(date +%Y%m%d)
    out=$(log_src "$1" | awk -F'\t' 'NF>=2' | sort -t"$(printf '\t')" -k1,1 -n -r | awk -F'\t' '
        function flush() { if (n) print nt "\t" ot "\t" n "\t" pt; n = 0 }
        { if ($2 == pt && ot - $1 < 1800) { ot = $1; n++; next } flush(); pt = $2; nt = $1; ot = $1; n = 1 }
        END { flush() }' | head -n 30 \
        | while IFS="$(printf '\t')" read nt ot n txt; do
            d=$(date -d "@$nt" +%Y%m%d)
            if [ "$d" != "$pd" ]; then
                [ -n "$pd" ] && echo
                if [ "$d" = "$today" ]; then echo "Сегодня"; else echo "Вчера"; fi
                pd=$d
            fi
            if [ "$n" -gt 1 ]; then echo "$(date -d "@$ot" +%H:%M)–$(date -d "@$nt" +%H:%M)  $txt ×$n"
            else echo "$(date -d "@$nt" +%H:%M)  $txt"; fi
        done)
    [ -n "$out" ] || out="За последние сутки событий нет."
    printf '📋 Журнал за сутки: %s\n\n%s' "$h" "$out"
}
log_kb() {   # текущий фильтр -> плитки фильтров
    for f in all dom net ppl; do
        case "$f" in all) l="Главное";; dom) l="Дом";; net) l="Сеть";; ppl) l="Люди";; esac
        [ "$f" = "${1:-all}" ] && l="• $l"
        printf '%s\tlog:%s\t' "$l" "$f"
    done | sed 's/\t$//' | json_kb
}
log_show() {   # фильтр [message_id]: новое сообщение или замена на месте
    case "$1" in дом|home|dom) f=dom;; сеть|net) f=net;; люди|ppl) f=ppl;; *) f=all;; esac
    if [ -n "$2" ]; then edit_msg "$2" "$(log_view "$f")" "$(log_kb "$f")"
    else send_kb "$(log_view "$f")" "$(log_kb "$f")"; fi
}

# ---- данные Home Assistant: датчики, батареи, погода ----
ha_states() { [ -r "$HAENV" ] || return 1; . "$HAENV"; curl -s -m 15 -H "Authorization: Bearer $HA_TOKEN" "$HA_URL/api/states" 2>/dev/null; }
ha_forecast() {   # прогноз на сегодня: «макс мин состояние»
    [ -r "$HAENV" ] || return 1; . "$HAENV"
    curl -s -m 15 -X POST -H "Authorization: Bearer $HA_TOKEN" -H 'Content-Type: application/json' \
        -d '{"entity_id":"weather.home","type":"daily"}' "$HA_URL/api/services/weather/get_forecasts?return_response" 2>/dev/null \
        | jq -r --arg d "$(date -u +%Y-%m-%d)" '[.service_response["weather.home"].forecast[]? | select(.datetime[0:10] >= $d)][0] // empty | "\((.temperature|round) + 0) \((.templow|round) + 0) \(.condition)"' 2>/dev/null
}
# общие jq-определения: комнаты, погода, батареи, пропавшие датчики
HA_JQ='(map({key: .entity_id, value: .}) | from_entries) as $s
  | def st($e): ($s[$e].state // "unavailable");
    def n($e): (st($e) | tonumber? // null);
    def wx($c): ({"clear-night":"ясно","sunny":"солнечно","partlycloudy":"переменная облачность","cloudy":"облачно","rainy":"дождь","pouring":"ливень","snowy":"снег","snowy-rainy":"мокрый снег","fog":"туман","windy":"ветрено","windy-variant":"ветрено, облачно","hail":"град","lightning":"гроза","lightning-rainy":"гроза с дождём"}[$c] // $c);
    def rooms: [
      ("Спальня" as $r | n("sensor.temperatura_temperature") as $t | n("sensor.temperatura_humidity") as $h
        | if $t then "\($r) \($t)°\(if $h then " · \($h|round)%" else "" end)" else "\($r): датчик не отвечает" end),
      ("Туалет" as $r | n("sensor.tualet_temp_temperature") as $t | n("sensor.tualet_temp_humidity") as $h
        | if $t then "\($r) \($t)°\(if $h then " · \($h|round)%" else "" end)" else "\($r): датчик не отвечает" end),
      ("Зал" as $r | n("sensor.spalnia_temperatura_temperature") as $t | n("sensor.spalnia_temperatura_humidity") as $h
        | if $t then "\($r) \($t)°\(if $h then " · \($h|round)%" else "" end)" else "\($r): датчик не отвечает" end)];
    def thr: (n("input_number.battery_low") // 20);
    def batt: [.[] | select(.attributes.device_class == "battery" and .attributes.unit_of_measurement == "%"
        and (.entity_id | startswith("sensor.pixel") | not) and (.state | tonumber? // null) != null)]
        | sort_by(.state | tonumber)
        | map({n: (.attributes.friendly_name | rtrimstr(" Батарея") | rtrimstr(" ")), v: (.state | tonumber | round)});
    def gone: [["binary_sensor.koridor_otkrytiia_door","Входная дверь"],
        ["binary_sensor.tualet_dvizhenie_motion","Движение прихожая"],["binary_sensor.motion_sensor_2_motion","Движение в туалете"],["sensor.spalnia_temperatura_temperature","Температура зал"],["sensor.temperatura_temperature","Температура спальня"],
        ["sensor.tualet_temp_temperature","Температура туалет"],["climate.zal_levyi","Радиатор зал левый"],
        ["climate.zal_pravyi_divan","Радиатор зал правый"],["climate.spalnia_radiator","Радиатор спальня"],
        ["climate.tualet_radiator","Радиатор туалет"]] | map(select(st(.[0]) == "unavailable") | .[1]);
    def heat: ({"auto":"авто","eco":"эконом","off":"выкл"}[st("input_select.heat_mode")] // "?") as $m
        | n("sensor.tselevaia_temperatura") as $t
        | "Отопление: \($m)\(if $t then ", цель \($t|round)°" elif $m == "авто" then ", на улице тепло — не греем" else "" end)";
    def outdoor: ($s["weather.home"].attributes.temperature // null) as $t
        | if $t then "Улица \($t|round)°, \(wx(st("weather.home")))" else "Улица: нет данных" end;'

sensors_view() {
    j=$(ha_states) || { echo "Home Assistant не подключён: нет /etc/tgbot.ha."; return; }
    [ -n "$j" ] || { echo "Home Assistant не отвечает."; return; }
    echo "$j" | jq -r "$HA_JQ"'
      "🌡 Температура\n" + (rooms | join("\n")) + "\n" + outdoor + "\n" + heat
      + "\n\n🔋 Батареи (предупреждаю ниже \(thr|round)%)\n"
      + (batt | map("\(if .v < thr then "⚠️ " else "" end)\(.n): \(.v)%") | join("\n"))
      + (gone | if length > 0 then "\n\n📡 Не отвечают: " + join(", ") else "\n\n📡 Все датчики на связи" end)' 2>/dev/null \
      || echo "Не удалось разобрать ответ Home Assistant."
}

# ---- погода на день: по часам из прогноза HA (met.no), совет по одежде ----
day_weather() {
    [ -r "$HAENV" ] || return 1; . "$HAENV"
    tz=$(date +%z | awk '{s=substr($0,1,1); h=substr($0,2,2); m=substr($0,4,2); print (s=="-"?-1:1)*(h*3600+m*60)}')
    sunset=$(curl -s -m 10 -H "Authorization: Bearer $HA_TOKEN" "$HA_URL/api/states/sun.sun" 2>/dev/null \
        | jq -r '.attributes.next_setting // empty | .[0:19] + "Z" | fromdateiso8601' 2>/dev/null)
    [ -n "$sunset" ] && sunset=$(date -d "@$sunset" +%H:%M)
    curl -s -m 15 -X POST -H "Authorization: Bearer $HA_TOKEN" -H 'Content-Type: application/json' \
        -d '{"entity_id":"weather.home","type":"hourly"}' "$HA_URL/api/services/weather/get_forecasts?return_response" 2>/dev/null \
    | jq -r --argjson tz "$tz" --arg today "$(date +%Y-%m-%d)" --arg sunset "$sunset" '
      def wx($c): ({"clear-night":"ясно","sunny":"солнечно","partlycloudy":"переменная облачность","cloudy":"облачно","rainy":"дождь","pouring":"ливень","snowy":"снег","snowy-rainy":"мокрый снег","fog":"туман","windy":"ветрено","windy-variant":"ветрено","hail":"град","lightning":"гроза","lightning-rainy":"гроза с дождём"}[$c] // $c);
      def r: (round + 0);
      def top: group_by(.) | max_by(length) | .[0];
      [.service_response["weather.home"].forecast[]?
        | ((.datetime[0:19] + "Z") | fromdateiso8601) as $t | ($t + $tz) as $l
        | select(($l | todate | .[0:10]) == $today)
        | . + {h: (($l % 86400) / 3600 | floor),
               feels: (.temperature - (.wind_speed / 3.6) * 0.7)}   # грубо: ветер «холодит» ~0.7° на каждый м/с
        | select(.h >= 7 and .h <= 21)] as $d
      | if ($d | length) == 0 then empty else
        def part($a; $b; $n): ([$d[] | select(.h >= $a and .h <= $b)]) as $p
          | if ($p | length) == 0 then empty else
            "\($n) \($p | map(.temperature) | min | r)…\($p | map(.temperature) | max | r)°" end;
        ($d | map(.temperature)) as $tt | ($d | map(.feels) | min) as $fmin
        | ($d | map(.precipitation // 0) | add) as $pr
        | ([$d[] | select((.precipitation // 0) > 0.1) | .h]) as $wet
        | ($d | map(.wind_speed) | max) as $wind
        | ($d | map(.uv_index // 0) | max) as $uv
        | ([$d[] | .condition] | map(select(. as $c | ["snowy","snowy-rainy","hail"] | index($c))) | length > 0) as $snow
        | "🌤 Погода сегодня: \($tt | min | r)…\($tt | max | r)°, \(wx([$d[] | .condition] | top))"
        + "\n" + ([part(7; 10; "утро"), part(11; 16; "день"), part(17; 21; "вечер")] | join(", "))
        + "\n" + (if $pr >= 0.3 then "\(if $snow then "❄️ снег" else "☔ осадки" end) \($wet | min)–\($wet | max + 1) ч, около \($pr * 10 | round / 10) мм — \(if $snow then "непромокаемая обувь" else "возьмите зонт" end)"
                  else "без осадков" end)
          + ", ветер до \($wind | r) км/ч\(if $wind >= 40 then " — сильный" else "" end)"
        + "\n👕 " + (if $fmin <= -10 then "пуховик, шапка, перчатки и шарф"
                    elif $fmin <= 0 then "тёплая куртка, шапка и перчатки"
                    elif $fmin <= 7 then "куртка или пальто, шапка не помешает"
                    elif $fmin <= 13 then "лёгкая куртка или плащ"
                    elif $fmin <= 18 then "ветровка или толстовка"
                    elif $fmin <= 23 then "футболка, на вечер кофта"
                    else "лёгкая одежда, вода с собой" end)
          + " (ощущается от \($fmin | r)°)"
          + (if $uv >= 5 then "\n🧴 УФ-индекс \($uv | r) — крем от солнца" else "" end)
          + (if $sunset != "" then "\n🌇 Закат в \($sunset)" else "" end)
        end' 2>/dev/null
}

# ---- календарь: все календари Home Assistant (Remote Calendar по ссылке iCal, Google и т.п.) ----
cal_view() {   # сегодня и завтра
    t=$(cal_day 0); rc=$?
    [ "$rc" = 2 ] && { echo "Календарь не подключён: в Home Assistant нет календарей (см. docs/HOME-ASSISTANT.md, «Календарь»)."; return; }
    [ "$rc" = 0 ] || { echo "Home Assistant не подключён: нет /etc/tgbot.ha."; return; }
    m=$(cal_day 1)
    printf '📅 Сегодня\n%s\n\n📅 Завтра\n%s' "${t:-событий нет}" "${m:-событий нет}"
}
cal_day() {   # [смещение в днях: 0 сегодня, 1 завтра] -> строки «время  событие (календарь)», пусто — событий нет
    [ -r "$HAENV" ] || return 1; . "$HAENV"
    off=${1:-0}
    d0=$(( $(date -d "$(date +%Y-%m-%d) 00:00" +%s) + off * 86400 )); d1=$((d0 + 86400))
    st=$(date -u -d "@$d0" +%Y-%m-%dT%H:%M:%SZ); en=$(date -u -d "@$d1" +%Y-%m-%dT%H:%M:%SZ)
    cals=$(curl -s -m 10 -H "Authorization: Bearer $HA_TOKEN" "$HA_URL/api/calendars" 2>/dev/null | jq -r '.[]? | "\(.entity_id)\t\(.name)"' 2>/dev/null)
    [ -n "$cals" ] || return 2
    ncal=$(echo "$cals" | wc -l)
    echo "$cals" | while IFS="$(printf '\t')" read ent name; do
        curl -s -m 15 -H "Authorization: Bearer $HA_TOKEN" "$HA_URL/api/calendars/$ent?start=$st&end=$en" 2>/dev/null \
        | jq -r --arg n "$name" --argjson many "$([ "$ncal" -gt 1 ] && echo true || echo false)" '.[]? |
            (if .start.date then "0000\t" + "весь день" else
               ((.start.dateTime // "") | .[0:19]) as $s | ((.end.dateTime // "") | .[0:19]) as $e
               | "\($s[11:16] | split(":") | join(""))\t\($s[11:16])–\($e[11:16])" end)
            + "\t" + (.summary // "без названия") + (if $many then " (\($n))" else "" end)' 2>/dev/null
    done | sort -n | cut -f2- | awk -F'\t' '{print $1 "  " $2}'
}
morning_brief() {   # утренняя сводка: погода, дом, что было ночью, проблемы
    wth=$(day_weather)
    j=$(ha_states)
    if [ -n "$j" ]; then
        house=$(echo "$j" | jq -r "$HA_JQ"'
          "🏠 Дома: " + (rooms | join(", ")) + "\n" + heat
          + (batt | map(select(.v < thr)) | if length > 0 then "\n⚠️ Батарейки: " + (map("\(.n) \(.v)%") | join(", ")) else "" end)
          + (gone | if length > 0 then "\n📡 Не отвечают: " + join(", ") else "" end)' 2>/dev/null)
    fi
    # ночь: с 23:00 вчера
    since=$(( $(date -d "$(date +%Y-%m-%d) 00:00" +%s) - 3600 ))
    nl=$( { log_ha; log_router nopresence; } | awk -F'\t' -v c="$since" '$1 >= c')
    door=$(echo "$nl" | grep -c "Входная дверь открыта")
    ngt=""
    [ "$door" -gt 0 ] && ngt="входная дверь открывалась $door раз (последний — $(echo "$nl" | grep "Входная дверь открыта" | sort -n | tail -1 | cut -f1 | xargs -I{} date -d @{} +%H:%M))"
    wan=$(echo "$nl" | grep "Интернета не было" | sed 's/.*Интернета не было //'); [ -n "$wan" ] && ngt="${ngt:+$ngt; }интернет пропадал: $(echo "$wan" | tr '\n' ',' | sed 's/,$//')"
    nd=$(echo "$nl" | grep -c "Новое устройство"); [ "$nd" -gt 0 ] && ngt="${ngt:+$ngt; }новых устройств в сети: $nd"
    [ -n "$ngt" ] || ngt="спокойно"
    cal=$(cal_day 0); rc=$?
    if [ "$rc" = 0 ]; then
        [ -n "$cal" ] && cal="📅 Сегодня:
$cal" || cal="📅 Сегодня событий в календаре нет"
        house="$cal

${house:-🏠 Home Assistant не ответил.}"
    fi
    printf '☀️ Доброе утро!\n\n%s\n\n%s\n\n🌙 Ночью: %s' \
        "${wth:-🌤 Прогноз погоды недоступен.}" "${house:-🏠 Home Assistant не ответил.}" "$ngt"
}

# ---- графики температуры и влажности (PNG рисует /usr/bin/tgbot-chart.lua) ----
# Температура: по графику на комнату (Зал, Спальня, Туалет), на каждом три линии:
# 🔴 температура в комнате, 🟢 цель, 🟠 уставка на радиаторе; полоса внизу — радиатор греет.
# Датчик зала: ZAL_TEMP_SENSOR в /etc/tgbot.ha; пока не задан — берётся встроенный датчик радиатора.
graph_kb() {   # k dd
    printf '%s\n' "$([ "$1" = t ] && echo '• Температура' || echo 'Температура')	g:t$2	$([ "$1" = h ] && echo '• Влажность' || echo 'Влажность')	g:h$2" \
        "$([ "$2" = 1 ] && echo '• 24 часа' || echo '24 часа')	g:${1}1	$([ "$2" = 7 ] && echo '• 7 дней' || echo '7 дней')	g:${1}7" | json_kb
}

graph_photo() {   # файл подпись [разметка]
    if [ -n "$CHART_DRY" ]; then echo "$2"; echo; return; fi   # отладка: в чат не отправляется
    if [ -n "$3" ]; then
        curl -s -m 60 -F "chat_id=$CHAT_ID" -F "photo=@$1" -F "caption=$2" -F "reply_markup=$3" "$API/sendPhoto" >/dev/null 2>&1
    else
        curl -s -m 60 -F "chat_id=$CHAT_ID" -F "photo=@$1" -F "caption=$2" "$API/sendPhoto" >/dev/null 2>&1
    fi
}

graph_room() {   # название датчик climate t0 now tz kb
    n=$1; sens=$2; clim=$3; t0=$4; now=$5; tz=$6; kb=$7
    st=$(date -u -d "@$t0" +%Y-%m-%dT%H:%M:%SZ); en=$(date -u -d "@$now" +%Y-%m-%dT%H:%M:%SZ)
    dat=/tmp/tgbot.chart.txt; png=/tmp/tgbot.chart.png
    ents="sensor.tselevaia_temperatura,$clim"; [ -n "$sens" ] && ents="$ents,$sens"
    curl -s -m 40 -H "Authorization: Bearer $HA_TOKEN" \
        "$HA_URL/api/history/period/$st?end_time=$en&filter_entity_id=$ents&significant_changes_only=0" 2>/dev/null \
      | jq -r --arg s "$sens" --arg c "$clim" --argjson now "$now" '
        def ts: (.last_changed[0:19] + "Z") | fromdateiso8601;
        .[]? | (.[0].entity_id // "") as $e
        | def vals:
            if $s != "" and $e == $s then [[1, (.state | tonumber?)]]
            elif $e == "sensor.tselevaia_temperatura" then [[3, (.state | tonumber?)]]
            elif $e == $c then [[4, .attributes.temperature]] + (if $s == "" then [[1, .attributes.current_temperature]] else [] end)
            else [] end;
          ( (.[] | select(.state != null) | . as $p | ($p | vals[]) | select(.[1] != null) | "s \(.[0]) \($p | ts) \(.[1])"),
            (if $e == $c then
               [.[] | {t: ts, s: .state}] as $a
               | range(0; $a | length) as $i | select($a[$i].s == "heat" or $a[$i].s == "heat_cool")
               | "b \($a[$i].t) \($a[$i + 1].t // $now)"
             else empty end) )' > "$dat" 2>/dev/null
    if ! grep -q '^s ' "$dat" || ! lua /usr/bin/tgbot-chart.lua "$png" "$t0" "$now" "$tz" < "$dat" 2>/dev/null; then
        rm -f "$dat" "$png"; return 1
    fi
    rng=$(awk '$1=="s" {s=$2; v=$4; if (!(s in mn) || v<mn[s]) mn[s]=v; if (!(s in mx) || v>mx[s]) mx[s]=v}
        END {for (s in mn) printf "%s %s %s\n", s, mn[s], mx[s]}' "$dat" | sort -n)
    leg=$(echo "$rng" | while read s a b; do
        case "$s" in (1) l="🔴 Температура в комнате";; (3) l="🟢 Цель";; (4) l="🟠 Уставка на радиаторе";; (*) l="";; esac
        [ -n "$l" ] && echo "$l: $a–$b°"
    done)
    [ "$dd" = 1 ] && per="24 часа" || per="$dd дней"
    cap=$(printf '🌡 %s за %s\n%s' "$n" "$per" "$leg")
    [ -z "$sens" ] && cap=$(printf '%s\nℹ️ Датчика комнаты нет: температура — встроенный датчик радиатора (он у горячего корпуса, завышает).' "$cap")
    grep -q '^b ' "$dat" && cap=$(printf '%s\n🟧 полоса внизу — радиатор греет' "$cap")
    graph_photo "$png" "$cap" "$kb"
    rm -f "$dat" "$png"
}

graph_send() {   # t|h (температура|влажность) 1|7 (дней)
    k=${1:-t}; dd=${2:-1}
    [ -r "$HAENV" ] || { send "Home Assistant не подключён: нет /etc/tgbot.ha."; return; }
    . "$HAENV"
    now=$(date +%s); t0=$((now - dd * 86400))
    tz=$(date +%z | awk '{s=substr($0,1,1); h=substr($0,2,2); m=substr($0,4,2); print (s=="-"?-1:1)*(h*3600+m*60)}')
    kb=$(graph_kb "$k" "$dd")
    if [ "$k" = t ]; then
        rooms="Зал|${ZAL_TEMP_SENSOR:-sensor.spalnia_temperatura_temperature}|climate.zal_levyi
Спальня|sensor.temperatura_temperature|climate.spalnia_radiator
Туалет|sensor.tualet_temp_temperature|climate.tualet_radiator"
        got=0; cnt=$(echo "$rooms" | wc -l); i=0
        echo "$rooms" | while IFS='|' read n sens clim; do
            i=$((i + 1)); m=""; [ "$i" -eq "$cnt" ] && m=$kb
            graph_room "$n" "$sens" "$clim" "$t0" "$now" "$tz" "$m" || echo "x" >> /tmp/tgbot.chart.fail
        done
        if [ -f /tmp/tgbot.chart.fail ] && [ "$(wc -l < /tmp/tgbot.chart.fail)" -ge "$cnt" ]; then
            send "Нет данных для графика (Home Assistant не ответил или история пуста)."
        fi
        rm -f /tmp/tgbot.chart.fail
        return
    fi
    st=$(date -u -d "@$t0" +%Y-%m-%dT%H:%M:%SZ); en=$(date -u -d "@$now" +%Y-%m-%dT%H:%M:%SZ)
    dat=/tmp/tgbot.chart.txt; png=/tmp/tgbot.chart.png
    curl -s -m 40 -H "Authorization: Bearer $HA_TOKEN" \
        "$HA_URL/api/history/period/$st?end_time=$en&filter_entity_id=sensor.temperatura_humidity,sensor.tualet_temp_humidity,sensor.spalnia_temperatura_humidity&significant_changes_only=0" 2>/dev/null \
      | jq -r '
        def ts: (.last_changed[0:19] + "Z") | fromdateiso8601;
        .[]? | (.[0].entity_id // "") as $e
        | .[] | select(.state != null) | . as $p
        | (if $e == "sensor.temperatura_humidity" then [1, (.state | tonumber?)]
           elif $e == "sensor.tualet_temp_humidity" then [2, (.state | tonumber?)]
           elif $e == "sensor.spalnia_temperatura_humidity" then [3, (.state | tonumber?)] else empty end) as $v
        | select($v[1] != null) | "s \($v[0]) \($p | ts) \($v[1])"' > "$dat" 2>/dev/null
    if ! grep -q '^s ' "$dat" || ! lua /usr/bin/tgbot-chart.lua "$png" "$t0" "$now" "$tz" < "$dat" 2>/dev/null; then
        rm -f "$dat" "$png"; send "Нет данных для графика (Home Assistant не ответил или история пуста)."; return
    fi
    rng=$(awk '$1=="s" {s=$2; v=$4; if (!(s in mn) || v<mn[s]) mn[s]=v; if (!(s in mx) || v>mx[s]) mx[s]=v}
        END {for (s in mn) printf "%s %s %s\n", s, mn[s], mx[s]}' "$dat" | sort -n)
    leg=$(echo "$rng" | while read s a b; do
        case "$s" in (1) l="🔴 Спальня";; (2) l="🔵 Туалет";; (3) l="🟢 Зал";; (*) l="";; esac
        [ -n "$l" ] && echo "$l: $a–$b%"
    done)
    [ "$dd" = 1 ] && per="24 часа" || per="$dd дней"
    cap=$(printf '💧 Влажность за %s\n%s\nНорма 40–60%%. Выше 65%% — риск плесени, ниже 35%% — сухо.' "$per" "$leg")
    graph_photo "$png" "$cap" "$kb"
    rm -f "$dat" "$png"
}
