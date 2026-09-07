#!/bin/bash
# ZCode launcher: runs the AppImage via FUSE mount.
# The container must run with --device /dev/fuse --cap-add SYS_ADMIN,
# otherwise the FUSE mount is not permitted and startup fails.
if [ ! -e /dev/fuse ]; then
    echo "WARNING: /dev/fuse is missing. Run the container with --device /dev/fuse --cap-add SYS_ADMIN." >&2
fi
exec /opt/ZCode.AppImage --no-sandbox "$@"
