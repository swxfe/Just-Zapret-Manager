# Source is compiled in memory. Separate environment values stay below Linux's
# per-argument limit; stdin remains available to the terminal menu and blockcheck.
# This value is ucode source passed as one interpreter argument.
# shellcheck disable=SC2089
JZM_BOOTSTRAP='let source = ""; for (let i = 1; i <= +getenv("JZM_PARTS"); i++) source += getenv("JZM_UCODE_" + i) + "\n"; loadstring(source, { strict_declarations: true })();'
ZM_HOME=${ZM_HOME:-/}
# shellcheck disable=SC2090
export JZM_BOOTSTRAP ZM_HOME
exec ucode -S -e "$JZM_BOOTSTRAP" -- "$@"
