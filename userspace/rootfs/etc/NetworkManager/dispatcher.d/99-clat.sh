#!/bin/bash
INTERFACE="$1"
ACTION="$2"

if [ "$INTERFACE" = "qmapmux0.0" ] || [ "$INTERFACE" = "qrtr0" ]; then
    case "$ACTION" in
        up)
            /usr/local/bin/clat-up.sh
            ;;
        down)
            /usr/local/bin/clat-down.sh
            ;;
    esac
fi
