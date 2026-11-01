#!/bin/sh
set -eu
case "$1" in -s) echo Linux;; -m) echo x86_64;; esac
