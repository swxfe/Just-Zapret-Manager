#!/bin/sh
set -eu
ZM_HOME=$(CDPATH='' cd -P "$(dirname "$0")/.." && pwd)
export ZM_HOME
exec ucode -S -L "$ZM_HOME/src/lib" "$ZM_HOME/tools/bundle.uc"
