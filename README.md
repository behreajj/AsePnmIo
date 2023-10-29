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

Import and export ignore alpha *completely*. (For example, not even transparent red, `0x000000ff`, will be corrected to transparent black, `0x00000000`.) I recommend that you set an opaque background layer if you want to avoid issues.

The Netpbm file format supports neither layers nor frames. For that reason, a flattened copy of the sprite is made at the active frame.

When the color maximum is reduced, the script performs *no* dithering, unlike GIMP or Krita. Dither prior to export if you want the effect. 

Aseprite's definition of "luma" to convert to grayscale is used by both `pbm` and `pgm` exports. `pbm` grayscale values are then thresholded.

This dialog's parser expects the header, image dimensions, max channel and pixel data to be separated by line breaks. In other words, don't expect one liner files to parse correctly.

## Modification

To modify these scripts, see Aseprite's [API Reference](https://github.com/aseprite/api). There is also a [type definition](https://github.com/behreajj/aseprite-type-definition) for use with VS Code and the [Lua Language Server extension](https://github.com/LuaLS/lua-language-server).

## Issues

This script was tested in Aseprite version 1.2.40-x64 on Windows 10. Its user interface elements were tested with 100% screen scaling and 200% UI scaling. Please report issues in the issues section on Github. The script was compared with the import-export capabilities of [GIMP](https://www.gimp.org/) version 2.10.34 and [Krita](https://krita.org/) version 5.2.0. 