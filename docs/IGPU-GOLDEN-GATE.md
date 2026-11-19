# Built-in graphics (iGPU) on macOS 27 through Golden Gate

macOS 27 for Intel has no graphics drivers of its own. Golden Gate gives a machine without a supported NVIDIA card one
of two graphics paths, chosen from what the machine's own Tahoe already runs:

| path | what it is | which machines |
|---|---|---|
| **apple** | The graphics drivers this machine's Tahoe has loaded are copied from the machine itself and linked for macOS 27. OpenCore keeps injecting the plug-ins that let those drivers take the GPU (WhateverGreen, WhateverXe, NootedRed). Nothing Apple-built is shipped in the kit. | Real Macs (since Beta 3) and, from Beta 4, PCs whose Tahoe runs the iGPU on Apple's driver |
| **test** | NullMoth's own AMD/Intel driver (NMXGPU) built for macOS 27, framebuffer first, Metal accelerator as a second step | Any other AMD or Intel GPU |

A machine with a supported NVIDIA card always takes the NVIDIA path. A machine whose Tahoe runs its iGPU on Apple's
driver is offered the apple path before the test path. Every iGPU path is untried on real hardware so far: the start
report says where a first start ended.

The rule for the apple path is simple: **if Tahoe accelerates this iGPU on this machine, Golden Gate carries that
driver to macOS 27.** So getting the iGPU working in Tahoe first, with the routes below, is how a machine gets it on
macOS 27.

## Intel

| generation | example IDs | Tahoe route | Golden Gate path |
|---|---|---|---|
| Ivy Bridge, Haswell, Broadwell (HD 4000 to 6200) | 0166, 0412, 0D26, 1626 | OpenCore Legacy Patcher root patches (3.0 added Tahoe; check its notes for your GPU) | apple, when the root patch is applied in Tahoe |
| Skylake (HD 5xx, Iris 5xx) | 1912, 191B, 1926 | WhateverGreen, spoofed as Kaby Lake | apple |
| Kaby Lake, Amber Lake, Whiskey Lake, Coffee Lake, Comet Lake (HD/UHD 6xx, Iris Plus 6xx) | 5916, 591B, 3E92, 3E9B, 9BC5 | Apple's own drivers in Tahoe, with WhateverGreen | apple |
| Ice Lake (Iris Plus G4/G7) | 8A52, 8A5A | Apple's own drivers in Tahoe, with WhateverGreen | apple |
| Tiger Lake, Alder Lake, Raptor Lake (Iris Xe, UHD Xe) | 9A49, 46A6, A7A0 | WhateverXe and its forks (table below) | apple, when WhateverXe runs it in Tahoe; otherwise test |
| Meteor Lake, Arrow Lake (Xe-LPG) | 7D45, 7D55, 7D51, 7D67 | Own-stack community drivers (table below) | test |
| Lunar Lake, Panther Lake (Xe2, Xe3) | 64A0, B080 | none working on bare metal yet | test |

## AMD

| generation | example IDs | Tahoe route | Golden Gate path |
|---|---|---|---|
| Vega APUs (Raven, Picasso, Renoir, Cezanne, Lucienne, Barcelo) | 15D8, 1636, 1638 | NootedRed (ChefKiss; install it yourself, see their licence) | apple, when NootedRed runs it in Tahoe (Golden Gate keeps it loading on macOS 27); otherwise test |
| Rembrandt 680M/660M | 1681 | RembrandtGfx (680M, one machine); PrimeBridge for display only beside NVIDIA | test |
| Phoenix/Hawk Point 780M | 15BF | nullarc (own stack) | test |
| Strix Point, Krackan (890M/880M), desktop Raphael/Granite Ridge 2-CU | 150E, 164E | none found | test |
| AMD discrete cards Apple shipped (Polaris, Vega, Navi) | 67DF, 731F | Apple's own drivers | apple |

## Community drivers for Tahoe (links; authors' own claims, not run by NullMoth)

Liberator never ships these. Where one is needed, download it from its author.

