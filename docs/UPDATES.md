# Updates: Liberator, the kit, and macOS itself

Three things update separately. Do not mix them up.

## 1. The Liberator app

The app checks `https://api.github.com/repos/nullmoth/liberator/releases` (the release list, newest 30), takes the newest
release whose tag looks like `vX.Y.Z` or `vX.Y.Z-beta.N` and that is not a draft, and offers it when its
`Liberator-Mac-<version>.zip` is newer than the running app. While every release of the product is a beta
(`UpdateChannel.betaProduct`), pre-releases are offered to everyone; the first full release turns that off, and
pre-releases go back to the opt-in early-updates switch.

A package is installed only when:

- its SHA-256 is listed in the release's `SHA256SUMS.txt`, and
- a `<file>.bsig` signature published beside it verifies against the release key compiled into the app, for this product,
  this version and these exact bytes.

`/releases/latest` is not used: GitHub never returns a pre-release there, so a product whose releases are all betas
would never find its next one.

An app older than this change (Beta 2 and earlier) asks `nullmoth/nvidia-macos-driver` at `/releases/latest` and expects
`nullmoth-nvidia-<n>.tar.gz`, `SHA256SUMS.txt`, `Liberator-Mac-<n>.zip` and the `.bsig` files in that one release. It
cannot find a pre-release on `nullmoth/liberator`; it is updated by a download, or by a full release on the repository it
reads.

## 2. The kit (macOS 27 support files)

The kit is pinned to one macOS 27 build: 27.2, build 26B123. The kernel collections are bit-exact results of that build's
kernel and kexts plus Liberator's changes, the system package's route list is `routes-26B123.txt`, and the kernel patches
match that kernel's bytes. Each part refuses a different build:

- the lay-down script refuses any restore image that is not 26B123;
- the system installer refuses a volume whose `ProductBuildVersion` differs from the one in the kit's `BUILT-ON.txt`;
- the driver installer refuses any build but 26B123.

A new Liberator release carries a new kit. On a Mac already on macOS 27, Install in the app gets this release's kit, runs
its system and driver installers on the running macOS (the driver installer also turns the previous kit's boot and system
kernel collections into this kit's with two small deltas, checked against their pins), and renews the startup files.
Everything replaced is kept in /Library/NullMoth/backups and EFI/NullMoth-backups, and the app names those folders.

## 3. macOS 27 itself (Apple's updates: 27.2.x, 27.3)

Apple's update is not something Liberator can take over. A newer build changes the kernel, the kexts and the system
files that the collections and patches were made from. Installing it on a Liberator machine would replace the system
volume with files the kit does not match and the Mac would not start from the kernel collections that were made for
26B123.

What Liberator does:

- Apple's own Software Update on the macOS 27 volume is set to check, but not to download or install macOS updates on its
  own (`kit/system/hold/com.apple.SoftwareUpdate.plist`, put in place by the system installer, kept with the original so
  uninstall puts the owner's setting back). Security data and configuration data updates stay on.
- The kit installers refuse a different build rather than applying 26B123 files to it.
- A Mac's macOS 26 (or 15) is untouched: its updates are Apple's, and the macOS 27 volumes sit beside it.

What the owner does when Apple ships a newer 27 build:

1. Do not choose the update in System Settings on the macOS 27 volume.
2. Wait for a Liberator release whose kit names the new build.
3. Install that release, then run Golden Gate again; it lays down the new build beside the old one, or on a Mac that
   already has macOS 27 renews the startup files and packages from the new kit.

An update taken anyway: the Mac may not reach the desktop from the macOS 27 startup files. Start macOS 26 from the
OpenCore picker (Option key / the boot menu) and use Cancel Golden Gate or Remove macOS 27 in the app.

Not covered: the lay-down for a new build needs a new kit (new delta files and route list for that build); there is no
automatic way to carry the old collections to a new build.
