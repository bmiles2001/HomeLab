#!/usr/bin/env bash
#
# Healthy = the loop in latest-save.sh completed a pass recently.
#
# This exists because of the specific failure this container was split out to
# make visible: a watcher running as a background job inside the web server can
# die silently while the web server stays up and healthy, and the only symptom
# is a map that quietly stops updating. Here, a stalled or crashed loop stops
# touching the heartbeat and shows up in `docker ps`.
#
# Note it deliberately does NOT check that latest.sav exists. An empty server
# with Auto Pause on writes no saves at all, and that is correct behaviour, not
# a fault. Whether the file is actually servable is the `saves` container's
# healthcheck to answer.
#
# Nothing in this repo restarts on unhealthy - this is a signal, and Beszel is
# what turns it into a notification.

set -euo pipefail

HEARTBEAT="${HEARTBEAT:-/tmp/heartbeat}"

# Three intervals. Two would flap on a slow pass over a large save directory.
MAX_AGE="${MAX_AGE:-180}"

[[ -f "$HEARTBEAT" ]] || exit 1
age=$(( $(date +%s) - $(stat -c %Y "$HEARTBEAT") ))
(( age >= 0 && age < MAX_AGE ))
