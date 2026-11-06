-- Проверка портов и TCP-доступности.
--   lua tgbot-scan.lua <ip>               список открытых «интересных» портов
--   lua tgbot-scan.lua --tcp <host> <port> код выхода 0, если порт открыт
local socket = require "socket"

local function try(host, port, timeout)
    local c = socket.tcp()
    c:settimeout(timeout)
    local ok = c:connect(host, port)
    c:close()
    return ok ~= nil
end

if arg[1] == "--tcp" then
    os.exit(try(arg[2], tonumber(arg[3]), 5) and 0 or 1)
end

local host = arg[1]
if not host then print("нужен IP") os.exit(2) end

-- {порт, описание, опасный?}
local ports = {
    {21, "FTP", true},
    {22, "SSH"},
    {23, "TELNET", true},
    {80, "HTTP (веб-интерфейс)"},
    {443, "HTTPS"},
    {445, "SMB (файлы)"},
    {554, "RTSP (видеопоток камеры)", true},
    {1883, "MQTT"},
    {2323, "TELNET (альтернативный)", true},
    {3389, "RDP (удалённый рабочий стол)", true},
    {5555, "ADB (отладка Android)", true},
    {7547, "TR-069 (удалённое управление)", true},
    {8000, "HTTP (альтернативный)"},
    {8080, "HTTP (альтернативный)"},
    {8443, "HTTPS (альтернативный)"},
    {8554, "RTSP (альтернативный)", true},
    {9100, "печать (RAW)"},
    {34567, "DVR/камера", true},
    {37777, "камера Dahua", true},
}

local found, risky = {}, {}
for _, p in ipairs(ports) do
    if try(host, p[1], 0.4) then
        local line = string.format("  %d: %s%s", p[1], p[2], p[3] and "  [!]" or "")
        found[#found + 1] = line
        if p[3] then risky[#risky + 1] = tostring(p[1]) end
    end
end

if #found == 0 then
    print("Открытых популярных портов не найдено.")
else
    print("Открытые порты:")
    print(table.concat(found, "\n"))
    if #risky > 0 then
        print("Внимание: потенциально небезопасно: " .. table.concat(risky, ", ")
              .. ". Если это камера или «умное» устройство, смените пароль и закройте ему выход в интернет.")
    end
end
