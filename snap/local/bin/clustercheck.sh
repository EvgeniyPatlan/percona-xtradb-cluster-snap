#!/bin/bash

# Wrapper for Percona clustercheck. With no arguments it uses the
# credential-less "-" form with the defaults file written by the install
# hook (root over the snap's unix socket via auth_socket). Any arguments
# are passed straight through to the underlying script.
if [ "$#" -eq 0 ]; then
    exec "${SNAP}/usr/bin/clustercheck" - 0 /dev/null 1 "${SNAP_DATA}/etc/clustercheck.cnf"
fi
exec "${SNAP}/usr/bin/clustercheck" "$@"
