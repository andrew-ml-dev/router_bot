# Настройка роутера (Flint 2 / GL.iNet 4.x)

Заметки о том, как настроен роутер вокруг бота. Всё делалось по SSH, без сторонних пакетов.
Перед правкой конфигов делайте бэкап (`cp файл файл.bak`).

## Админка на стандартных портах

Порты админки GL.iNet (nginx) хранятся прямо в `/etc/nginx/conf.d/gl.conf`
(`listen 8888;` для HTTP и `listen 9443 ssl;` для HTTPS на изменённых портах).
Вернуть стандартные:

```sh
cp /etc/nginx/conf.d/gl.conf /etc/nginx/conf.d/gl.conf.bak
sed -i 's/listen 8888;/listen 80;/; s/listen \[::\]:8888;/listen [::]:80;/; s/listen 9443 ssl;/listen 443 ssl;/; s/listen \[::\]:9443 ssl;/listen [::]:443 ssl;/' /etc/nginx/conf.d/gl.conf
nginx -t && nginx -s reload
```

Чтобы быстро узнать, на каком порту админка: `netstat -lntp | grep nginx`.
LuCI (uhttpd) отдельно: `uci show uhttpd | grep listen` (по умолчанию 8083/8443).
Обновление прошивки может вернуть порты.

## AdGuard Home

AdGuard Home входит в прошивку, но выключен по умолчанию.

```sh
uci set adguardhome.config.enabled=1; uci commit adguardhome
/etc/init.d/adguardhome enable
/etc/init.d/adguardhome restart
```

DNS-схема: устройства → dnsmasq (порт 53) → AdGuard Home (порт 3053) → upstream. Интерфейс AdGuard: `http://<роутер>:3000`.
Рекомендуемые настройки в `/etc/AdGuardHome/config.yaml`:

- `upstream_dns`: шифрованные DoH, например `https://dns.quad9.net/dns-query` и `https://cloudflare-dns.com/dns-query`;
- `enable_dnssec: true`;
- блок-листы: AdGuard DNS filter и OISD small (`https://small.oisd.nl/`);
- журнал запросов: см. [INSTALL.md](INSTALL.md), раздел 5.

Ограничения DNS-блокировки: реклама YouTube и внутри приложений так не убирается; приложения с собственным DoH
(Chrome, Firefox) могут обходить DNS роутера.

## WireGuard-сервер

Настраивается в админке (VPN → WireGuard Server). Для доступа «из любого места» достаточно статического IP
или DDNS и проброса UDP-порта (на роутере порт открывается автоматически правилом `wgserver_allow`).

В DNS пиров указывайте только адрес роутера (`10.0.0.1`), без сторонних DNS, иначе запросы клиента могут идти мимо AdGuard.
Пир с `AllowedIPs = 0.0.0.0/0` пускает весь трафик через дом, пир с `10.0.0.0/24` только трафик к домашней сети.

Добавление пира вручную (пример, ключи генерируйте на роутере, не публикуйте их):

```sh
PRIV=$(wg genkey); PUB=$(echo "$PRIV" | wg pubkey)
uci set wireguard_server.peer_7001=peers
uci set wireguard_server.peer_7001.name='me-full'
uci set wireguard_server.peer_7001.peer_id='7001'
uci set wireguard_server.peer_7001.presharedkey_enable='0'
uci set wireguard_server.peer_7001.allowed_ips='0.0.0.0/0,::/0'
uci set wireguard_server.peer_7001.mtu='1420'
uci set wireguard_server.peer_7001.persistent_keepalive='25'
uci set wireguard_server.peer_7001.public_key="$PUB"
uci set wireguard_server.peer_7001.private_key="$PRIV"
uci set wireguard_server.peer_7001.client_ip='10.0.0.4/24,fd00:db8:0:abc::4/64'
uci set wireguard_server.peer_7001.deprecated='0'
uci set wireguard_server.peer_7001.dns='10.0.0.1,fd00:db8:0:abc::1'
uci commit wireguard_server
wg set wgserver peer "$PUB" allowed-ips 10.0.0.4/32     # применить без перезапуска
```

Клиентский конфиг и QR-код содержат приватный ключ: не отправляйте их в мессенджеры, после настройки удалите.

## Проверка, что роутер не виден из интернета

В зоне `wan` политика `input = DROP`; снаружи разрешены только служебные пакеты и порт WireGuard.
Проверить:

```sh
uci show firewall | grep -E "@zone\[1\]|src='wan'"      # зона wan и правила для неё
iptables -S zone_wan_input                               # живые правила
netstat -lntup                                           # что слушает на роутере
uci show upnpd | grep enabled                            # UPnP должен быть выключен (enabled='0')
```

Служба может слушать на внешнем адресе (например, dnsmasq на порту 53), но недоступна из интернета,
пока политика `wan` = `DROP`.

## Доступ по SSH только по ключу (по желанию)

```sh
uci set dropbear.@dropbear[0].PasswordAuth='off'
uci set dropbear.@dropbear[0].RootPasswordAuth='off'
uci commit dropbear && /etc/init.d/dropbear restart
```

Сначала убедитесь, что вход по ключу работает, иначе потеряете доступ по SSH.
Этот пункт не проверялся на конкретной прошивке GL.iNet; параметры стандартные для OpenWrt (dropbear).
