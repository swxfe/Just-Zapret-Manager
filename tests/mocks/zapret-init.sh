#!/bin/sh
set -eu
case "$1" in start|stop|restart|enable|disable) printf '%s\n' "$1" >> "$ZM_TEST_ROOT/service-actions";; esac
state=$ZM_TEST_ROOT/state
case "$1" in
    running) [ -f "$state" ];;
    enabled) [ -f "$ZM_TEST_ROOT/enabled" ];;
    start|restart)
        if [ -f "$ZM_TEST_ROOT/fail-restart" ]; then
            rm -f "$ZM_TEST_ROOT/fail-restart"
            exit 1
        fi
        : > "$state"
        ;;
    stop) rm -f "$state";;
    enable) : > "$ZM_TEST_ROOT/enabled";;
    disable) rm -f "$ZM_TEST_ROOT/enabled";;
    *) exit 2;;
esac
