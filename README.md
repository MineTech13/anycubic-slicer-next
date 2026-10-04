# Anycubic Slicer Next — AppImage & Flatpak

Unofficial, **fully automated** AppImage and Flatpak builds of [Anycubic Slicer Next](https://www.anycubic.com/pages/anycubic-slicer-next) for Linux, repackaged from Anycubic's official Ubuntu 24.04 `.deb`.

## Install

### Flatpak (recommended)

```bash
flatpak remote-add --user --if-not-exists anycubic-slicer https://minetech13.github.io/anycubic-slicer-next/anycubic-slicer.flatpakrepo
flatpak install --user anycubic-slicer com.anycubic.AnycubicSlicer
```

Or use the one-click install on the [Flatpak page](https://minetech13.github.io/anycubic-slicer-next/), or download the single-file `.flatpak` bundle from the [latest release](../../releases/latest). Every route updates through `flatpak update`, GNOME Software or Discover. The GNOME runtime comes from Flathub, so it works on any distro, including older ones the AppImage can't run on.

Coming from another Anycubic Slicer Flatpak (e.g. develonrails' bundle)? Run `flatpak uninstall com.anycubic.AnycubicSlicer` first. Your settings stay.

### AppImage

```bash
chmod +x AnycubicSlicer-*-x86_64.AppImage
./AnycubicSlicer-*-x86_64.AppImage
```

Download it from the [latest release](../../releases/latest). Releases carry update information, so [Gear Lever](https://flathub.org/apps/it.mijorus.gearlever), AppImageLauncher or AppImageUpdate can update in place.

## How it works

```
every 6h ─▶ check ─▶ build AppImage ─▶ test ─┬─▶ publish release ─▶ deploy Flatpak repo (Pages)
                    └▶ build Flatpak ──▶ test ─┘
```

| Stage | What happens |
|---|---|
| **check** | Reads Anycubic's apt index (`cdn-universe-slicer.anycubic.com/prod/dists/noble/main/binary-amd64/Packages`) and looks for a release whose notes contain that `.deb`'s SHA256. If there is none, it builds. |
| **build** | Downloads the `.deb`, **verifies the SHA256** from the apt index, extracts it, reads the real app version from `resources/build-version.txt` (the deb version is different, e.g. deb `2.0.06` = app `2.0.0.5`), assembles the AppDir and packs it with the current [appimagetool](https://github.com/AppImage/appimagetool). Outputs: `.AppImage`, `.zsync`, `.sha256`. The Flatpak is built from **the same `.deb`** with `flatpak-builder` on the GNOME 51 runtime into a signed OSTree repo (branch `stable`), plus a `.flatpak` bundle. |
| **test** | On a clean Ubuntu 24.04 runner: checks the AppImage format and contents, validates the desktop and AppStream files, confirms every shared library resolves, then launches the app headless under Xvfb for 60 s. It must not crash and the bundled fonts must load. The Flatpak is **installed from the built repo** the way users install it, then gets the same checks plus a library check inside the runtime. |
| **publish** | Creates the GitHub release `v<version>` (AppImage + Flatpak bundle), marks it as latest, then deploys the Flatpak repo and [landing page](https://minetech13.github.io/anycubic-slicer-next/) to GitHub Pages. Nothing is published if any test fails. |

Workflows:
- [`update.yml`](.github/workflows/update.yml): scheduled pipeline. Run it manually with **force** to rebuild the current version.
- [`ci.yml`](.github/workflows/ci.yml): shellcheck, actionlint, build and test on every push and PR. Never publishes.
- [`build-test.yml`](.github/workflows/build-test.yml): the shared build and test jobs.

A scheduled run also re-enables its own workflow, so GitHub's 60-day inactivity auto-disable doesn't stop the automation.

The Flatpak repo on GitHub Pages is rebuilt on every release and only contains the current version, which is all `flatpak update` needs. It is deployed straight from the workflow, so nothing is stored in git and the repo doesn't grow.

### Setup after forking or creating the repo
1. Push to GitHub.
2. **Settings → Actions → General → Workflow permissions:** make sure workflows are allowed to run. The jobs request the permissions they need themselves.
3. **Flatpak signing key** (one time). Generate a key without a passphrase in a throwaway directory:
   ```bash
   mkdir -m 700 /tmp/acs-key
   gpg --homedir /tmp/acs-key --batch --passphrase '' --quick-gen-key "Anycubic Slicer Next Flatpak <noreply@github.com>" ed25519 sign never
   ```
   Print the private key and paste it into **Settings → Secrets and variables → Actions → New repository secret** named `FLATPAK_GPG_KEY`:
   ```bash
   gpg --homedir /tmp/acs-key --armor --export-secret-keys
   ```
   Keep a backup somewhere safe. If the key changes, installed users have to re-add the remote. Then `rm -rf /tmp/acs-key`.
4. **Settings → Pages → Build and deployment → Source: GitHub Actions.**
5. **Actions → Check for updates & release → Run workflow** (tick **force** if the current version is already released) to publish right away.

## Build locally

Requirements: `bash`, `curl`, `ar`/`tar` (or `dpkg-deb`), about 1 GB of free disk space.

```bash
scripts/check-upstream.sh                 # show what's current upstream
scripts/build-appimage.sh                 # download, verify, build → dist/
scripts/build-appimage.sh --deb some.deb  # build from a local .deb
scripts/test-appimage.sh dist/*.AppImage  # smoke tests (launch test needs xvfb-run)

scripts/build-flatpak.sh                  # needs flatpak + flatpak-builder → dist/*.flatpak, build/site/
scripts/test-flatpak.sh build/site/repo   # installs from the local repo and smoke-tests it
```

`REGION=china` uses Anycubic's China CDN.

## Requirements

**Flatpak:** just Flatpak. Everything else comes from the GNOME runtime.

**AppImage:** the AppImage bundles Anycubic's own libraries. **GTK 3, WebKit2GTK 4.1 and GStreamer come from your system** (same as upstream's `.deb`):

- glibc **2.38+** (Ubuntu 24.04+, Fedora 39+, Debian 13+, Arch/Manjaro/CachyOS, …)
- `webkit2gtk-4.1` (Arch: `webkit2gtk-4.1`, Debian/Ubuntu: `libwebkit2gtk-4.1-0`, Fedora: `webkit2gtk4.1`)
- `gtk3`, `glu`, `gstreamer` + `gst-libav`

FUSE: new AppImages use the static type-2 runtime and **don't need `libfuse2`**. Without FUSE at all (containers), run with `--appimage-extract-and-run`.

## Troubleshooting

The launchers set a few workarounds. Every one is **overridable**: set the variable yourself and it's left alone. For the Flatpak, pass variables with `flatpak run --env=NAME=value com.anycubic.AnycubicSlicer`, or permanently with `flatpak override --user --env=NAME=value com.anycubic.AnycubicSlicer`.

| Symptom | Try |
|---|---|
| Blank **Workbench** / web pages | Default `WEBKIT_DISABLE_DMABUF_RENDERER=1` is already set. Also try `ANYCUBIC_SAFE_GFX=1 ./AnycubicSlicer…` or `WEBKIT_DISABLE_COMPOSITING_MODE=1`. |
| No **3D view** on NVIDIA | The launcher no longer forces Mesa's EGL vendor on NVIDIA systems (the old AppImages did, which broke NVIDIA EGL). On Wayland with driver > 555 it switches to Zink; turn that off with `ZINK_DISABLE_OVERRIDE=1` or force it with `ZINK_FORCE_OVERRIDE=1`. X11 session: try `GDK_BACKEND=x11`. |
| `error while loading shared libraries: libwebkit2gtk-4.1.so.0` | Install WebKit2GTK 4.1 (see Requirements). On NixOS the AppImage needs an FHS environment that provides webkitgtk 4.1. |
| `GLIBC_2.38 not found` | Your distro is too old for Anycubic's binary. |
| `dlopen(): error loading libfuse.so.2` | You have an old AppImage from elsewhere; use a release from this repo, or add `--appimage-extract-and-run`. |
| Crash with odd locales | `LC_ALL=C` is forced by default; `ANYCUBIC_KEEP_LOCALE=1` disables that. |

Please include the terminal output when opening an issue (Flatpak: `flatpak run com.anycubic.AnycubicSlicer`).

**Flathub?** Not at the moment. Flathub needs a manual submission and review, the app ID would have to be one the maintainer controls (not `com.anycubic.*`), and the app ships Anycubic's prebuilt binaries instead of being built from source. The self-hosted repo above gives the same `flatpak update` experience.

## Credits

Based on the manual work of [develonrails/anycubic-slicer-next](https://github.com/develonrails/anycubic-slicer-next) and [thecalamityjoe87/anycubic-slicer-next-packages](https://github.com/thecalamityjoe87/anycubic-slicer-next-packages); the launcher workarounds come from OrcaSlicer.

## Disclaimer

Not affiliated with or endorsed by Anycubic. The Flatpak uses the `com.anycubic.AnycubicSlicer` ID so it replaces earlier community Flatpaks cleanly. Anycubic Slicer Next is © Anycubic; the scripts in this repository are MIT licensed (see [LICENSE](LICENSE)).
