-- Линейный график в PNG без внешних библиотек (палитра, zlib «хранимыми» блоками).
-- Использование: lua tgbot-chart.lua out.png t0 t1 tz_offset_sec [единица] < данные
-- Данные (по строке):  s <серия 1..5> <epoch> <значение>   — точка серии («-» вместо значения — разрыв линии)
--                      b <epoch_начала> <epoch_конца>        — полоса «грело» внизу графика
-- Цвета серий: 1 красный, 2 синий, 3 зелёный, 4 оранжевый, 5 фиолетовый.
local bit = require "bit"
local out, t0, t1, tz = arg[1], tonumber(arg[2]), tonumber(arg[3]), tonumber(arg[4]) or 0
local W, H = 720, 400
local L, R, T, B = 52, 14, 14, 34
local PW, PH = W - L - R, H - T - B

local pal = { [0] = {255,255,255}, {226,229,234}, {90,96,108}, {220,50,47}, {38,110,210}, {40,160,70}, {240,140,20}, {150,80,200}, {253,226,190} }
local img = {}
for i = 1, W * H do img[i] = 0 end
local function px(x, y, c)
    x, y = math.floor(x + 0.5), math.floor(y + 0.5)
    if x >= 0 and x < W and y >= 0 and y < H then img[y * W + x + 1] = c end
end
local function rect(x0, y0, x1, y1, c)
    for y = math.floor(y0), math.floor(y1) do for x = math.floor(x0), math.floor(x1) do px(x, y, c) end end
end
local function line(x0, y0, x1, y1, c, th)
    local dx, dy = x1 - x0, y1 - y0
    local n = math.max(math.abs(dx), math.abs(dy), 1)
    for i = 0, n do
        local x, y = x0 + dx * i / n, y0 + dy * i / n
        if th and th > 1 then rect(x - 1, y - 1, x, y, c) else px(x, y, c) end
    end
end

-- шрифт 3x5: цифры и знаки
local F = {
    ["0"]="111101101101111", ["1"]="010110010010111", ["2"]="111001111100111", ["3"]="111001111001111",
    ["4"]="101101111001001", ["5"]="111100111001111", ["6"]="111100111101111", ["7"]="111001010010010",
    ["8"]="111101111101111", ["9"]="111101111001111", ["-"]="000000111000000", ["."]="000000000000010",
    [":"]="000010000010000", ["%"]="101001010100101", ["°"]="010101010000000", [" "]="000000000000000" }
local function text(s, x, y, c, sc)
    sc = sc or 2
    for ch in s:gmatch(utf8 and utf8.charpattern or "[%z\1-\127\194-\244][\128-\191]*") do
        local g = F[ch]
        if g then
            for r = 0, 4 do for k = 0, 2 do
                if g:sub(r * 3 + k + 1, r * 3 + k + 1) == "1" then rect(x + k * sc, y + r * sc, x + k * sc + sc - 1, y + r * sc + sc - 1, c) end
            end end
        end
        x = x + 4 * sc
    end
end
local function twidth(s, sc) local n = 0; for _ in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do n = n + 1 end; return n * 4 * (sc or 2) end

-- данные
local ser, bands = {}, {}
local vmin, vmax
for l in io.lines() do
    local a, b, c, d = l:match("^(%a)%s+(%S+)%s+(%S+)%s*(%S*)")
    if a == "s" then
        local s, t, v = tonumber(b), tonumber(c), tonumber(d)
        if s and t and (v or d == "-") then
            ser[s] = ser[s] or {}
            table.insert(ser[s], { t, v or false })
            if v then vmin = (vmin and math.min(vmin, v)) or v; vmax = (vmax and math.max(vmax, v)) or v end
        end
    elseif a == "b" then
        local s, e = tonumber(b), tonumber(c)
        if s and e then table.insert(bands, { s, e }) end
    end
end
if not vmin then io.stderr:write("нет данных\n") os.exit(1) end
if vmax - vmin < 2 then local m = (vmax + vmin) / 2; vmin, vmax = m - 1, m + 1 end
local steps = { 0.5, 1, 2, 5, 10, 20 }
local step = 20
for _, s in ipairs(steps) do if (vmax - vmin) / s <= 7 then step = s; break end end
vmin = math.floor(vmin / step) * step; vmax = math.ceil(vmax / step) * step
local function X(t) return L + (t - t0) / (t1 - t0) * PW end
local function Y(v) return T + PH - (v - vmin) / (vmax - vmin) * PH end

