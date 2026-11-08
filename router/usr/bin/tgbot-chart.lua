-- График в PNG без внешних библиотек: палитра до 256 цветов, сглаженные линии, zlib «хранимыми» блоками.
-- Использование: lua tgbot-chart.lua out.png t0 t1 tz_offset_sec [единица] < данные
-- Данные (по строке):
--   s <серия 1..5> <epoch> <значение>   точка серии («-» вместо значения — разрыв линии)
--   b <epoch_начала> <epoch_конца>        интервал «радиатор грел»: оранжевая подложка и полоса внизу
--   l <серия> <стиль> [fill]              стиль серии: line (плавная, по умолчанию), step (ступеньки), dash (пунктир-ступеньки);
--                                         fill — лёгкая заливка под линией
-- Цвета серий: 1 красный, 2 синий, 3 зелёный, 4 оранжевый, 5 фиолетовый (как эмодзи в подписи).
-- Ночь (22:00–06:00) подсвечивается фоном, справа — текущее значение каждой серии.
local bit = require "bit"
local out, t0, t1, tz = arg[1], tonumber(arg[2]), tonumber(arg[3]), tonumber(arg[4]) or 0
local unit = arg[5] or ""
local W, H = 960, 540
local L, R, T, B = 64, 74, 18, 40
local PW, PH = W - L - R, H - T - B

local COL = { {229,72,77}, {0,144,255}, {48,164,108}, {247,107,21}, {142,78,198} }
local WHITE, GRID, AXIS, TEXT = {255,255,255}, {234,236,240}, {176,182,192}, {96,104,116}
local NIGHT, HEAT = {241,244,250}, {247,107,21}

