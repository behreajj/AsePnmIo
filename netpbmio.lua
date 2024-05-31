local uiAvailable <const> = app.isUIAvailable

local fileTypes <const> = { "pbm", "pgm", "ppm" }
local writeModes <const> = { "ASCII", "BINARY" }
local colorModes <const> = { "RGB", "GRAY", "INDEXED" }

local defaults <const> = {
    colorMode = "RGB",
    writeMode = "ASCII",
    channelMax = 255,
    pivot = 128,
    scale = 1,
    usePixelAspect = true,
}

---Define luminance function for converting RGB to gray.
---Default to Aseprite's definition, even though better
---alternatives exist.
---@param r integer
---@param g integer
---@param b integer
---@return integer
local function lum(r, g, b)
    return (r * 2126 + g * 7152 + b * 722) // 10000
end

---@param str string
---@param alt boolean
---@return boolean
local function parseCliBool(str, alt)
    if str and #str > 0 then
        local strLwr <const> = str.lower(str)
        if strLwr == "t" or strLwr == "true" or strLwr == "1" then
            return true
        elseif strLwr == "f" or strLwr == "false" or strLwr == "0" then
            return false
        end
        return alt
    end
    return alt
end

---@param s string range string
---@param frameCount integer? number of frames
---@param offset integer? offset
---@return integer[]
local function parseCliRange(s, frameCount, offset)
    local offVerif <const> = offset or 0
    local fcVerif <const> = frameCount or 2147483647

    local strgmatch <const> = string.gmatch
    local min <const> = math.min
    local max <const> = math.max

    ---@type table<integer, boolean>
    local uniqueDict <const> = {}

    -- Parse string by comma.
    for token in strgmatch(s, "([^,]+)") do
        ---@type integer[]
        local edges <const> = {}
        local idxEdges = 0

        -- Parse string by colon.
        for subtoken in strgmatch(token, "[^:]+") do
            local trial <const> = tonumber(subtoken, 10)
            if trial then
                idxEdges = idxEdges + 1
                edges[idxEdges] = trial - offVerif
            end
        end

        local lenEdges <const> = #edges
        if lenEdges > 1 then
            local origIdx = edges[1]
            local destIdx = edges[lenEdges]

            -- Edges of a range should be clamped to valid.
            origIdx = min(max(origIdx, 1), fcVerif)
            destIdx = min(max(destIdx, 1), fcVerif)

            if destIdx < origIdx then
                local j = origIdx + 1
                while j > destIdx do
                    j = j - 1
                    uniqueDict[j] = true
                end
            elseif destIdx > origIdx then
                local j = origIdx - 1
                while j < destIdx do
                    j = j + 1
                    uniqueDict[j] = true
                end
            else
                uniqueDict[destIdx] = true
            end
        elseif lenEdges > 0 then
            -- Filter out unique numbers if invalid, don't bother clamping.
            local trial <const> = edges[1]
            if trial >= 1 and trial <= fcVerif then
                uniqueDict[trial] = true
            end
        end
    end

    ---@type integer[]
    local arr <const> = {}
    for idx, _ in pairs(uniqueDict) do arr[#arr + 1] = idx end
    return arr
end

---@param str string
---@param lb integer
---@param ub integer
---@param alt integer
---@param base integer
---@return integer
local function parseCliUint(str, lb, ub, alt, base)
    if str and #str > 0 then
        local num <const> = tonumber(str, base)
        if num then
            return math.min(math.max(math.floor(math.abs(num) + 0.5), lb), ub)
        end
        return alt
    end
    return alt
end

---@param importFilepath string
---@param colorMode "RGB"|"GRAY"|"INDEXED"
---@param dithering "ordered"|"old"|"error-diffusion"|"none"
---@param toGray "luma"|"hsv"|"hsl"|"default"
---@return Sprite|nil
local function readFile(importFilepath, colorMode, dithering, toGray)
    -- Check for invalid file extension.
    local filepathLower <const> = string.lower(importFilepath)
    local fileSysTools <const> = app.fs
    local fileExt <const> = fileSysTools.fileExtension(filepathLower)
    local extIsPbm <const> = fileExt == "pbm"
    local extIsPgm <const> = fileExt == "pgm"
    local extIsPpm <const> = fileExt == "ppm"
    if not (extIsPbm or extIsPgm or extIsPpm) then
        if uiAvailable then
            app.alert {
                title = "Error",
                text = "File extension must be pbm, pgm or ppm."
            }
        else
            print("Error: File extension must be pbm, pgm or ppm.")
        end
        return nil
    end

    local asciiFile <const>, err <const> = io.open(importFilepath, "r")
    if err ~= nil then
        if asciiFile then asciiFile:close() end
        if uiAvailable then
            app.alert { title = "Error", text = err }
        else
            print(err)
        end
        return nil
    end

    if asciiFile == nil then
        if uiAvailable then
            app.alert {
                title = "Error",
                text = "File could not be opened."
            }
        else
            print(string.format("Error: Could not open file \"%s\".",
                importFilepath))
        end
        return nil
    end

    -- Cache functions to local when used in loop.
    local abs <const> = math.abs
    local floor <const> = math.floor
    local max <const> = math.max
    local min <const> = math.min
    local strgmatch <const> = string.gmatch
    local strlower <const> = string.lower
    local strpack <const> = string.pack
    local strsub <const> = string.sub
    local strunpack <const> = string.unpack

    ---@type string[]
    local comments <const> = {}

    ---@type number[]
    local pxData <const> = {}

    local headerFound = 0
    local channelMaxFound = 0
    local whFound = 0

    -- For ASCII pbm files, delimiter needs to be changed to parse lines by
    -- each character in a sequence, not by strings of characters. This is
    -- because GIMP exports its pbm bits as "11001" not "1 1 0 0 1".
    local delimiter = "%S+"
    local channels3 = false
    local isBinPbm = false
    local includesChnlMax = false
    local isBinary = false
    local invert = false
    local channelMax = 255.0
    local fromChnlMax = 255.0
    local stride = 1
    local spriteWidth = 1
    local spriteHeight = 1

    local charCount = 0
    local linesItr <const> = asciiFile:lines("L")
    for line in linesItr do
        local lenLine <const> = #line
        charCount = charCount + lenLine
        if lenLine > 0 then
            local lc <const> = strlower(line)
            local twoChars <const> = strsub(lc, 1, 2)
            if strsub(line, 1, 1) == '#' then
                comments[#comments + 1] = strsub(line, 1)
            elseif twoChars == "p1" then
                headerFound = charCount
                invert = true
                delimiter = "%S"
            elseif twoChars == "p2" then
                headerFound = charCount
                includesChnlMax = true
            elseif twoChars == "p3" then
                headerFound = charCount
                includesChnlMax = true
                channels3 = true
                stride = 3
            elseif twoChars == "p4" then
                headerFound = charCount
                isBinary = true
                isBinPbm = true
                invert = true
            elseif twoChars == "p5" then
                headerFound = charCount
                isBinary = true
                includesChnlMax = true
            elseif twoChars == "p6" then
                headerFound = charCount
                isBinary = true
                includesChnlMax = true
                channels3 = true
                stride = 3
            elseif whFound <= 0 then
                whFound = charCount

                ---@type string[]
                local whTokens <const> = {}
                local lenWhTokens = 0
                for token in strgmatch(line, "%S+") do
                    lenWhTokens = lenWhTokens + 1
                    whTokens[lenWhTokens] = token
                end

                if lenWhTokens > 0 then
                    local wPrs <const> = tonumber(whTokens[1], 10)
                    if wPrs then
                        spriteWidth = floor(abs(wPrs) + 0.5)
                        spriteHeight = spriteWidth
                    end
                end

                if lenWhTokens > 1 then
                    local hPrs <const> = tonumber(whTokens[2], 10)
                    if hPrs then
                        spriteHeight = floor(abs(hPrs) + 0.5)
                    end
                end

                if lenWhTokens > 2 then
                    channelMaxFound = charCount
                    local channelMaxPrs <const> = tonumber(whTokens[3], 10)
                    if channelMaxPrs then
                        channelMax = min(max(floor(abs(channelMaxPrs) + 0.5), 1), 255)
                        fromChnlMax = 255.0 / channelMax
                    end
                end
            elseif includesChnlMax and channelMaxFound <= 0 then
                channelMaxFound = charCount
                local channelMaxPrs <const> = tonumber(lc, 10)
                if channelMaxPrs then
                    channelMax = min(max(floor(abs(channelMaxPrs) + 0.5), 1), 255)
                    fromChnlMax = 255.0 / channelMax
                end
            else
                if isBinary then break end
                for token in strgmatch(line, delimiter) do
                    local num <const> = tonumber(token, 10)
                    if num then pxData[#pxData + 1] = num end
                end -- End of ASCII read loop.
            end     -- End of data chunk parse block.
        end         -- End of line length gt zero check.
    end             -- End of lines iterator loop.

    asciiFile:close()

    if headerFound <= 0 then
        if uiAvailable then
            app.alert {
                title = "Error",
                text = "No supported file header found."
            }
        else
            print("Error: No supported file header found.")
        end
        return nil
    end

    if isBinary then
        -- Assume that the data block is the final block and read from the
        -- suffix of the file according to the flat length.
        local flatLen = spriteWidth * spriteHeight
        if isBinPbm then
            local charsPerRow <const> = math.ceil(spriteWidth / 8)
            flatLen = charsPerRow * spriteHeight
        end
        local strideFlatLen <const> = stride * flatLen

        local binFile <const>, _ <const> = io.open(importFilepath, "rb")
        if not binFile then return end
        local allChars <const> = binFile:read("a")
        local dataBlock <const> = strsub(allChars, -strideFlatLen)
        for token in strgmatch(dataBlock, ".") do
            local num <const> = strunpack("B", token)
            -- print(strfmt("%02x", num))
            pxData[#pxData + 1] = num
        end
        binFile:close()
    end

    -- Create image and sprite specification.
    local clampedSpriteWidth <const> = min(max(spriteWidth, 1), 65535)
    local clampedSpriteHeight <const> = min(max(spriteHeight, 1), 65535)
    local spriteSpec <const> = ImageSpec {
        width = clampedSpriteWidth,
        height = clampedSpriteHeight,
        colorMode = ColorMode.RGB,
        transparentColor = 0
    }
    spriteSpec.colorSpace = ColorSpace { sRGB = true }

    -- This precaution minimizes raising an Aseprite error that will
    -- halt the script.
    local spriteFlatLen <const> = clampedSpriteHeight * clampedSpriteWidth
    local spriteStrideFlatLen <const> = stride * spriteFlatLen
    while #pxData < spriteStrideFlatLen do pxData[#pxData + 1] = 0 end

    local rBlack <const> = 0
    local gBlack <const> = 0
    local bBlack <const> = 0

    local rWhite <const> = 255
    local gWhite <const> = 255
    local bWhite <const> = 255

    -- Write to image based on file type.
    local image <const> = Image(spriteSpec)
    if isBinPbm then
        local wBlack <const> = strpack("B B B B", rBlack, gBlack, bBlack, 255)
        local wWhite <const> = strpack("B B B B", rWhite, gWhite, bWhite, 255)
        local charsPerRow <const> = math.ceil(spriteWidth / 8)

        ---@type string[]
        local bwStrs <const> = {}
        local i = 0
        while i < spriteFlatLen do
            local xSprite = i % clampedSpriteWidth
            local ySprite = i // clampedSpriteWidth

            local xChar <const> = xSprite // 8
            local xBit <const> = xSprite % 8

            local j <const> = xChar + charsPerRow * ySprite
            local char <const> = pxData[1 + j]
            local shift <const> = 7 - xBit
            local bit <const> = (char >> shift) & 1

            i = i + 1
            bwStrs[i] = bit == 0 and wWhite or wBlack
        end

        image.bytes = table.concat(bwStrs)
    elseif channels3 then
        ---@type string[]
        local rgbStrs <const> = {}
        local i = 0
        while i < spriteFlatLen do
            local k <const> = i * 3
            local r <const> = floor(pxData[1 + k] * fromChnlMax + 0.5)
            local g <const> = floor(pxData[2 + k] * fromChnlMax + 0.5)
            local b <const> = floor(pxData[3 + k] * fromChnlMax + 0.5)

            i = i + 1
            rgbStrs[i] = strpack("B B B B", r, g, b, 255)
        end
        image.bytes = table.concat(rgbStrs)
    else
        ---@type string[]
        local gryStrs <const> = {}
        local i = 0
        while i < spriteFlatLen do
            i = i + 1
            local u <const> = pxData[i]
            local v = floor(u * fromChnlMax + 0.5)
            if invert then v = 255 ~ v end
            gryStrs[i] = strpack("B B B B", v, v, v, 255)
        end
        image.bytes = table.concat(gryStrs)
    end

    -- Create the sprite and assign the image to the sprite's cel.
    local sprite <const> = Sprite(spriteSpec)
    sprite.cels[1].image = image

    -- Name the sprite after the file name.
    sprite.filename = fileSysTools.fileName(importFilepath)

    -- Set the palette.
    if extIsPbm then
        local palette <const> = sprite.palettes[1]
        app.transaction("Set Palette", function()
            palette:resize(3)
            palette:setColor(0, Color { r = 0, g = 0, b = 0, a = 0 })
            palette:setColor(1, Color { r = rBlack, g = gBlack, b = bBlack, a = 255 })
            palette:setColor(2, Color { r = rWhite, g = gWhite, b = bWhite, a = 255 })
        end)
    else
        app.command.ColorQuantization { ui = false, maxColors = 256 }
    end

    -- Set sprite color mode to user preference if not RGB. Internally, the
    -- default will be used in an else case when there's no match.
    if colorMode then
        if colorMode == "INDEXED" then
            -- Ordered dithering is slow for large images with large palettes.
            app.command.ChangePixelFormat {
                ui = false,
                format = "indexed",
                ---@diagnostic disable-next-line: assign-type-mismatch
                dithering = dithering
            }
        elseif colorMode == "GRAY" then
            app.command.ChangePixelFormat {
                ui = false,
                format = "gray",
                ---@diagnostic disable-next-line: assign-type-mismatch
                toGray = toGray
            }
        end
    end

    -- Turn off onion skin loop through tag frames.
    local appPrefs <const> = app.preferences
    if appPrefs then
        local docPrefs <const> = appPrefs.document(sprite)
        if docPrefs then
            local onionSkinPrefs <const> = docPrefs.onionskin
            if onionSkinPrefs then
                onionSkinPrefs.loop_tag = false
            end

            local thumbPrefs <const> = docPrefs.thumbnails
            if thumbPrefs then
                thumbPrefs.enabled = true
                thumbPrefs.zoom = 1
                thumbPrefs.overlay_enabled = true
            end
        end
    end

    return sprite
end

---@param exportFilepath string
---@param activeSprite Sprite
---@param frIdcs integer[]
---@param writeMode "ASCII"|"BINARY"
---@param channelMax integer
---@param pivot integer
---@param scale integer
---@param usePixelAspect boolean
local function writeFile(
    exportFilepath,
    activeSprite,
    frIdcs,
    writeMode,
    channelMax,
    pivot,
    scale,
    usePixelAspect)
    -- Check for invalid file extension.
    local fileSysTools <const> = app.fs
    local fileExt <const> = fileSysTools.fileExtension(exportFilepath)
    local filePathAndTitle <const> = string.gsub(
        fileSysTools.filePathAndTitle(exportFilepath), "\\", "\\\\")

    local fileExtLower <const> = string.lower(fileExt)
    local extIsPbm <const> = fileExtLower == "pbm"
    local extIsPgm <const> = fileExtLower == "pgm"
    local extIsPpm <const> = fileExtLower == "ppm"

    if not (extIsPbm or extIsPgm or extIsPpm) then
        if uiAvailable then
            app.alert {
                title = "Error",
                text = "File extension must be pbm, pgm or ppm."
            }
        else
            print("Error: File extension must be pbm, pgm or ppm.")
        end
        return
    end

    -- For the pbm file extension, black is associated with 1 or on,
    -- and white is associated with 0 or off. This is the opposite of
    -- image conventions.
    local offTok <const> = "1"
    local onTok <const> = "0"

    -- Unpack sprite data.
    local palettes <const> = activeSprite.palettes
    local lenPalettes <const> = #palettes
    local spriteSpec <const> = activeSprite.spec
    local wSprite <const> = spriteSpec.width
    local hSprite <const> = spriteSpec.height
    local colorMode <const> = spriteSpec.colorMode

    -- Process color mode.
    local cmIsRgb <const> = colorMode == ColorMode.RGB
    local cmIsGry <const> = colorMode == ColorMode.GRAY
    local cmIsIdx <const> = colorMode == ColorMode.INDEXED

    -- Process mode.
    local fmtIsBinary <const> = writeMode == "BINARY"
    local fmtIsAscii <const> = writeMode == "ASCII"

    -- Process channel max.
    local chnlMaxVerif <const> = math.min(math.max(channelMax, 1), 255)
    local toChnlMax <const> = chnlMaxVerif / 255.0
    local frmtrStr = "%d"
    if fmtIsAscii then
        if chnlMaxVerif < 10 then
            frmtrStr = "%01d"
        elseif chnlMaxVerif < 100 then
            frmtrStr = "%02d"
        elseif chnlMaxVerif < 1000 then
            frmtrStr = "%03d"
        end
    end

    -- Process scale.
    local wScale = scale
    local hScale = scale
    if usePixelAspect then
        -- Pixel ratio sizes are not validated by Aseprite.
        local pxRatio <const> = activeSprite.pixelRatio
        local pxw <const> = math.max(1, math.abs(pxRatio.width))
        local pxh <const> = math.max(1, math.abs(pxRatio.height))
        wScale = wScale * pxw
        hScale = hScale * pxh
    end
    local useResize <const> = wScale ~= 1 or hScale ~= 1
    local wSpriteScld <const> = math.min(wSprite * wScale, 65535)
    local hSpriteScld <const> = math.min(hSprite * hScale, 65535)
    local imageSizeStr <const> = string.format(
        "%d %d",
        wSpriteScld, hSpriteScld)

    -- Supplied to image pixel method when looping
    -- by pixel row.
    local rowRect <const> = Rectangle(0, 0, wSpriteScld, 1)

    -- Cache global methods to local.
    local floor <const> = math.floor
    local ceil <const> = math.ceil
    local strfmt <const> = string.format
    local strpack <const> = string.pack
    local strsub <const> = string.sub
    local strgsub <const> = string.gsub
    local tconcat <const> = table.concat
    local tinsert <const> = table.insert

    -- For the binary format, the code supplied to io.open is different.
    -- The separators for columns and rows are not needed.
    local writerType = "w"
    local colSep = " "
    local rowSep = "\n"
    if fmtIsBinary then
        writerType = "wb"
        colSep = ""
        rowSep = ""
    end

    -- The appropriate string for a pixel differs based on (1.) the
    -- extension, (2.) the sprite color mode, (3.) whether ASCII or binary
    -- is being written. Binary .pbm files are a special case because bits
    -- are packed into byte-sized ASCII chars.
    local headerStr = ""
    local chnlMaxStr = ""
    local isBinPbm = false
    local writePixel = nil

    if extIsPpm then
        -- File extension supports RGB.
        headerStr = "P3"
        chnlMaxStr = strfmt("%d", chnlMaxVerif)
        local rgbFrmtrStr = strfmt(
            "%s %s %s",
            frmtrStr, frmtrStr, frmtrStr)
        if fmtIsBinary then
            headerStr = "P6"
            rgbFrmtrStr = "%s%s%s"
        end

        if cmIsIdx then
            if fmtIsBinary then
                writePixel = function(h, p)
                    local c <const> = p:getColor(h)
                    return strpack("B B B",
                        floor(c.red * toChnlMax + 0.5),
                        floor(c.green * toChnlMax + 0.5),
                        floor(c.blue * toChnlMax + 0.5))
                end
            else
                writePixel = function(h, p)
                    local c <const> = p:getColor(h)
                    return strfmt(rgbFrmtrStr,
                        floor(c.red * toChnlMax + 0.5),
                        floor(c.green * toChnlMax + 0.5),
                        floor(c.blue * toChnlMax + 0.5))
                end
            end
        elseif cmIsGry then
            if fmtIsBinary then
                writePixel = function(h)
                    local v <const> = floor((h & 0xff) * toChnlMax + 0.5)
                    return strpack("B B B", v, v, v)
                end
            else
                writePixel = function(h)
                    local v <const> = floor((h & 0xff) * toChnlMax + 0.5)
                    return strfmt(rgbFrmtrStr, v, v, v)
                end
            end
        else
            -- Default to RGB color mode.
            if fmtIsBinary then
                writePixel = function(h)
                    return strpack("B B B",
                        floor((h & 0xff) * toChnlMax + 0.5),
                        floor((h >> 0x08 & 0xff) * toChnlMax + 0.5),
                        floor((h >> 0x10 & 0xff) * toChnlMax + 0.5))
                end
            else
                writePixel = function(h)
                    return strfmt(rgbFrmtrStr,
                        floor((h & 0xff) * toChnlMax + 0.5),
                        floor((h >> 0x08 & 0xff) * toChnlMax + 0.5),
                        floor((h >> 0x10 & 0xff) * toChnlMax + 0.5))
                end
            end
        end
    elseif extIsPgm then
        -- File extension supports grayscale.
        -- From Wikipedia:
        -- "Conventionally PGM stores values in linear color space, but
        -- depending on the application, it can often use either sRGB or a
        -- simplified gamma representation."

        headerStr = "P2"
        chnlMaxStr = strfmt("%d", chnlMaxVerif)
        if fmtIsBinary then
            headerStr = "P5"
        end

        if cmIsIdx then
            if fmtIsBinary then
                writePixel = function(h, p)
                    local c <const> = p:getColor(h)
                    return strpack("B", floor(lum(
                        c.red, c.green, c.blue) * toChnlMax + 0.5))
                end
            else
                writePixel = function(h, p)
                    local c <const> = p:getColor(h)
                    return strfmt(frmtrStr, floor(lum(
                        c.red, c.green, c.blue) * toChnlMax + 0.5))
                end
            end
        elseif cmIsRgb then
            if fmtIsBinary then
                writePixel = function(h)
                    return strpack("B", floor(lum(
                        h & 0xff,
                        h >> 0x08 & 0xff,
                        h >> 0x10 & 0xff) * toChnlMax + 0.5))
                end
            else
                writePixel = function(h)
                    return strfmt(frmtrStr, floor(lum(
                        h & 0xff,
                        h >> 0x08 & 0xff,
                        h >> 0x10 & 0xff) * toChnlMax + 0.5))
                end
            end
        else
            -- Default to grayscale color mode.
            if fmtIsBinary then
                writePixel = function(h)
                    return strpack("B", floor((h & 0xff) * toChnlMax + 0.5))
                end
            else
                writePixel = function(h)
                    return strfmt(frmtrStr, floor((h & 0xff) * toChnlMax + 0.5))
                end
            end
        end
    else
        -- Default to extIsPbm (1 or 0).
        headerStr = "P1"
        if fmtIsBinary then
            headerStr = "P4"
            isBinPbm = true
        end

        if cmIsGry then
            writePixel = function(h)
                if (h & 0xff) < pivot then return offTok end
                return onTok
            end
        elseif cmIsRgb then
            writePixel = function(h)
                if lum(h & 0xff, h >> 0x08 & 0xff,
                        h >> 0x10 & 0xff) < pivot then
                    return offTok
                end
                return onTok
            end
        else
            writePixel = function(h, p)
                local c <const> = p:getColor(h)
                if lum(c.red, c.green, c.blue) < pivot then
                    return offTok
                end
                return onTok
            end
        end
    end

    -- Store unique pixels in a dictionary, where each pixel value is the
    -- key and its string representation is the value. (For multiple frames,
    -- initialize this dictionary outside the frames loop.)
    ---@type table<integer, string>
    local hexToStr <const> = {}

    local lenFrIdcs <const> = #frIdcs
    local h = 0
    while h < lenFrIdcs do
        h = h + 1
        local frIdx <const> = frIdcs[h]

        -- In rare cases, e.g., a sprite opened from a sequence of indexed
        -- color mode files, there may be multiple palettes in the sprite.
        local paletteIdx = frIdx
        if paletteIdx > lenPalettes then paletteIdx = 1 end
        local palette <const> = palettes[paletteIdx]

        -- Blit the sprite composite onto a new image.
        local trgImage <const> = Image(spriteSpec)
        trgImage:drawSprite(activeSprite, frIdx)
        local trgPxItr <const> = trgImage:pixels()

        -- Convert pixels to strings.
        for pixel in trgPxItr do
            local hex <const> = pixel()
            if not hexToStr[hex] then
                hexToStr[hex] = writePixel(hex, palette)
            end
        end

        -- Scale image after unique pixels have been found.
        if useResize then
            trgImage:resize(wSpriteScld, hSpriteScld)
        end

        -- Concatenate pixels into  columns, then rows.
        ---@type string[]
        local rowStrs <const> = {}
        local j = 0
        while j < hSpriteScld do
            ---@type string[]
            local colStrs <const> = {}
            rowRect.y = j
            local rowItr <const> = trgImage:pixels(rowRect)
            for rowPixel in rowItr do
                colStrs[#colStrs + 1] = hexToStr[rowPixel()]
            end

            j = j + 1
            rowStrs[j] = tconcat(colStrs, colSep)
        end

        local frFilePath = exportFilepath
        if lenFrIdcs > 1 then
            frFilePath = strfmt("%s_%03d.%s", filePathAndTitle, frIdx, fileExt)
        end

        local file <const>, err <const> = io.open(frFilePath, writerType)
        if err ~= nil then
            if file then file:close() end
            if uiAvailable then
                app.alert { title = "Error", text = err }
            else
                print(err)
            end
            return
        end

        if file == nil then
            if uiAvailable then
                app.alert {
                    title = "Error",
                    text = "File could not be opened."
                }
            else
                print(strfmt("Error: Could not open file \"%s\".", frFilePath))
            end
            return
        end

        local imgDataStr = ""
        if isBinPbm then
            -- From Wikipedia:
            -- "The P4 binary format of the same image represents each pixel
            -- with a single bit, packing 8 pixels per byte, with the first
            -- pixel as the most significant bit. Extra bits are added at the
            -- end of each row to fill a whole byte."

            ---@type string[]
            local charStrs <const> = {}
            local lenRows <const> = #rowStrs
            local k = 0
            while k < lenRows do
                k = k + 1
                local rowStr <const> = rowStrs[k]
                local lenRowStr <const> = #rowStr
                local lenRowChars <const> = ceil(lenRowStr / 8)

                local m = 0
                while m < lenRowChars do
                    local idxOrig <const> = 1 + m * 8
                    local idxDest <const> = idxOrig + 7
                    local strSeg = strsub(rowStr, idxOrig, idxDest)
                    while #strSeg < 8 do strSeg = strSeg .. offTok end
                    local numSeg <const> = tonumber(strSeg, 2)
                    charStrs[#charStrs + 1] = strpack("B", numSeg)
                    m = m + 1
                end
            end

            imgDataStr = tconcat(charStrs)
        else
            imgDataStr = tconcat(rowStrs, rowSep)
        end

        ---@type string[]
        local chunks <const> = { headerStr, imageSizeStr, imgDataStr }
        if not extIsPbm then
            tinsert(chunks, 3, chnlMaxStr)
        end
        file:write(tconcat(chunks, "\n"))
        file:close()

        if not uiAvailable then
            print(strfmt("Wrote file to %s .",
                strgsub(frFilePath, "\\+", "\\")))
        end
    end
end

if not uiAvailable then
    local params <const> = app.params
    -- print("\nparams:")
    -- for k, v in pairs(params) do
    --     print(string.format("%s: %s", k, v))
    -- end

    local action = params["action"]
    if action and #action > 0 then
        action = string.upper(action)
    else
        print("Error: Parameter \"action\" requires an argument.")
        return
    end

    local readFilePath <const> = params["readFile"] or params["file"]
    if not readFilePath or #readFilePath < 1 then
        print("Error: Parameter \"readFile\" requires an argument.")
        return
    end

    if not app.fs.isFile(readFilePath) then
        print("Error: \"readFile\" does not refer to an existing file.")
        return
    end

    local writeFilePath = params["writeFile"]
    if not writeFilePath or #writeFilePath < 1 then
        if action == "IMPORT" then
            writeFilePath = app.fs.filePathAndTitle(readFilePath) .. ".aseprite"
        elseif action == "EXPORT" then
            writeFilePath = app.fs.filePathAndTitle(readFilePath) .. ".ppm"
        else
            print("Error: Parameter \"writeFile\" requires an argument.")
            return
        end
    end

    if action == "IMPORT" then
        local colorMode = defaults.colorMode
        local colorModeRequest = params["colorMode"]
        if colorModeRequest and #colorModeRequest > 0 then
            colorModeRequest = string.upper(colorModeRequest)
            if colorModeRequest == "RGB" then
                colorMode = "RGB"
            elseif colorModeRequest == "GRAY"
                or colorModeRequest == "GRAYSCALE"
                or colorModeRequest == "GREY" then
                colorMode = "GRAY"
            elseif colorModeRequest == "INDEXED"
                or colorModeRequest == "INDEX" then
                colorMode = "INDEXED"
            end
        end

        local dithering = "none"
        local ditherRequest <const> = params["dithering"]
        if ditherRequest and #ditherRequest > 0 then
            dithering = string.lower(ditherRequest)
        end

        local toGray = "default"
        local toGrayRequest <const> = params["toGray"]
        if toGrayRequest and #toGrayRequest > 0 then
            toGray = string.lower(toGrayRequest)
        end

        local sprite <const> = readFile(readFilePath, colorMode, dithering,
            toGray)
        if sprite then
            sprite:saveAs(writeFilePath)
            print(string.format("Wrote file to %s .",
                string.gsub(writeFilePath, "\\+", "\\")))
        else
            print(string.format("Error: Sprite %s could not be saved.",
                string.gsub(writeFilePath, "\\+", "\\")))
        end
    elseif action == "EXPORT" then
        local readSprite <const> = Sprite { fromFile = readFilePath }
        if not readSprite then
            print("Error: File could not be loaded to sprite.")
            return
        end

        ---@type integer[]
        local frIdcs = {}
        local framesRequest = params["frames"]
        if framesRequest and #framesRequest > 0 then
            framesRequest = string.upper(framesRequest)
            local numFrames <const> = #readSprite.frames
            if framesRequest == "ALL" then
                local i = 0
                while i < numFrames do
                    i = i + 1
                    frIdcs[i] = i
                end
            else
                frIdcs = parseCliRange(framesRequest, numFrames, 0)
            end
        else
            frIdcs[1] = 1
        end

        local writeMode = defaults.writeMode
        local writeModeRequest = params["writeMode"]
        if writeModeRequest and #writeModeRequest > 0 then
            writeModeRequest = string.upper(writeModeRequest)
            if writeModeRequest == "BINARY"
                or writeModeRequest == "RAW" then
                writeMode = "BINARY"
            elseif writeModeRequest == "ASCII"
                or writeModeRequest == "TEXT" then
                writeMode = "ASCII"
            end
        end

        local channelMax <const> = parseCliUint(params["channelMax"], 1, 255,
            defaults.channelMax, 10)
        local pivot <const> = parseCliUint(params["pivot"], 1, 255,
            defaults.pivot, 10)
        local scale <const> = parseCliUint(params["scale"], 1, 10,
            defaults.scale, 10)
        local usePixelAspect <const> = parseCliBool(params["usePixelAspect"],
            defaults.usePixelAspect)

        writeFile(writeFilePath, readSprite, frIdcs, writeMode, channelMax,
            pivot, scale, usePixelAspect)
    else
        print("Error: Action was not recognized.")
    end

    return
end

local dlg <const> = Dialog { title = "PNM Import Export" }

dlg:combobox {
    id = "colorMode",
    label = "Color:",
    option = defaults.colorMode,
    options = colorModes,
    focus = false
}

dlg:newrow { always = false }

dlg:file {
    id = "importFilepath",
    label = "Open:",
    filetypes = fileTypes,
    open = true,
    focus = true
}

dlg:newrow { always = false }

dlg:button {
    id = "importButton",
    text = "&IMPORT",
    focus = false,
    onclick = function()
        -- Check for invalid file path.
        local args <const> = dlg.data
        local importFilepath <const> = args.importFilepath --[[@as string]]
        if (not importFilepath) or #importFilepath < 1 then
            app.alert {
                title = "Error",
                text = "Empty file path."
            }
            return
        end

        -- As a precaution against crashes, do not allow slices UI interface
        -- to be active.
        local appTool <const> = app.tool
        if appTool then
            local toolName <const> = appTool.id
            if toolName == "slice" then
                app.tool = "hand"
            end
        end

        -- Just getting the tool above seems to suffice.
        -- Prevent uncommitted selection transformation (drop pixels) from
        -- raising an error.
        -- app.command.InvertMask()
        -- app.command.InvertMask()

        -- Preserve fore- and background colors.
        local fgc <const> = app.fgColor
        app.fgColor = Color {
            r = fgc.red,
            g = fgc.green,
            b = fgc.blue,
            a = fgc.alpha
        }

        app.command.SwitchColors()
        local bgc <const> = app.fgColor
        app.fgColor = Color {
            r = bgc.red,
            g = bgc.green,
            b = bgc.blue,
            a = bgc.alpha
        }
        app.command.SwitchColors()

        local colorMode <const> = args.colorMode
            or defaults.colorMode --[[@as string]]
        local sprite <const> = readFile(importFilepath, colorMode, "none",
            "default")

        if sprite then
            app.command.Zoom { action = "set", percentage = 100 }
            app.command.ScrollCenter()
        end
    end
}

dlg:separator { id = "exportSep" }

dlg:combobox {
    id = "writeMode",
    label = "Format:",
    option = defaults.writeMode,
    options = writeModes,
    focus = false
}

dlg:newrow { always = false }

dlg:slider {
    id = "channelMax",
    label = "Channel:",
    min = 1,
    max = 255,
    value = defaults.channelMax
}

dlg:newrow { always = false }

dlg:slider {
    id = "pivot",
    label = "Pivot:",
    min = 1,
    max = 255,
    value = defaults.pivot,
    visible = false
}

dlg:newrow { always = false }

dlg:slider {
    id = "scale",
    label = "Scale:",
    min = 1,
    max = 10,
    value = defaults.scale
}

dlg:newrow { always = false }

dlg:check {
    id = "usePixelAspect",
    label = "Apply:",
    text = "Pi&xel Aspect",
    selected = defaults.usePixelAspect,
    visible = true
}

dlg:newrow { always = false }

dlg:file {
    id = "exportFilepath",
    label = "Save:",
    filetypes = fileTypes,
    save = true,
    focus = false
}

dlg:newrow { always = false }

dlg:button {
    id = "exportButton",
    text = "E&XPORT",
    focus = false,
    onclick = function()
        local activeSprite <const> = app.sprite
        if not activeSprite then
            app.alert {
                title = "Error",
                text = "There is no active sprite."
            }
            return
        end

        local activeFrame <const> = app.frame
        if not activeFrame then
            app.alert {
                title = "Error",
                text = "There is no active frame."
            }
            return
        end

        -- Check for invalid file path.
        local args <const> = dlg.data
        local exportFilepath <const> = args.exportFilepath --[[@as string]]
        if (not exportFilepath) or #exportFilepath < 1 then
            app.alert {
                title = "Error",
                text = "Empty file path."
            }
            return
        end

        -- Prevent uncommitted selection transformation (drop pixels) from
        -- raising an error.
        app.command.InvertMask()
        app.command.InvertMask()

        -- Unpack other arguments.
        local writeMode <const> = args.writeMode
            or defaults.writeMode --[[@as string]]
        local channelMax <const> = args.channelMax
            or defaults.channelMax --[[@as integer]]
        local pivot <const> = args.pivot
            or defaults.pivot --[[@as integer]]
        local scale <const> = args.scale
            or defaults.scale --[[@as integer]]
        local usePixelAspect <const> = args.usePixelAspect --[[@as boolean]]

        writeFile(exportFilepath, activeSprite, { activeFrame.frameNumber },
            writeMode, channelMax, pivot, scale, usePixelAspect)

        app.alert {
            title = "Success",
            text = "File exported."
        }
    end
}

dlg:separator { id = "cancelSep" }

dlg:button {
    id = "cancel",
    text = "&CANCEL",
    focus = false,
    onclick = function()
        dlg:close()
    end
}

dlg:show {
    autoscrollbars = true,
    wait = false
}