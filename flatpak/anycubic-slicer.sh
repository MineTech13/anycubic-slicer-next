#!/bin/sh
# Launcher for Anycubic Slicer Next inside the Flatpak sandbox.
#
# Every variable is only set when you have not set it already, so workarounds can be
# overridden, e.g.:
#   flatpak run --env=WEBKIT_DISABLE_DMABUF_RENDERER=0 com.anycubic.AnycubicSlicer
#
# Extra switches:
#   ANYCUBIC_SAFE_GFX=1     also disable WebKit compositing (blank Workbench pages)
#   ANYCUBIC_KEEP_LOCALE=1  do not force LC_ALL=C
# GPU drivers come from Flatpak's GL extensions; no Mesa/Zink juggling is needed here.

export LD_LIBRARY_PATH="/app/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export ANYCUBIC_RESOURCES_PATH="${ANYCUBIC_RESOURCES_PATH:-/app/resources}"

# The slicer segfaults when locale data is not as expected (workaround from OrcaSlicer).
if [ "${ANYCUBIC_KEEP_LOCALE:-0}" != "1" ]; then
  export LC_ALL=C
fi

# DMA-BUF renderer is the usual culprit for blank web views (Workbench, device pages).
export WEBKIT_DISABLE_DMABUF_RENDERER="${WEBKIT_DISABLE_DMABUF_RENDERER:-1}"
if [ "${ANYCUBIC_SAFE_GFX:-0}" = "1" ]; then
  export WEBKIT_DISABLE_COMPOSITING_MODE="${WEBKIT_DISABLE_COMPOSITING_MODE:-1}"
fi

# The app writes its settings below the config dir and aborts if that does not exist yet.
mkdir -p "${XDG_CONFIG_HOME:-$HOME/.config}" "$HOME/.config" 2>/dev/null

exec /app/bin/AnycubicSlicerNext "$@"
