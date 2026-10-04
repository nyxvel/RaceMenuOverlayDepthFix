# RaceMenu Overlay Depth Fix

Fixes see-through or black patches on the skin under RaceMenu body overlays (blush, cum, tattoos...)
with Community Shaders, during and after physics-heavy scenes.

## The problem

RaceMenu body overlays are copies of the body mesh. They don't follow GT Softbody / FSMP physics:
where the soft body is pushed in, the overlay copy floats above the skin. RaceMenu's overlay templates
write depth and cast shadows, so wherever the copy floats, Community Shaders' lighting on the skin
behind it breaks.

## The fix

Transparent overlays shouldn't write depth or cast shadows. This patch clears those two shader flags
on RaceMenu's body, hands and feet overlay templates (`body_overlay.nif`, `hands_overlay.nif`,
`feet_overlay.nif` in `meshes\actors\character\character assets`):

| Flag | Original | Fixed |
|---|---|---|
| Shader flags 1: `Cast_Shadows` | `0x82601303` | `0x82601103` |
| Shader flags 2: `ZBuffer_Write` | `0x02008081` | `0x02008080` |

Nothing else in the meshes changes. The face overlay template is left alone.

## Building the patch

The meshes belong to RaceMenu, so this repository ships a patcher instead of the meshes. It reads
them from your own `RaceMenu.bsa`:

    powershell -ExecutionPolicy Bypass -File patch.ps1
    powershell -ExecutionPolicy Bypass -File patch.ps1 -Bsa "<path>\RaceMenu.bsa" -Output out

Without `-Bsa` it uses `RaceMenu.bsa` from the game's Data folder (Vortex deploys it there; with MO2,
pass the one in RaceMenu's mod folder). Zip the `out` folder and install it with your mod manager,
loaded after RaceMenu, or copy its `meshes` folder into Data.

Undo: remove the three meshes; RaceMenu falls back to the originals in its BSA.

Tested with RaceMenu 0.4.20 (Skyrim AE 1.6.1170). The patcher refuses meshes whose flags differ from
the table above.

## License

MIT (`LICENSE`). RaceMenu and its meshes belong to expired6978.
