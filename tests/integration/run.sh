#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
. tests/setup/integration.sh

. tests/integration/cases/configuration.sh
. tests/integration/cases/hostlists-backups.sh
. tests/integration/cases/strategy-import.sh
. tests/integration/cases/source-refresh.sh
. tests/integration/cases/strategy-composition.sh
. tests/integration/cases/fakes.sh
. tests/integration/cases/assets.sh
. tests/integration/cases/applied-provenance.sh
. tests/integration/cases/devices-firewall.sh
. tests/integration/cases/benchmark.sh
. tests/integration/cases/bundle-installation.sh
. tests/integration/cases/manager-update.sh
. tests/integration/cases/scheduling-recovery.sh
. tests/integration/cases/installer.sh

printf '%s\n' 'integration: menu, UCI, rollback, sources, networking, readable bundle and installation OK'