-- сетка и подписи
local v = vmin
while v <= vmax + 1e-9 do
    local y = Y(v)
    line(L, y, L + PW, y, 1)
    local s = (step < 1) and string.format("%.1f", v) or string.format("%d", math.floor(v + 0.5))
    text(s, L - 6 - twidth(s), y - 5, 2)
    v = v + step
end
local span = t1 - t0
local hstep = (span <= 2 * 86400) and 6 * 3600 or 86400
local first = math.ceil((t0 + tz) / hstep) * hstep - tz
for t = first, t1, hstep do
    local x = X(t)
    line(x, T, x, T + PH, 1)
    local s = (hstep < 86400) and os.date("!%H", t + tz) or os.date("!%d.%m", t + tz)
    text(s, x - twidth(s) / 2, T + PH + 8, 2)
end
-- полоса «грело»
for _, b in ipairs(bands) do
    local x0, x1 = X(math.max(b[1], t0)), X(math.min(b[2], t1))
    if x1 > x0 then rect(x0, T + PH - 7, x1, T + PH - 1, 8) end
end
line(L, T, L, T + PH, 2); line(L, T + PH, L + PW, T + PH, 2)

-- серии: ступеньки (значение держится до следующего изменения)
for s, pts in pairs(ser) do
    table.sort(pts, function(a, b) return a[1] < b[1] end)
    local c = 2 + s
    for i = 1, #pts do
        local ta = math.max(pts[i][1], t0)
        local tb = (pts[i + 1] and pts[i + 1][1]) or t1
        if tb > t0 and pts[i][2] then
            local y = Y(pts[i][2])
            line(X(ta), y, X(tb), y, c, 2)
            if pts[i + 1] and pts[i + 1][2] then line(X(tb), y, X(tb), Y(pts[i + 1][2]), c, 2) end
        end
    end
end

-- PNG: палитра, 8 бит на пиксель
local rows = {}
for y = 0, H - 1 do
    local r = { "\0" }
    for x = 1, W do r[#r + 1] = string.char(img[y * W + x]) end
    rows[#rows + 1] = table.concat(r)
end
local data = table.concat(rows)
local crct = {}
for i = 0, 255 do
    local c = i
    for _ = 1, 8 do
        if bit.band(c, 1) == 1 then c = bit.bxor(bit.rshift(c, 1), 0xEDB88320) else c = bit.rshift(c, 1) end
    end
    crct[i] = c
end
local function crc32(s)
    local c = -1
    for i = 1, #s do c = bit.bxor(crct[bit.band(bit.bxor(c, s:byte(i)), 0xFF)], bit.rshift(c, 8)) end
    return bit.bnot(c)
end
local function adler32(s)
    local a, b = 1, 0
    for i = 1, #s do a = (a + s:byte(i)) % 65521; b = (b + a) % 65521 end
    return b * 65536 + a
end
local function u32(v)
    return string.char(bit.band(bit.rshift(v, 24), 255), bit.band(bit.rshift(v, 16), 255), bit.band(bit.rshift(v, 8), 255), bit.band(v, 255))
end
local function chunk(typ, body) return u32(#body) .. typ .. body .. u32(crc32(typ .. body)) end
local z, pos, len = { "\120\1" }, 1, #data
while pos <= len do
    local size = math.min(65535, len - pos + 1)
    local final = (pos + size > len) and 1 or 0
    z[#z + 1] = string.char(final, size % 256, math.floor(size / 256), (65535 - size) % 256, math.floor((65535 - size) / 256))
    z[#z + 1] = data:sub(pos, pos + size - 1)
    pos = pos + size
end
z[#z + 1] = u32(adler32(data))
local plte = {}
for i = 0, 8 do plte[#plte + 1] = string.char(pal[i][1], pal[i][2], pal[i][3]) end
local f = assert(io.open(out, "wb"))
f:write("\137PNG\13\10\26\10" .. chunk("IHDR", u32(W) .. u32(H) .. "\8\3\0\0\0") .. chunk("PLTE", table.concat(plte))
    .. chunk("IDAT", table.concat(z)) .. chunk("IEND", ""))
f:close()
