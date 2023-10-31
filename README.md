# Aseprite PNM

![Screen Cap](screenCap.png)

This is a [PNM](https://en.wikipedia.org/wiki/Netpbm) import-export dialog for use with the [Aseprite](https://www.aseprite.org/) [scripting API](https://www.aseprite.org/docs/scripting/). The PNM family of image formats supported by this dialog are `pbm`, `pgm` and `ppm`.

- `ppm` files support up to 256-bit per red, green and blue color channels. Alpha is not included. The maximum per each channel can be adjusted, effectively allowing for a reduced bit-depth image. For example, a max of `7` would be `(1<<3)-1` or `(2^3)-1`.
- `pgm` files support up to 256-bit per gray channel. Alpha is not included. The maximum per channel can be adjusted.
- `pbm` files support either `1` or `0` per pixel. The format specifies that `1` is black while `0` is white. This dialog inverts this to match image conventions.

These three files can be formatted either as human-readable ASCII or as binary.

## Download

To download this script, click on the green Code button above, then select Download Zip. You can also click on the `netpbmio.lua` file. Beware that some browsers will append a `.txt` file format extension to script files on download. Aseprite will not recognize the script until this is removed and the original `.lua` extension is used. There can also be issues with copying and pasting. Be sure to click on the Raw file button; do not copy the formatted code.

## Usage

To use this script, open Aseprite. In the menu bar, go to `File > Scripts > Open Scripts Folder`. Move the Lua script into the folder that opens. Return to Aseprite; go to `File > Scripts > Rescan Scripts Folder` (the default hotkey is `F5`). The script should now be listed under `File > Scripts`. Select `netpbmio.lua` to launch the dialog.

If an error message in Aseprite's console appears, check if the script folder is on a file path that includes characters beyond [UTF-8](https://en.wikipedia.org/wiki/UTF-8), such as 'é' (e acute) or 'ö' (o umlaut).

A hot key can be assigned to the script by going to `Edit > Keyboard Shortcuts`. The search input box in the top left of the shortcuts dialog can be used to locate the script by its file name. The dialog can be closed with `Alt+C`. The import button can be activated with `Alt+I`; export, with `Alt+E`.

Import and export ignore alpha *completely*. For example transparent red, `0x000000ff`, will not be corrected to opaque black, `0xff000000`. I recommend that you set an opaque background layer if you want to avoid issues.

PNM file formats support neither layers nor frames. For that reason, a flattened copy of the sprite is made at the active frame (unless the script is called from the CLI, see below).

When the color maximum is reduced, the script performs *no* dithering, unlike GIMP or Krita. Dither prior to export if you want the effect. Channel contraction uses the formula `floor(value * (max / 255.0) + 0.5)`; expansion, `floor(value * (255.0 / max) + 0.5)`. This is equivalent to a signed, rather than an unsigned quantization. The difference can be illustrated with this [Desmos graph](https://www.desmos.com/calculator/8izpd3rfcj) or a comparison of gradients.

![Quantize Comparison](quantizeCompare.png)

Unsigned quantization is in the middle row; signed is on the bottom.

Aseprite's definition of "luma" to convert to grayscale is used by both `pbm` and `pgm` exports. For more info, I wrote a guide comparing grayscale conversion methods [here](https://steamcommunity.com/sharedfiles/filedetails/?id=3014911194). `pbm` grayscale values are then thresholded against a pivot, `128` by default. 

This script's parser expects the header, image dimensions, max channel and pixel data to be separated by line breaks. In other words, don't expect one liner files to parse correctly.

## Example

### PPM

Below is an example output for a 9 by 16 ppm file, upscaled to 90 by 160:

![Example 1](example1.png)

In a text editor, the ASCII version looks like this:

```
P3
9 16
255
220 058 058 182 037 079 151 028 090 137 036 105 132 038 109 137 036 105 151 028 090 182 037 079 220 058 058
142 033 100 104 047 120 081 064 143 057 078 153 045 082 155 057 078 153 081 064 143 104 047 120 142 033 100
081 064 143 000 094 156 000 109 156 000 118 156 000 122 155 000 118 156 000 109 156 000 094 156 081 064 143
000 103 156 000 126 155 000 143 149 000 152 133 000 154 126 000 152 133 000 143 149 000 126 155 000 103 156
000 129 154 000 152 133 042 171 096 115 190 069 138 196 059 115 190 069 042 171 096 000 152 133 000 129 154
000 149 140 065 178 089 166 207 048 213 219 027 227 220 025 213 219 027 166 207 048 065 178 089 000 149 140
000 157 107 151 201 054 227 220 025 255 199 017 255 179 018 255 199 017 227 220 025 151 201 054 000 157 107
042 171 096 181 212 041 254 217 023 252 151 028 238 103 044 252 151 028 254 217 023 181 212 041 042 171 096
042 171 096 181 212 041 254 217 023 252 151 028 238 103 044 252 151 028 254 217 023 181 212 041 042 171 096
000 157 107 151 201 054 227 220 025 255 199 017 255 179 018 255 199 017 227 220 025 151 201 054 000 157 107
000 149 140 065 178 089 166 207 048 213 219 027 227 220 025 213 219 027 166 207 048 065 178 089 000 149 140
000 129 154 000 152 133 042 171 096 115 190 069 138 196 059 115 190 069 042 171 096 000 152 133 000 129 154
000 103 156 000 126 155 000 143 149 000 152 133 000 154 126 000 152 133 000 143 149 000 126 155 000 103 156
081 064 143 000 094 156 000 109 156 000 118 156 000 122 155 000 118 156 000 109 156 000 094 156 081 064 143
142 033 100 104 047 120 081 064 143 057 078 153 045 082 155 057 078 153 081 064 143 104 047 120 142 033 100
220 058 058 182 037 079 151 028 090 137 036 105 132 038 109 137 036 105 151 028 090 182 037 079 220 058 058
```

In a hex editor, the binary version looks like this:

```
50 36 0A 39 20 31 36 0A 32 35 35 0A
DC 3A 3A B6 25 4F 97 1C 5A 89 24 69
84 26 6D 89 24 69 97 1C 5A B6 25 4F
DC 3A 3A 8E 21 64 68 2F 78 51 40 8F
39 4E 99 2D 52 9B 39 4E 99 51 40 8F
68 2F 78 8E 21 64 51 40 8F 00 5E 9C
00 6D 9C 00 76 9C 00 7A 9B 00 76 9C
00 6D 9C 00 5E 9C 51 40 8F 00 67 9C
00 7E 9B 00 8F 95 00 98 85 00 9A 7E
00 98 85 00 8F 95 00 7E 9B 00 67 9C
00 81 9A 00 98 85 2A AB 60 73 BE 45
8A C4 3B 73 BE 45 2A AB 60 00 98 85
00 81 9A 00 95 8C 41 B2 59 A6 CF 30
D5 DB 1B E3 DC 19 D5 DB 1B A6 CF 30
41 B2 59 00 95 8C 00 9D 6B 97 C9 36
E3 DC 19 FF C7 11 FF B3 12 FF C7 11
E3 DC 19 97 C9 36 00 9D 6B 2A AB 60
B5 D4 29 FE D9 17 FC 97 1C EE 67 2C
FC 97 1C FE D9 17 B5 D4 29 2A AB 60
2A AB 60 B5 D4 29 FE D9 17 FC 97 1C
EE 67 2C FC 97 1C FE D9 17 B5 D4 29
2A AB 60 00 9D 6B 97 C9 36 E3 DC 19
FF C7 11 FF B3 12 FF C7 11 E3 DC 19
97 C9 36 00 9D 6B 00 95 8C 41 B2 59
A6 CF 30 D5 DB 1B E3 DC 19 D5 DB 1B
A6 CF 30 41 B2 59 00 95 8C 00 81 9A
00 98 85 2A AB 60 73 BE 45 8A C4 3B
73 BE 45 2A AB 60 00 98 85 00 81 9A
00 67 9C 00 7E 9B 00 8F 95 00 98 85
00 9A 7E 00 98 85 00 8F 95 00 7E 9B
00 67 9C 51 40 8F 00 5E 9C 00 6D 9C
00 76 9C 00 7A 9B 00 76 9C 00 6D 9C
00 5E 9C 51 40 8F 8E 21 64 68 2F 78
51 40 8F 39 4E 99 2D 52 9B 39 4E 99
51 40 8F 68 2F 78 8E 21 64 DC 3A 3A
B6 25 4F 97 1C 5A 89 24 69 84 26 6D
89 24 69 97 1C 5A B6 25 4F DC 3A 3A
```

The pixel in the top left corner can be seen as `220` for the red channel, `58` for the green and `58` for the blue. Or, in hexadecimal: `0xDC`, `0x3A` and `0x3A`. The file header is still in human readable form: `0x50` `0x36` is `P3`, `0x39` `0x20` `0x31` `0x36` is `9 16` and `0x32` `0x35` `0x35` is `255`.

### PBM

Below is from the same source image as above, but exported as a pbm:

![Example 2](example2.png)

The ASCII version looks like this:

```
P1
9 16
1 1 1 1 1 1 1 1 1
1 1 1 1 1 1 1 1 1
1 1 1 1 1 1 1 1 1
1 1 1 1 1 1 1 1 1
1 1 0 0 0 0 0 1 1
1 0 0 0 0 0 0 0 1
1 0 0 0 0 0 0 0 1
0 0 0 0 1 0 0 0 0
0 0 0 0 1 0 0 0 0
1 0 0 0 0 0 0 0 1
1 0 0 0 0 0 0 0 1
1 1 0 0 0 0 0 1 1
1 1 1 1 1 1 1 1 1
1 1 1 1 1 1 1 1 1
1 1 1 1 1 1 1 1 1
1 1 1 1 1 1 1 1 1
```

The binary version looks like this:

```
50 34 0A 39 20 31 36 0A FF FF FF FF
FF FF FF FF C1 FF 80 FF 80 FF 08 7F
08 7F 80 FF 80 FF C1 FF FF FF FF FF
FF FF FF FF
```

Binary pbms pack 8 pixels of binary data into one byte, with extra padding depending on the image width.

## Command Line Interface

Due to the relative slowness of Lua scripts, I recommend using another graphics package to convert files to or from the PNM format in bulk. However, Aseprite does support calling scripts from the [command line](https://aseprite.org/docs/cli#script) (CLI). This script has been updated to utilize that feature.

The primary `-script-param` to call is `action`, which may be either `IMPORT` -- to convert from PNM -- or `EXPORT` -- to convert to PNM. The next important parameter is `readFile`, which should be assigned a file path. A separate `writeFile` path can be specified optionally. If omitted, the `writeFile` path will be given the `readFile` path with the extension changed. The extension will be `aseprite` for `IMPORT` or `ppm` for `EXPORT`.

For example,

```
aseprite -b -script-param readFile="path\\to\\pnm" -script-param action=IMPORT -script-param colorMode=INDEXED -script "path\\to\\lua"
```

and

```
aseprite -b -script-param readFile="path\\to\\img" -script-param writeFile="path\\to\\pnm" -script-param action=EXPORT -script-param writeMode=BINARY -script-param frames=all -script-param channelMax=7 -script-param scale=2 -script "path\\to\\lua"
```

One of the benefits of exporting via the CLI is that multiple frames can be exported. As seen above, the argument `all` is used. Alternatively, the string `1:3,7:9` uses a colon `:` to specify two ranges from 1 to 3 and from 7 to 9, separated by a comma, `,`.

## Modification

To modify these scripts, see Aseprite's [API Reference](https://github.com/aseprite/api). There is also a [type definition](https://github.com/behreajj/aseprite-type-definition) for use with VS Code and the [Lua Language Server extension](https://github.com/LuaLS/lua-language-server).

## Issues

This script was tested in Aseprite version 1.2.40-x64 on Windows 10. Its user interface elements were tested with 100% screen scaling and 200% UI scaling. Please report issues in the issues section on Github. The script was compared with the import-export capabilities of [GIMP](https://www.gimp.org/) version 2.10.34 and [Krita](https://krita.org/) version 5.2.0. 