**Apple-driver reuse (carried to macOS 27 on the apple path once it runs in Tahoe):**
[b00t0x/WhateverXe](https://github.com/b00t0x/WhateverXe) with
[WhateverXe-Graphics](https://github.com/b00t0x/WhateverXe-Graphics) (Tiger Lake to Raptor Lake, the most mature) and
its machine forks:
[samranahmad09/WhateverXe-RaptorLakeP](https://github.com/samranahmad09/WhateverXe-RaptorLakeP),
[akiffurkan/WhateverXe-0xA7A0](https://github.com/akiffurkan/WhateverXe-0xA7A0),
[jkbuha/WhateverXe](https://github.com/jkbuha/WhateverXe),
[TigerShota/WhateverXe](https://github.com/TigerShota/WhateverXe),
[taingo936-ui/WhateverXe-AlderLakeS](https://github.com/taingo936-ui/WhateverXe-AlderLakeS),
[Elezorn/WhateverXe-TigerLakeH](https://github.com/Elezorn/WhateverXe-TigerLakeH),
[dristotle/WhateverXe-ASUS-F15-eDP](https://github.com/dristotle/WhateverXe-ASUS-F15-eDP),
[belugaa-01/WhateverXe-Patched](https://github.com/belugaa-01/WhateverXe-Patched),
[Minorli/WhateverXe-Next](https://github.com/Minorli/WhateverXe-Next),
[NebbaGiveUp/WhateverXe-AlderLake](https://github.com/NebbaGiveUp/WhateverXe-AlderLake) (46A6 eDP fixes),
[Pratyush1267/WhateverXe-RPLP-A7AB](https://github.com/Pratyush1267/WhateverXe-RPLP-A7AB),
[xiananliu/wex-modified-edition](https://github.com/xiananliu/wex-modified-edition) (Dynabook Tiger Lake builds),
[ManasSoni-2009/AlderXe](https://github.com/ManasSoni-2009/AlderXe).
Also [JulioNectar/Hackintosh-XPS13Plus-IrisXe-Tahoe](https://github.com/JulioNectar/Hackintosh-XPS13Plus-IrisXe-Tahoe)
and its ports [dssoftx X1 Carbon G11](https://github.com/dssoftx/Hackintosh-X1Carbon-G11-IrisXe-Tahoe) and
[mschiller890 X13 Yoga G2](https://github.com/mschiller890/Hackintosh-X13YogaG2-Iris),
[sgiammori/NootedGreen](https://github.com/sgiammori/NootedGreen) (work in progress),
[m4j2rpf766-crypto/IntelIGPU-Tahoe](https://github.com/m4j2rpf766-crypto/IntelIGPU-Tahoe).

**Own stack (Linux driver + Mesa + Metal over Vulkan):**
[watchthelight-labs/WTLIntelGfx](https://github.com/watchthelight-labs/WTLIntelGfx) (Arrow Lake, Meteor Lake),
[hepengfei00/XeMac](https://github.com/hepengfei00/XeMac) (Arrow Lake desktop, Core Ultra 7 265K),
[taqieallah/ThinkPad-E16-ArrowLake-macOS](https://github.com/taqieallah/ThinkPad-E16-ArrowLake-macOS),
[Mountainatic/ArrowWhatever](https://github.com/Mountainatic/ArrowWhatever),
[samwu07/xegfx-thinkbook14plus-mtl](https://github.com/samwu07/xegfx-thinkbook14plus-mtl),
[VedCloud/Meteor-Lake-Xe-LPG-Metal-Graphics](https://github.com/VedCloud/Meteor-Lake-Xe-LPG-Metal-Graphics),
[longurara/ArcMTL](https://github.com/longurara/ArcMTL),
[zep245/IrisXe-macos-driver](https://github.com/zep245/IrisXe-macos-driver) (Tiger Lake),
[pongpan-bk Core 5 120U driver](https://github.com/pongpan-bk/First-Custom-iGPU-Driver-for-Intel-Core-5-120U-on-macOS),
[luuumi-dev/nullarc](https://github.com/luuumi-dev/nullarc) (780M),
[OscarrWu/780m-hackintosh](https://github.com/OscarrWu/780m-hackintosh),
[wzh4869/Radeon-680M-Hackintosh](https://github.com/wzh4869/Radeon-680M-Hackintosh) (680M).

**Display bridges for laptops where the panel hangs off the iGPU and NVIDIA renders:**
[kitsuneislife/nmx-intel](https://github.com/kitsuneislife/nmx-intel),
[nvsaim/mothbridge-630](https://github.com/nvsaim/mothbridge-630),
[myvoow/PrimeBridge](https://github.com/myvoow/PrimeBridge).

## What is not done yet

- Intel Metal on macOS 27 through Tahoe's carried driver has not been started anywhere. AMD needed a shader-compiler
  hook on macOS 27 (the Mac Pro); Intel's compiler may need one too. The first start report will tell.
- The own-stack community drivers are not offered by Golden Gate itself; they need macOS 27 builds from their authors.
- Laptops with both an iGPU and an NVIDIA card take the NVIDIA path; using both at once is not built yet.
