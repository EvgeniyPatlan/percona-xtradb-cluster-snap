#!/bin/bash

set -eo pipefail  # Exit on error

# Galera Arbitrator daemon wrapper. Configuration comes from snap options:
#   snap set _NAME_ garbd.address=gcomm://<ip>:4567 garbd.group=<cluster-name>
#   snap set _NAME_ garbd.options="<extra galera options>"   (optional)
if [ -n "$SNAP" ]; then
    GARBD_ADDRESS="$(snapctl get garbd.address 2>/dev/null || true)"
    GARBD_GROUP="$(snapctl get garbd.group 2>/dev/null || true)"
    GARBD_OPTIONS="$(snapctl get garbd.options 2>/dev/null || true)"
fi

if [ -z "${GARBD_ADDRESS}" ] || [ -z "${GARBD_GROUP}" ]; then
    echo "Error: both garbd.address and garbd.group must be set:" >&2
    echo "  snap set _NAME_ garbd.address=gcomm://<ip>:4567 garbd.group=<cluster-name>" >&2
    exit 1
fi

GARBD_CMD=("${SNAP}/usr/bin/garbd" --address "${GARBD_ADDRESS}" --group "${GARBD_GROUP}")
if [ -n "${GARBD_OPTIONS}" ]; then
    GARBD_CMD+=(--options "${GARBD_OPTIONS}")
fi

# For security measures, daemons should not be run as sudo.
exec "${SNAP}/usr/bin/setpriv" \
    --clear-groups \
    --reuid snap_daemon \
    --regid snap_daemon \
    -- \
    "${GARBD_CMD[@]}"
