#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
ZM_HOME=$(pwd -P)
export ZM_HOME
exec ucode -S -L "$ZM_HOME/src/lib" tests/unit/run.uc