-- ---------- палитра и смешивание ----------
local pal, pidx = {}, {}
local function color(c)
    local r, g, b = math.floor(c[1] + 0.5), math.floor(c[2] + 0.5), math.floor(c[3] + 0.5)
    local k = r * 65536 + g * 256 + b
    local i = pidx[k]
    if i then return i end
    if #pal < 256 then
        pal[#pal + 1] = { r, g, b }; i = #pal - 1; pidx[k] = i; return i
    end
    local best, bd = 0, 1e9   -- палитра заполнена: ближайший цвет
    for j = 1, #pal do
        local p = pal[j]; local d = (p[1] - r) ^ 2 + (p[2] - g) ^ 2 + (p[3] - b) ^ 2
        if d < bd then bd, best = d, j - 1 end
    end
    pidx[k] = best
    return best
end
local BG = color(WHITE)
local img = {}
for i = 1, W * H do img[i] = BG end

local memo = {}
local function blend(i, c, a)   -- i: индекс пикселя (0-based), c: {r,g,b}, a: 0..1
    if a <= 0 then return end
    local q = math.floor(a * 16 + 0.5)
    if q <= 0 then return end
    local cur = img[i + 1]
    local key = (cur * 17 + q) * 16777216 + c[1] * 65536 + c[2] * 256 + c[3]
    local r = memo[key]
    if not r then
        local p, f = pal[cur + 1], q / 16
        r = color({ p[1] + (c[1] - p[1]) * f, p[2] + (c[2] - p[2]) * f, p[3] + (c[3] - p[3]) * f })
        memo[key] = r
    end
    img[i + 1] = r
end
local function fillrect(x0, y0, x1, y1, c, a)
    x0, x1 = math.max(0, math.floor(x0 + 0.5)), math.min(W - 1, math.floor(x1 + 0.5) - 1)
    y0, y1 = math.max(0, math.floor(y0 + 0.5)), math.min(H - 1, math.floor(y1 + 0.5) - 1)
    for y = y0, y1 do local row = y * W; for x = x0, x1 do blend(row + x, c, a or 1) end end
end

-- сглаженная линия: покрытие пикселя по расстоянию до отрезка, копится в cov (максимум), потом смешивается один раз
local function seg(cov, x0, y0, x1, y1, w)
    local hw = w / 2
    local dx, dy = x1 - x0, y1 - y0
    local len2 = dx * dx + dy * dy
    local xa, xb = math.floor(math.min(x0, x1) - hw - 1), math.ceil(math.max(x0, x1) + hw + 1)
    local ya, yb = math.floor(math.min(y0, y1) - hw - 1), math.ceil(math.max(y0, y1) + hw + 1)
    xa, xb, ya, yb = math.max(xa, 0), math.min(xb, W - 1), math.max(ya, 0), math.min(yb, H - 1)
    local steep = math.abs(dy) > math.abs(dx)
    local function px(x, y)
        local cx, cy = x + 0.5, y + 0.5
        local t = len2 > 0 and ((cx - x0) * dx + (cy - y0) * dy) / len2 or 0
        if t < 0 then t = 0 elseif t > 1 then t = 1 end
        local ex, ey = x0 + t * dx - cx, y0 + t * dy - cy
        local a = hw + 0.5 - math.sqrt(ex * ex + ey * ey)
        if a > 0 then
            if a > 1 then a = 1 end
            local k = y * W + x
            if (cov[k] or 0) < a then cov[k] = a end
        end
    end
    if not steep then
        for x = xa, xb do
            local u0 = dx ~= 0 and (x - x0) / dx or 0
            local u1 = dx ~= 0 and (x + 1 - x0) / dx or 1
            if u0 > u1 then u0, u1 = u1, u0 end
            u0, u1 = math.max(u0, 0), math.min(u1, 1)
            local ys, ye = y0 + dy * u0, y0 + dy * u1
            if ys > ye then ys, ye = ye, ys end
            for y = math.max(ya, math.floor(ys - hw - 1)), math.min(yb, math.ceil(ye + hw + 1)) do px(x, y) end
        end
    else
        for y = ya, yb do
            local u0 = (y - y0) / dy
            local u1 = (y + 1 - y0) / dy
            if u0 > u1 then u0, u1 = u1, u0 end
            u0, u1 = math.max(u0, 0), math.min(u1, 1)
            local xs, xe = x0 + dx * u0, x0 + dx * u1
            if xs > xe then xs, xe = xe, xs end
            for x = math.max(xa, math.floor(xs - hw - 1)), math.min(xb, math.ceil(xe + hw + 1)) do px(x, y) end
        end
    end
end
local function flush(cov, c, alpha)
    for k, a in pairs(cov) do blend(k, c, a * (alpha or 1)) end
end

-- ---------- шрифт 5x7: цифры и знаки ----------
local F = {
    ["0"]="01110100011001110101110011000101110", ["1"]="00100011000010000100001000010001110",
    ["2"]="01110100010000100010001000100011111", ["3"]="11111000100010000010000011000101110",
    ["4"]="00010001100101010010111110001000010", ["5"]="11111100001111000001000011000101110",
    ["6"]="00110010001000011110100011000101110", ["7"]="11111000010001000100010000100001000",
    ["8"]="01110100011000101110100011000101110", ["9"]="01110100011000101111000010001001100",
    ["-"]="00000000000000011111000000000000000", ["."]="00000000000000000000000001100011000",
    [":"]="00000110001100000000110001100000000", ["%"]="11000110010001000100010001001100011",
    ["°"]="01100100101001001100000000000000000", [" "]="00000000000000000000000000000000000" }
local ADV = { ["."] = 4, [":"] = 4, ["°"] = 5, [" "] = 4 }
local CHP = "[%z\1-\127\194-\244][\128-\191]*"
local function twidth(s, sc)
    local n = 0
    for ch in s:gmatch(CHP) do n = n + (ADV[ch] or 6) end
    return (n - 1) * (sc or 2)
end
local function text(s, x, y, c, sc, a)
    sc = sc or 2
    x = math.floor(x + 0.5); y = math.floor(y + 0.5)
    for ch in s:gmatch(CHP) do
        local g = F[ch]
        if g then
            for r = 0, 6 do for k = 0, 4 do
                if g:byte(r * 5 + k + 1) == 49 then fillrect(x + k * sc, y + r * sc, x + k * sc + sc, y + r * sc + sc, c, a) end
            end end
        end
        x = x + (ADV[ch] or 6) * sc
    end
end

-- ---------- данные ----------
local ser, bands, style = {}, {}, {}
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
    elseif a == "l" then
        local s = tonumber(b)
        if s then style[s] = { kind = c, fill = (d == "fill") } end
    end
end
if not vmin then io.stderr:write("нет данных\n") os.exit(1) end
-- история короче запрошенного периода (например, HA работает 2 дня, а просили 7): ось начинается с первых данных
local tfirst
for _, pts in pairs(ser) do for _, p in ipairs(pts) do if p[2] and (not tfirst or p[1] < tfirst) then tfirst = p[1] end end end
if tfirst and tfirst > t0 + (t1 - t0) * 0.1 then t0 = tfirst - math.min(3600, (t1 - tfirst) * 0.02) end

-- шкала: «круглый» шаг, 4–7 делений, немного воздуха сверху и снизу
local span = vmax - vmin
if span < 2 then local m = (vmax + vmin) / 2; vmin, vmax = m - 1, m + 1; span = 2 end
local step = 20
for _, s in ipairs({ 0.5, 1, 2, 5, 10, 20 }) do if (span * 1.1) / s <= 6 then step = s; break end end
vmin = math.floor((vmin - span * 0.04) / step) * step
vmax = math.ceil((vmax + span * 0.04) / step) * step
local function X(t) return L + (t - t0) / (t1 - t0) * PW end
local function Y(v) return T + PH - (v - vmin) / (vmax - vmin) * PH end

-- ---------- фон: ночь, «грело», сетка ----------
local DAY = 86400
local d0 = math.floor((t0 + tz) / DAY) * DAY - tz - DAY
while d0 < t1 do
    local a, b = math.max(d0 + 22 * 3600, t0), math.min(d0 + 30 * 3600, t1)
    if b > a then fillrect(X(a), T, X(b), T + PH, NIGHT) end
    d0 = d0 + DAY
end
for _, b in ipairs(bands) do
    local a, e = math.max(b[1], t0), math.min(b[2], t1)
    if e > a then
        fillrect(X(a), T, X(e) + 1, T + PH, HEAT, 0.07)
        fillrect(X(a), T + PH - 6, X(e) + 1, T + PH, HEAT, 0.55)
    end
end
local v = vmin
while v <= vmax + 1e-9 do
    local y = math.floor(Y(v) + 0.5)
    fillrect(L, y, L + PW, y + 1, GRID)
    local s = ((step < 1) and string.format("%.1f", v) or string.format("%d", math.floor(v + 0.5))) .. unit
    text(s, L - 10 - twidth(s), y - 7, TEXT)
    v = v + step
end
local hstep = (t1 - t0 <= 1.3 * DAY) and 3 * 3600 or ((t1 - t0 <= 3.5 * DAY) and 6 * 3600 or DAY)
local first = math.ceil((t0 + tz) / hstep) * hstep - tz
for t = first, t1, hstep do
    local x = math.floor(X(t) + 0.5)
    local midnight = (t + tz) % DAY == 0
    fillrect(x, T, x + 1, T + PH, (midnight and hstep < DAY) and AXIS or GRID)
    local s = (hstep < DAY and not (midnight and t1 - t0 > 1.3 * DAY)) and os.date("!%H:%M", t + tz) or os.date("!%d.%m", t + tz)
    if x - twidth(s) / 2 > 4 and x + twidth(s) / 2 < W - 4 then text(s, x - twidth(s) / 2, T + PH + 12, TEXT) end
end
fillrect(L, T + PH, L + PW + 1, T + PH + 1, AXIS)

-- ---------- серии ----------
local RAMP = 1800   -- плавная линия: значение держится, потом за ≤30 мин переходит к следующему
local order = {}
for s in pairs(ser) do order[#order + 1] = s end
local PRIO = { [3] = 1, [5] = 2, [2] = 3, [4] = 4, [1] = 5 }   -- цель внизу, уставка над ней, комната поверх всех
table.sort(order, function(a, b) return (PRIO[a] or 0) < (PRIO[b] or 0) end)
local last = {}
for _, s in ipairs(order) do
    local pts = ser[s]
    table.sort(pts, function(a, b) return a[1] < b[1] end)
    local st = style[s] or { kind = "line" }
    local c = COL[s] or COL[5]
    -- ломаная в экранных координатах; nil — разрыв
    local poly = {}
    for i = 1, #pts do
        local ta, va = pts[i][1], pts[i][2]
        local nx = pts[i + 1]
        local tb = nx and nx[1] or t1
        if va and tb > t0 then
            local a = math.max(ta, t0)
            local y = Y(va)
            if st.kind == "line" and nx and nx[2] then
                local r = math.min(RAMP, (tb - ta) / 2)
                local hold = math.max(tb - r, a)
                poly[#poly + 1] = { X(a), y }
                poly[#poly + 1] = { X(hold), y }
                poly[#poly + 1] = { X(tb), Y(nx[2]) }
            else
                poly[#poly + 1] = { X(a), y }
                poly[#poly + 1] = { X(math.min(tb, t1)), y }
                if nx and nx[2] then poly[#poly + 1] = { X(tb), Y(nx[2]) } else poly[#poly + 1] = false end
            end
        elseif not va then
            poly[#poly + 1] = false
        end
        if va then last[s] = va elseif i == #pts then last[s] = nil end
    end
    -- заливка под линией
    if st.fill then
        local cov = {}
        for i = 1, #poly - 1 do
            local p, q = poly[i], poly[i + 1]
            if p and q and q[1] > p[1] then
                for x = math.floor(p[1]), math.floor(q[1]) - 1 do
                    local y = p[2] + (q[2] - p[2]) * ((x + 0.5 - p[1]) / (q[1] - p[1]))
                    for yy = math.max(T, math.floor(y + 1)), T + PH - 1 do cov[yy * W + x] = 1 end
                end
            end
        end
        flush(cov, c, 0.09)
    end
    -- линия
    local cov, w = {}, (s == 1) and 3.2 or ((st.kind == "dash") and 1.8 or 2.4)
    local dash = st.kind == "dash"
    local phase = 0
    for i = 1, #poly - 1 do
        local p, q = poly[i], poly[i + 1]
        if p and q then
            if dash then
                local len = math.sqrt((q[1] - p[1]) ^ 2 + (q[2] - p[2]) ^ 2)
                local pos = 0
                while pos < len do
                    local on = phase < 9
                    local run = math.min(len - pos, on and (9 - phase) or (15 - phase))
                    if on and run > 0 then
                        local a, b = pos / len, (pos + run) / len
                        seg(cov, p[1] + (q[1] - p[1]) * a, p[2] + (q[2] - p[2]) * a, p[1] + (q[1] - p[1]) * b, p[2] + (q[2] - p[2]) * b, w)
                    end
                    pos = pos + run; phase = (phase + run) % 15
                end
            else
                seg(cov, p[1], p[2], q[1], q[2], w)
            end
        end
    end
    flush(cov, c)
end

-- ---------- подписи текущих значений справа ----------
local labs = {}
for s, val in pairs(last) do
    local txt = (math.abs(val - math.floor(val)) < 0.05 and string.format("%d", math.floor(val + 0.5)) or string.format("%.1f", val)) .. unit
    labs[#labs + 1] = { s = s, y = Y(val), t = txt }
end
table.sort(labs, function(a, b) return a.y < b.y end)
local LH = 22
for i = 2, #labs do if labs[i].y - labs[i - 1].y < LH then labs[i].y = labs[i - 1].y + LH end end
for i = #labs, 1, -1 do   -- не вылезать за низ
    local lim = (labs[i + 1] and labs[i + 1].y - LH) or (T + PH - LH / 2)
    if labs[i].y > lim then labs[i].y = lim end
end
for _, lb in ipairs(labs) do
    local c = COL[lb.s] or COL[5]
    local x0, y0 = L + PW + 8, math.floor(lb.y - LH / 2 + 1.5)
    local x1, y1 = x0 + twidth(lb.t) + 12, y0 + LH - 3
    fillrect(x0 + 1, y0, x1 - 1, y1, c); fillrect(x0, y0 + 1, x1, y1 - 1, c)
    text(lb.t, x0 + 6, y0 + 3, WHITE)
end

-- ---------- PNG: палитра, 8 бит на пиксель ----------
local chr = {}
for i = 0, 255 do chr[i] = string.char(i) end
local rows = {}
for y = 0, H - 1 do
    local r, base = { "\0" }, y * W
    for x = 1, W do r[x + 1] = chr[img[base + x]] end
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
    local band, bxor, rshift, byte = bit.band, bit.bxor, bit.rshift, string.byte
    for i = 1, #s do c = bxor(crct[band(bxor(c, byte(s, i)), 0xFF)], rshift(c, 8)) end
    return bit.bnot(c)
end
local function adler32(s)
    local a, b, byte = 1, 0, string.byte
    for i = 1, #s do a = a + byte(s, i); if a >= 65521 then a = a - 65521 end; b = (b + a) % 65521 end
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
for i = 1, #pal do plte[#plte + 1] = string.char(pal[i][1], pal[i][2], pal[i][3]) end
local f = assert(io.open(out, "wb"))
f:write("\137PNG\13\10\26\10" .. chunk("IHDR", u32(W) .. u32(H) .. "\8\3\0\0\0") .. chunk("PLTE", table.concat(plte))
    .. chunk("IDAT", table.concat(z)) .. chunk("IEND", ""))
f:close()
