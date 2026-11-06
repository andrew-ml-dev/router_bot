-- QR-код в PNG без внешних библиотек.
-- Использование:  qrencode -t ASCII -m 0 -l M -o - < текст | lua tgbot-png.lua out.png [масштаб]
-- (штатный qrencode на GL.iNet собран без поддержки PNG, поэтому PNG строится здесь)
local bit = require "bit"
local out = arg[1] or "qr.png"
local scale = tonumber(arg[2]) or 7
local quiet = 4

-- читаем матрицу: каждый модуль = 2 символа ("##" тёмный, "  " светлый), 1 строка
local rows = {}
for line in io.lines() do
    if #line > 0 then rows[#rows + 1] = line end
end
local n = #rows
if n == 0 then io.stderr:write("пустой ввод\n") os.exit(1) end

local function dark(y, x) -- x, y с нуля в модулях
    local r = rows[y + 1]
    if not r then return false end
    return r:sub(2 * x + 1, 2 * x + 1) == "#"
end

local mods = n + 2 * quiet
local W = mods * scale
local H = W

-- построчная упаковка 1 бит/пиксель (1 = белый, 0 = чёрный)
local rowbytes = math.ceil(W / 8)
local raw = {}
for my = 0, mods - 1 do
    local px = {}
    for mx = 0, mods - 1 do
        local d = false
        local qy, qx = my - quiet, mx - quiet
        if qy >= 0 and qy < n and qx >= 0 and qx < n then d = dark(qy, qx) end
        for _ = 1, scale do px[#px + 1] = d and 0 or 1 end
    end
    -- упаковать
    local bytes = {}
    for i = 0, rowbytes - 1 do
        local v = 0
        for b = 0, 7 do
            local p = px[i * 8 + b + 1]
            if p == nil then p = 1 end
            v = v * 2 + p
        end
        bytes[#bytes + 1] = string.char(v)
    end
    local line = "\0" .. table.concat(bytes) -- фильтр 0
    for _ = 1, scale do raw[#raw + 1] = line end
end
local data = table.concat(raw)

-- CRC32 и Adler32
local crct = {}
for i = 0, 255 do
    local c = i
    for _ = 1, 8 do
        if bit.band(c, 1) == 1 then c = bit.bxor(bit.rshift(c, 1), 0xEDB88320)
        else c = bit.rshift(c, 1) end
    end
    crct[i] = c
end
local function crc32(s)
    local c = -1
    for i = 1, #s do
        c = bit.bxor(crct[bit.band(bit.bxor(c, s:byte(i)), 0xFF)], bit.rshift(c, 8))
    end
    return bit.bnot(c)
end
local function adler32(s)
    local a, b = 1, 0
    for i = 1, #s do
        a = (a + s:byte(i)) % 65521
        b = (b + a) % 65521
    end
    return b * 65536 + a
end
local function u32(v)
    return string.char(bit.band(bit.rshift(v, 24), 255), bit.band(bit.rshift(v, 16), 255),
                       bit.band(bit.rshift(v, 8), 255), bit.band(v, 255))
end
local function chunk(typ, body)
    return u32(#body) .. typ .. body .. u32(crc32(typ .. body))
end

-- zlib: «хранимые» блоки без сжатия
local z = {"\120\1"}
local pos, len = 1, #data
while pos <= len do
    local size = math.min(65535, len - pos + 1)
    local final = (pos + size > len) and 1 or 0
    z[#z + 1] = string.char(final, size % 256, math.floor(size / 256),
                            (65535 - size) % 256, math.floor((65535 - size) / 256))
    z[#z + 1] = data:sub(pos, pos + size - 1)
    pos = pos + size
end
z[#z + 1] = u32(adler32(data))

local png = "\137PNG\13\10\26\10"
    .. chunk("IHDR", u32(W) .. u32(H) .. "\1\0\0\0\0")
    .. chunk("IDAT", table.concat(z))
    .. chunk("IEND", "")

local f = assert(io.open(out, "wb"))
f:write(png)
f:close()
