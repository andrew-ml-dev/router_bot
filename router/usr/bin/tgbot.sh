#!/bin/sh
# Периодические проверки бота (cron, раз в минуту):
# загрузка, новые устройства (+проверка портов), перебор SSH, VPN-события, пропажа интернета,
# слежение за устройствами и сайтами, аномалии DNS, железо, история скорости, бэкап, отчёты
. /usr/lib/tgbot-lib.sh
KNOWN=/etc/tgbot.known          # известные MAC (переживает перезагрузку)
BOOTFLAG=/tmp/tgbot.booted
SSHCNT=/tmp/tgbot.sshcnt
LOCK=/tmp/tgbot.lock

if [ -d "$LOCK" ]; then
    [ -n "$(find "$LOCK" -mmin +3 2>/dev/null)" ] && rmdir "$LOCK" 2>/dev/null
    [ -d "$LOCK" ] && exit 0
fi
mkdir "$LOCK" 2>/dev/null || exit 0
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

# ---- сторож: если задан HC_URL (healthchecks.io), раз в минуту сообщаем, что роутер жив ----
[ -n "$HC_URL" ] && curl -s -m 10 -o /dev/null "$HC_URL" 2>/dev/null

# ---- недоставленные уведомления ----
flush_outbox

# ---- загрузка ----
if [ ! -e "$BOOTFLAG" ]; then
    if send "$(printf 'Роутер загрузился\n\n%s' "$(status)")"; then
        touch "$BOOTFLAG"
    fi
fi

# ---- новые устройства ----
connection() {
    m=$1
    for pair in "ra0:2.4 ГГц" "rax0:5 ГГц" "ra1:гостевая 2.4 ГГц" "rax1:гостевая 5 ГГц"; do
        i=${pair%%:*}; band=${pair#*:}
        line=$(iwinfo "$i" assoclist 2>/dev/null | grep -i "^$m ")
        if [ -n "$line" ]; then
            ssid=$(iwinfo "$i" info 2>/dev/null | sed -n 's/.*ESSID: "\(.*\)"/\1/p')
            sig=$(echo "$line" | awk '{print $2, $3}')
            echo "Wi-Fi $band ($ssid), сигнал $sig"
            return
        fi
    done
    echo "кабель или не определено"
}

vendor() {
    oui=$(echo "$1" | cut -c1-8)
    f=$(echo "$1" | cut -c2)
    case "$f" in 2|6|a|A|e|E) echo "приватный (случайный) MAC, производитель не определяется"; return ;; esac
    v=$(curl -s -m 8 "https://api.macvendors.com/$oui" 2>/dev/null)
    case "$v" in ""|*errors*|*Too*) echo "неизвестно" ;; *) echo "$v" ;; esac
}

[ -e "$KNOWN" ] || { first_run=1; touch "$KNOWN"; }
awk 'NR>1 && $3=="0x2" && $6=="br-lan" {print tolower($4), $1}' /proc/net/arp | while read mac ip; do
    grep -qi "^$mac\$" "$KNOWN" && continue
    if [ -n "$first_run" ]; then echo "$mac" >> "$KNOWN"; continue; fi
    if true; then
        send_kb "$(printf 'Новое устройство в сети\nИмя: %s\nПроизводитель: %s\nПодключение: %s\nIP: %s\nMAC: %s\n\n%s' \
            "$(devname "$mac")" "$(vendor "$mac")" "$(connection "$mac")" "$ip" "$mac" "$(lua /usr/bin/tgbot-scan.lua "$ip")")" \
            "{\"inline_keyboard\":[[{\"text\":\"Знаю\",\"callback_data\":\"allow:$mac\"},{\"text\":\"Заблокировать\",\"callback_data\":\"block:$mac\"}]]}" \
            && { echo "$mac" >> "$KNOWN"; log_event new "$(devname "$mac") ($mac)"; }
        sleep 1
    fi
done

# ---- перебор паролей SSH ----
cnt=$(logread 2>/dev/null | grep -c 'Bad password attempt\|Login attempt for nonexistent user')
last=$(cat "$SSHCNT" 2>/dev/null || echo "$cnt")
echo "$cnt" > "$SSHCNT"
[ "$cnt" -ge "$((last + 3))" ] && qsend "Неудачные попытки входа по SSH: +$((cnt - last)) за минуту"

# ---- VPN: подключился / отключился ----
now=$(date +%s)
for sec in $(uci -q show wireguard_server | grep -o 'peer_[0-9]*=peers' | cut -d= -f1); do
    name=$(uci -q get wireguard_server.$sec.name)
    pub=$(uci -q get wireguard_server.$sec.public_key)
    hs=$(wg show wgserver latest-handshakes 2>/dev/null | grep "^$pub" | cut -f2)
    online=0
    [ -n "$hs" ] && [ "$hs" != "0" ] && [ $((now - hs)) -lt 240 ] && online=1
    sf=/tmp/tgbot.vpn.$sec
    prev=$(cat "$sf" 2>/dev/null)
    if [ -z "$prev" ]; then
        echo "$online" > "$sf"
    elif [ "$prev" != "$online" ]; then
        ep=$(wg show wgserver endpoints 2>/dev/null | grep "^$pub" | cut -f2 | sed 's/:[0-9]*$//')
        if [ "$online" = "1" ]; then
            send "VPN: $name подключился (с адреса ${ep:-?})" && echo "$online" > "$sf"
        else
            send "VPN: $name отключился" && echo "$online" > "$sf"
        fi
    fi
done

