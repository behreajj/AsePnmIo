local uiAvailable = app.isUIAvailable

local fileTypes = { "pbm", "pgm", "ppm" }
local writeModes = { "ASCII", "BINARY" }
local colorModes = { "RGB", "GRAY", "INDEXED" }

local defaults = {
    colorMode = "RGB",
    writeMode = "ASCII",
    channelMax = 255,
    pivot = 128,
    scale = 1,
    usePixelAspect = true,
}

---@param s string range string
---@param frameCount integer? number of frames
---@param offset integer? offset
---@return integer[]
local function parseRangeString(s, frameCount, offset)
    local offVerif = offset or 0
    local fcVerif = frameCount or 2147483647

    local strgmatch = string.gmatch
    local min = math.min
    local max = math.max

    ---@type table<integer, boolean>
    local uniqueDict = {}

    -- Parse string by comma.
    for token in strgmatch(s, "([^,]+)") do
        ---@type integer[]
        local edges = {}
        local idxEdges = 0

        -- Parse string by colon.
        for subtoken in strgmatch(token, "[^:]+") do
            local trial = tonumber(subtoken, 10)
            if trial then
                idxEdges = idxEdges + 1
                edges[idxEdges] = trial - offVerif
            end
        end

        local lenEdges = #edges
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
            local trial = edges[1]
            if trial >= 1 and trial <= fcVerif then
                uniqueDict[trial] = true
            end
        end
    end

    ---@type integer[]
    local arr = {}
    for idx, _ in pairs(uniqueDict) do arr[#arr + 1] = idx end
    return arr
end

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

---@param importFilepath string
---@param colorMode "RGB"|"GRAY"|"INDEXED"
---@param dithering "ordered"|"old"|"error-diffusion"|"none"
---@param toGray "luma"|"hsv"|"hsl"|"default"
---@return Sprite|nil
local function readFile(importFilepath, colorMode, dithering, toGray)
    -- Check for invalid file extension.
    local filepathLower = string.lower(importFilepath)
    local fileSysTools = app.fs
    local fileExt = fileSysTools.fileExtension(filepathLower)
    local extIsPbm = fileExt == "pbm"
    local extIsPgm = fileExt == "pgm"
    local extIsPpm = fileExt == "ppm"
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

    local asciiFile, err = io.open(importFilepath, "r")
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
    local abs = math.abs
    local floor = math.floor
    local max = math.max
    local min = math.min
    local strgmatch = string.gmatch
    local strlower = string.lower
    local strsub = string.sub
    local strunpack = string.unpack

    ---@type string[]
    local comments = {}

    ---@type number[]
    local pxData = {}

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
    local linesItr = asciiFile:lines("L")
    for line in linesItr do
        local lenLine = #line
        charCount = charCount + lenLine
        if lenLine > 0 then
            local lc = strlower(line)
            local twoChars = strsub(lc, 1, 2)
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
                local whTokens = {}
                local lenWhTokens = 0
                for token in strgmatch(line, "%S+") do
                    lenWhTokens = lenWhTokens + 1
                    whTokens[lenWhTokens] = token
                end

                if lenWhTokens > 0 then
                    local wPrs = tonumber(whTokens[1], 10)
                    if wPrs then
                        spriteWidth = floor(abs(wPrs) + 0.5)
                        spriteHeight = spriteWidth
                    end
                end

                if lenWhTokens > 1 then
                    local hPrs = tonumber(whTokens[2], 10)
                    if hPrs then
                        spriteHeight = floor(abs(hPrs) + 0.5)
                    end
                end

                if lenWhTokens > 2 then
                    channelMaxFound = charCount
                    local channelMaxPrs = tonumber(whTokens[3], 10)
                    if channelMaxPrs then
                        channelMax = min(max(floor(abs(channelMaxPrs) + 0.5), 1), 255)
                        fromChnlMax = 255.0 / channelMax
                    end
                end
            elseif includesChnlMax and channelMaxFound <= 0 then
                channelMaxFound = charCount
                local channelMaxPrs = tonumber(lc, 10)
                if channelMaxPrs then
                    channelMax = min(max(floor(abs(channelMaxPrs) + 0.5), 1), 255)
                    fromChnlMax = 255.0 / channelMax
                end
            else
                if isBinary then break end
                for token in strgmatch(line, delimiter) do
                    local num = tonumber(token, 10)
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
            local charsPerRow = math.ceil(spriteWidth / 8)
            flatLen = charsPerRow * spriteHeight
        end
        local strideFlatLen = stride * flatLen

        local binFile, _ = io.open(importFilepath, "rb")
        if not binFile then return end
        local allChars = binFile:read("a")
        local dataBlock = strsub(allChars, -strideFlatLen)
        for token in strgmatch(dataBlock, ".") do
            local num = strunpack("B", token)
            -- print(strfmt("%02x", num))
            pxData[#pxData + 1] = num
        end
        binFile:close()
    end

    -- Create image and sprite specification.
    local clampedSpriteWidth = min(max(spriteWidth, 1), 65535)
    local clampedSpriteHeight = min(max(spriteHeight, 1), 65535)
    local spriteSpec = ImageSpec {
        width = clampedSpriteWidth,
        height = clampedSpriteHeight,
        colorMode = ColorMode.RGB,
        transparentColor = 0
    }
    spriteSpec.colorSpace = ColorSpace { sRGB = true }

    -- This precaution minimizes raising an Aseprite error that will
    -- halt the script.
    local spriteFlatLen = clampedSpriteHeight * clampedSpriteWidth
    local spriteStrideFlatLen = stride * spriteFlatLen
    while #pxData < spriteStrideFlatLen do pxData[#pxData + 1] = 0 end

    -- Write to image based on file type.
    local image = Image(spriteSpec)
    if isBinPbm then
        local charsPerRow = math.ceil(spriteWidth / 8)
        local pxItr = image:pixels()
        for pixel in pxItr do
            local xSprite = pixel.x
            local ySprite = pixel.y

            local xChar = xSprite // 8
            local xBit = xSprite % 8

            local j = xChar + charsPerRow * ySprite
            local char = pxData[1 + j]
            local shift = 7 - xBit
            local bit = (char >> shift) & 1

            if bit == 0 then
                pixel(0xffffffff)
            else
                pixel(0xff000000)
            end
        end
    elseif channels3 then
        local i = 0
        local pxItr = image:pixels()
        for pixel in pxItr do
            local k = i * 3
            local r = floor(pxData[1 + k] * fromChnlMax + 0.5)
            local g = floor(pxData[2 + k] * fromChnlMax + 0.5)
            local b = floor(pxData[3 + k] * fromChnlMax + 0.5)
            pixel(0xff000000 | b << 0x10 | g << 0x08 | r)
            i = i + 1
        end
    else
        local i = 0
        local pxItr = image:pixels()
        for pixel in pxItr do
            i = i + 1
            local u = pxData[i]
            local v = floor(u * fromChnlMax + 0.5)
            if invert then v = 255 ~ v end
            pixel(0xff000000 | v << 0x10 | v << 0x08 | v)
        end
    end

    -- Create the sprite and assign the image to the sprite's cel.
    local sprite = Sprite(spriteSpec)
    sprite.cels[1].image = image

    -- Name the sprite after the file name.
    sprite.filename = fileSysTools.fileName(importFilepath)

    -- Set the palette.
    if extIsPbm then
        local palette = sprite.palettes[1]
        app.transaction(function()
            palette:resize(3)
            palette:setColor(0, Color { r = 0, g = 0, b = 0, a = 0 })
            palette:setColor(1, Color { r = 0, g = 0, b = 0, a = 255 })
            palette:setColor(2, Color { r = 255, g = 255, b = 255, a = 255 })
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
    local docPrefs = app.preferences.document(sprite)
    local onionSkinPrefs = docPrefs.onionskin
    onionSkinPrefs.loop_tag = false

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
    local fileSysTools = app.fs
    local fileExt = fileSysTools.fileExtension(exportFilepath)
    local filePathAndTitle = string.gsub(
        fileSysTools.filePathAndTitle(exportFilepath), "\\", "\\\\")

    local fileExtLower = string.lower(fileExt)
    local extIsPbm = fileExtLower == "pbm"
    local extIsPgm = fileExtLower == "pgm"
    local extIsPpm = fileExtLower == "ppm"

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
    local offTok = "1"
    local onTok = "0"

    -- Unpack sprite data.
    local palettes = activeSprite.palettes
    local spriteSpec = activeSprite.spec
    local wSprite = spriteSpec.width
    local hSprite = spriteSpec.height
    local colorMode = spriteSpec.colorMode

    -- Process color mode.
    local cmIsRgb = colorMode == ColorMode.RGB
    local cmIsGry = colorMode == ColorMode.GRAY
    local cmIsIdx = colorMode == ColorMode.INDEXED

    -- Process mode.
    local fmtIsBinary = writeMode == "BINARY"
    local fmtIsAscii = writeMode == "ASCII"

    -- Process channel max.
    local chnlMaxVerif = math.min(math.max(channelMax, 1), 255)
    local toChnlMax = chnlMaxVerif / 255.0
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
        local pxRatio = activeSprite.pixelRatio
        local pxw = math.max(1, math.abs(pxRatio.width))
        local pxh = math.max(1, math.abs(pxRatio.height))
        wScale = wScale * pxw
        hScale = hScale * pxh
    end
    local useResize = wScale ~= 1 or hScale ~= 1
    local wSpriteScld = math.min(wSprite * wScale, 65535)
    local hSpriteScld = math.min(hSprite * hScale, 65535)
    local imageSizeStr = string.format(
        "%d %d",
        wSpriteScld, hSpriteScld)

    -- Supplied to image pixel method when looping
    -- by pixel row.
    local rowRect = Rectangle(0, 0, wSpriteScld, 1)

    -- Cache global methods to local.
    local floor = math.floor
    local ceil = math.ceil
    local strfmt = string.format
    local strpack = string.pack
    local strsub = string.sub
    local strgsub = string.gsub
    local tconcat = table.concat
    local tinsert = table.insert

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
                    local c = p:getColor(h)
                    return strfmt(rgbFrmtrStr,
                        strpack("B", floor(c.red * toChnlMax + 0.5)),
                        strpack("B", floor(c.green * toChnlMax + 0.5)),
                        strpack("B", floor(c.blue * toChnlMax + 0.5)))
                end
            else
                writePixel = function(h, p)
                    local c = p:getColor(h)
                    return strfmt(rgbFrmtrStr,
                        floor(c.red * toChnlMax + 0.5),
                        floor(c.green * toChnlMax + 0.5),
                        floor(c.blue * toChnlMax + 0.5))
                end
            end
        elseif cmIsGry then
            if fmtIsBinary then
                writePixel = function(h)
                    local vc = strpack("B", floor(
                        (h & 0xff) * toChnlMax + 0.5))
                    return strfmt(rgbFrmtrStr, vc, vc, vc)
                end
            else
                writePixel = function(h)
                    local v = floor((h & 0xff) * toChnlMax + 0.5)
                    return strfmt(rgbFrmtrStr, v, v, v)
                end
            end
        else
            -- Default to RGB color mode.
            if fmtIsBinary then
                writePixel = function(h)
                    return strfmt(rgbFrmtrStr,
                        strpack("B", floor((h & 0xff) * toChnlMax + 0.5)),
                        strpack("B", floor((h >> 0x08 & 0xff) * toChnlMax + 0.5)),
                        strpack("B", floor((h >> 0x10 & 0xff) * toChnlMax + 0.5)))
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
                    local c = p:getColor(h)
                    return strpack("B", floor(lum(
                        c.red, c.green, c.blue) * toChnlMax + 0.5))
                end
            else
                writePixel = function(h, p)
                    local c = p:getColor(h)
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
                local c = p:getColor(h)
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
    local hexToStr = {}

    local lenFrIdcs = #frIdcs
    local h = 0
    while h < lenFrIdcs do
        h = h + 1
        local frIdx = frIdcs[h]

        -- In rare cases, e.g., a sprite opened from a sequence of indexed
        -- color mode files, there may be multiple palettes in the sprite.
        local paletteIdx = frIdx
        local lenPalettes = #palettes
        if paletteIdx > lenPalettes then paletteIdx = 1 end
        local palette = palettes[paletteIdx]

        -- Blit the sprite composite onto a new image.
        local trgImage = Image(spriteSpec)
        trgImage:drawSprite(activeSprite, frIdx)
        local trgPxItr = trgImage:pixels()

        -- Convert pixels to strings.
        for pixel in trgPxItr do
            local hex = pixel()
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
        local rowStrs = {}
        local j = 0
        while j < hSpriteScld do
            ---@type string[]
            local colStrs = {}
            rowRect.y = j
            local rowItr = trgImage:pixels(rowRect)
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

        local file, err = io.open(frFilePath, writerType)
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
            local charStrs = {}
            local lenRows = #rowStrs
            local k = 0
            while k < lenRows do
                k = k + 1
                local rowStr = rowStrs[k]
                local lenRowStr = #rowStr
                local lenRowChars = ceil(lenRowStr / 8)

                local m = 0
                while m < lenRowChars do
                    local idxOrig = 1 + m * 8
                    local idxDest = idxOrig + 7
                    local strSeg = strsub(rowStr, idxOrig, idxDest)
                    while #strSeg < 8 do strSeg = strSeg .. offTok end
                    local numSeg = tonumber(strSeg, 2)
                    charStrs[#charStrs + 1] = strpack("B", numSeg)
                    m = m + 1
                end
            end

            imgDataStr = tconcat(charStrs)
        else
            imgDataStr = tconcat(rowStrs, rowSep)
        end

        ---@type string[]
        local chunks = { headerStr, imageSizeStr, imgDataStr }
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

---@param str string
---@param alt boolean
---@return boolean
local function parseCliBool(str, alt)
    if str and #str > 0 then
        local strLwr = str.lower(str)
        if strLwr == "t" or strLwr == "true" or strLwr == "1" then
            return true
        elseif strLwr == "f" or strLwr == "false" or strLwr == "0" then
            return false
        end
        return alt
    end
    return alt
end

---@param str string
---@param lb integer
---@param ub integer
---@param alt integer
---@param base integer
---@return integer
local function parseCliUint(str, lb, ub, alt, base)
    if str and #str > 0 then
        local num = tonumber(str, base)
        if num then
            return math.min(math.max(math.floor(math.abs(num) + 0.5), lb), ub)
        end
        return alt
    end
    return alt
end

if not uiAvailable then
    local params = app.params
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

    local readFilePath = params["readFile"] or params["file"]
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
        local ditherRequest = params["dithering"]
        if ditherRequest and #ditherRequest > 0 then
            dithering = string.lower(ditherRequest)
        end

        local toGray = "default"
        local toGrayRequest = params["toGray"]
        if toGrayRequest and #toGrayRequest > 0 then
            toGray = string.lower(toGrayRequest)
        end

        local sprite = readFile(readFilePath, colorMode, dithering, toGray)
        if sprite then
            sprite:saveAs(writeFilePath)
            print(string.format("Wrote file to %s .",
                string.gsub(writeFilePath, "\\+", "\\")))
        else
            print(string.format("Error: Sprite %s could not be saved.",
                string.gsub(writeFilePath, "\\+", "\\")))
        end
    elseif action == "EXPORT" then
        local readSprite = Sprite { fromFile = readFilePath }
        if not readSprite then
            print("Error: File could not be loaded to sprite.")
            return
        end

        ---@type integer[]
        local frIdcs = {}
        local framesRequest = params["frames"]
        if framesRequest and #framesRequest > 0 then
            framesRequest = string.upper(framesRequest)
            local numFrames = #readSprite.frames
            if framesRequest == "ALL" then
                local i = 0
                while i < numFrames do
                    i = i + 1
                    frIdcs[i] = i
                end
            else
                frIdcs = parseRangeString(framesRequest, numFrames, 0)
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

        local channelMax = parseCliUint(params["channelMax"], 1, 255,
            defaults.channelMax, 10)
        local pivot = parseCliUint(params["pivot"], 1, 255, defaults.pivot, 10)
        local scale = parseCliUint(params["scale"], 1, 10, defaults.scale, 10)
        local usePixelAspect = parseCliBool(params["usePixelAspect"],
            defaults.usePixelAspect)

        writeFile(writeFilePath, readSprite, frIdcs, writeMode, channelMax,
            pivot, scale, usePixelAspect)
    else
        print("Error: Action was not recognized.")
    end

    return
end

local dlg = Dialog { title = "PNM Import Export" }

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
    id = "import",
    text = "&IMPORT",
    focus = false,
    onclick = function()
        -- Check for invalid file path.
        local args = dlg.data
        local importFilepath = args.importFilepath --[[@as string]]
        if (not importFilepath) or #importFilepath < 1 then
            app.alert {
                title = "Error",
                text = "Empty file path."
            }
            return
        end

        -- Preserve fore- and background colors.
        local fgc = app.fgColor
        app.fgColor = Color {
            r = fgc.red,
            g = fgc.green,
            b = fgc.blue,
            a = fgc.alpha
        }

        app.command.SwitchColors()
        local bgc = app.fgColor
        app.fgColor = Color {
            r = bgc.red,
            g = bgc.green,
            b = bgc.blue,
            a = bgc.alpha
        }
        app.command.SwitchColors()

        local colorMode = args.colorMode or defaults.colorMode --[[@as string]]
        local sprite = readFile(importFilepath, colorMode, "none", "default")

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
    id = "export",
    text = "&EXPORT",
    focus = false,
    onclick = function()
        ---@diagnostic disable-next-line: deprecated
        local activeSprite = app.activeSprite
        if not activeSprite then
            app.alert {
                title = "Error",
                text = "There is no active sprite."
            }
            return
        end

        ---@diagnostic disable-next-line: deprecated
        local activeFrame = app.activeFrame
        if not activeFrame then
            app.alert {
                title = "Error",
                text = "There is no active frame."
            }
            return
        end

        -- Check for invalid file path.
        local args = dlg.data
        local exportFilepath = args.exportFilepath --[[@as string]]
        if (not exportFilepath) or #exportFilepath < 1 then
            app.alert {
                title = "Error",
                text = "Empty file path."
            }
            return
        end

        -- Unpack other arguments.
        local writeMode = args.writeMode
            or defaults.writeMode --[[@as string]]
        local channelMax = args.channelMax
            or defaults.channelMax --[[@as integer]]
        local pivot = args.pivot
            or defaults.pivot --[[@as integer]]
        local scale = args.scale
            or defaults.scale --[[@as integer]]
        local usePixelAspect = args.usePixelAspect --[[@as boolean]]

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

dlg:show { wait = false }