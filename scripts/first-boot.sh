#!/bin/bash

(
    while true; do
        sleep 7200

        WINDOW=$(xdotool search --onlyvisible --class firefox 2>/dev/null | head -n 1)

        if [ -n "$WINDOW" ]; then
            xdotool key --window "$WINDOW" ctrl+r
        fi
    done
) >/tmp/firefox-refresh.log 2>&1 &
