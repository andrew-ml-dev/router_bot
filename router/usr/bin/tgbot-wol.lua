-- Wake-on-LAN: lua tgbot-wol.lua AA:BB:CC:DD:EE:FF
local socket = require "socket"
local mac = (arg[1] or ""):gsub("[:%-]", "")
if #mac ~= 12 then print("Неверный MAC: " .. (arg[1] or "")) os.exit(1) end
local b = {}
for i = 1, 12, 2 do b[#b + 1] = string.char(tonumber(mac:sub(i, i + 1), 16)) end
local packet = string.rep("\255", 6) .. string.rep(table.concat(b), 16)
local u = socket.udp()
u:setoption("broadcast", true)
u:sendto(packet, "192.168.8.255", 9)
u:sendto(packet, "255.255.255.255", 9)
u:close()