# ---- интернет: пропал / вернулся ----
DOWN=/tmp/tgbot.wandown
if ping -c1 -W3 1.1.1.1 >/dev/null 2>&1 || ping -c1 -W3 8.8.8.8 >/dev/null 2>&1; then
    if [ -e "$DOWN" ]; then
        since=$(cat "$DOWN"); mins=$(( (now - since) / 60 ))
        if [ "$mins" -ge 2 ]; then
            send "Интернет вернулся. Не было связи примерно $mins мин." && rm -f "$DOWN" && log_event wan "$mins"
        else
            rm -f "$DOWN"
        fi
    fi
else
    [ -e "$DOWN" ] || echo "$now" > "$DOWN"
fi

# ---- контроль железа (не чаще раза в час на каждую проблему) ----
hw_alert() {   # $1 = ключ, $2 = текст
    f=/tmp/tgbot.hw.$1
    if [ -z "$(find "$f" -mmin -60 2>/dev/null)" ]; then
        send "$2" && touch "$f"
    fi
}
TEMP_MAX=75       # °C
MEM_MIN_MB=80     # свободной памяти
DISK_MAX=90       # % занятости
t=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null)
[ -n "$t" ] && [ $((t / 1000)) -ge $TEMP_MAX ] && hw_alert temp "Перегрев: процессор $((t / 1000)) °C"
mavail=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo)
[ -n "$mavail" ] && [ "$mavail" -lt "$MEM_MIN_MB" ] && hw_alert mem "Мало памяти: доступно $mavail МБ"
disk=$(df /overlay 2>/dev/null | awk 'NR==2 {gsub("%","",$5); print $5}')
[ -n "$disk" ] && [ "$disk" -ge "$DISK_MAX" ] && hw_alert disk "Заканчивается место на роутере: занято $disk%"

# ---- аномалии в DNS (каждые 10 минут, по журналу AdGuard) ----
QMAX_DAY=500      # запросов с одного устройства за 10 мин (днём)
QMAX_NIGHT=200    # то же ночью (01:00–06:00)
BLOCKED_MAX=150   # заблокированных запросов с одного устройства за 10 мин
mm=$(date +%M); mm=${mm#0}; [ -z "$mm" ] && mm=0
if [ $(( mm % 10 )) -eq 0 ] && [ -s "$QLOG" ]; then
    cutoff=$(date -u -d "@$(( now - 600 ))" +%Y-%m-%dT%H:%M 2>/dev/null)
    jq -c --arg c "$cutoff" 'select(.T > $c)' "$QLOG" 2>/dev/null > /tmp/tgbot.q10
    hour=$(date +%H); hour=${hour#0}; [ -z "$hour" ] && hour=0; lim=$QMAX_DAY
    [ "$hour" -ge 1 ] && [ "$hour" -lt 6 ] && lim=$QMAX_NIGHT
    jq -r '.IP' /tmp/tgbot.q10 2>/dev/null | sort | uniq -c | while read c ip; do
        [ -n "$ip" ] && [ "$c" -ge "$lim" ] || continue
        f=/tmp/tgbot.an.$ip
        [ -n "$(find "$f" -mmin -60 2>/dev/null)" ] && continue
        top=$(jq -r --arg ip "$ip" 'select(.IP==$ip) | .QH' /tmp/tgbot.q10 | sort | uniq -c | sort -rn | head -3 | awk '{print "  "$2" ("$1")"}')
        send "$(printf 'Всплеск DNS-запросов\nУстройство: %s (%s)\nЗапросов за 10 мин: %s (порог %s)\nЧаще всего:\n%s' "$(ipname "$ip")" "$ip" "$c" "$lim" "$top")" && touch "$f"
    done
    jq -r 'select(.Result.IsFiltered==true) | .IP' /tmp/tgbot.q10 2>/dev/null | sort | uniq -c | while read c ip; do
        [ -n "$ip" ] && [ "$c" -ge "$BLOCKED_MAX" ] || continue
        f=/tmp/tgbot.anb.$ip
        [ -n "$(find "$f" -mmin -60 2>/dev/null)" ] && continue
        top=$(jq -r --arg ip "$ip" 'select(.IP==$ip and .Result.IsFiltered==true) | .QH' /tmp/tgbot.q10 | sort | uniq -c | sort -rn | head -3 | awk '{print "  "$2" ("$1")"}')
        send "$(printf 'Много заблокированных запросов\nУстройство: %s (%s)\nЗаблокировано за 10 мин: %s\nЧаще всего:\n%s' "$(ipname "$ip")" "$ip" "$c" "$top")" && touch "$f"
    done
    rm -f /tmp/tgbot.q10
fi

# ---- слежение: люди дома, «живые» устройства, сайты ----
watch_tick
house_tick
pause_tick
[ $(( mm % 2 )) -eq 0 ] && sites_tick

# ---- ночные и еженедельные задачи ----
stamp=$(date +%u%H%M)
today=$(date +%Y%m%d)
run_once() {   # ключ команда...: не чаще раза в сутки
    k=$1; shift
    [ "$(cat "/tmp/tgbot.once.$k" 2>/dev/null)" = "$today" ] && return
    echo "$today" > "/tmp/tgbot.once.$k"
    "$@"
}
night_job() { traffic_snap; speed_daily; }
backup_job() { r=$(do_backup) || send "Еженедельный бэкап не удался: $r"; }
digest_job() { qsend "$(digest)"; }
case "$(date +%H%M)" in 0400) run_once night night_job ;; esac
case "$stamp" in 70300) run_once backup backup_job ;; 10910) run_once digest digest_job ;; esac

# ---- утренний отчёт 09:00 ----
if [ "$(date +%H%M)" = "0900" ] && [ "$(cat /tmp/tgbot.reportday 2>/dev/null)" != "$(date +%Y%m%d)" ]; then
    send "$(printf 'Доброе утро!\n\n%s\n\n%s' "$(status)" "$(vpn)")" && date +%Y%m%d > /tmp/tgbot.reportday
fi
exit 0
