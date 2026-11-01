import { equal, rejects, count } from '../support/assertions.uc';
import { newer_version } from 'manager';
import { parse_packages, release_plan, release_compare, procd_running } from 'status';

export function run() {
    equal(newer_version('10.10.0', '10.9.9'), true, 'compare versions numerically');
    equal(newer_version('10.2.0', '10.2.0'), false, 'same version needs no update');
    equal(newer_version('9.99.9', '10.2.0'), false, 'never offer downgrade');
    rejects(() => newer_version('10.2.0;id', '10.2.0'), 'reject invalid update version');
    equal(parse_packages('Package: zapret\nVersion: 72.20260307-r1\nStatus: install ok installed\n\nPackage: luci-app-zapret\nVersion: 72.20260307-r1\nStatus: deinstall ok config-files\n', 'opkg'),
        { zapret: '72.20260307-r1' }, 'opkg removed packages are not installed');
    equal(parse_packages('P:zapret\nV:72.20260307-r1\n\nP:luci-app-zapret\nV:72.20260307-r1\n', 'apk'),
        { zapret: '72.20260307-r1', 'luci-app-zapret': '72.20260307-r1' }, 'read APK database versions');
    let max_version = sprintf('%0100d', 0);
    equal(parse_packages('P:zapret\nV:' + max_version + '\n', 'apk'), {zapret: max_version}, 'package version accepts 100 bytes');
    equal(parse_packages('P:zapret\nV:' + max_version + '0\n', 'apk'), {}, 'package version rejects 101 bytes');
    equal(release_plan({}, 'v72.20260307'), 'both', 'new installation includes LuCI');
    equal(release_plan({ zapret: '72.20260307-r1' }, 'v72.20260307'), 'luci', 'repair missing LuCI without reinstalling core');
    equal(release_plan({ zapret: '72.20260307-r1', 'luci-app-zapret': '72.20260307-r1' }, 'v72.20260307'),
        'none', 'skip installation when release is current');
    equal(release_plan({ zapret: '72.20250101-r1' }, 'v72.20260307'), 'both', 'update an older core with LuCI');
    equal(release_compare('72.20260307-r1', 'v72.20260307'), 0, 'compare package to release tag');
    rejects(() => release_plan({ zapret: '73.20270101-r1' }, 'v72.20260307'), 'never repair LuCI from an older incompatible release');
    equal(procd_running({ zapret: { instances: { nfqws: { running: true } } } }), true, 'procd running instance');
    equal(procd_running({ zapret: { instances: { nfqws: { running: false } } } }), false, 'procd stopped instance');
    equal(procd_running({}), false, 'procd missing service is stopped');
    rejects(() => procd_running(null), 'invalid procd response is not reported as stopped');
    equal(parse_packages('C:checksum\nP:irrelevant\nV:1\n\nC:checksum\nP:zapret\nV:72.20260307-r1\n', 'apk'),
        { zapret: '72.20260307-r1' }, 'APK package name need not be first field');

};
