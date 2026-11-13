#!/bin/bash
# SPDX-License-Identifier: MIT
INTERFACE="$1"
ACTION="$2"

if [ "$INTERFACE" = "qmapmux0.0" ] || [ "$INTERFACE" = "qrtr0" ]; then
    case "$ACTION" in
        up)
            /usr/lib/zflip3/clat-up
            ;;
        down)
            /usr/lib/zflip3/clat-down
            ;;
    esac
fi
