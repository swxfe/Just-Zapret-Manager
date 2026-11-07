import { equal, rejects } from '../support/assertions.uc';
import { fake_slots, replace_fake, group_fakes } from 'fakes';
import { asset_destination, fake_filename } from 'assets';

export function run() {
    let path = '/opt/zapret/files/fake/tls.bin', next = '/opt/zapret/files/fake/other.bin';
    let body = '#v7\n--filter-tcp=443\n--dpi-desync-fake-tls=' + path + '\n--new\n' +
        '--filter-udp=443\n--dpi-desync-split-seqovl-pattern=' + path + '\n';
    let slots = fake_slots(body);
    equal(length(slots), 2, 'find payloads and patterns');
    equal(slots[0].section, 'v7', 'payload strategy label');
    equal(slots[1].profile, 2, 'profile for repeated path');
    let changed = fake_slots(replace_fake(body, '' + slots[0].line, path, next));
    equal(map(changed, (s) => s.path), [next, path], 'replace exactly one occurrence');
    equal(fake_slots('--filter-tcp=443 --dpi-desync-fake-tls=' + path)[0].path, path, 'one-line UCI strategy');
    equal(fake_slots(''), [], 'no strategy');
    equal(fake_slots('--dpi-desync-fake-tls=/opt/zapret/fakes/tls.bin')[0].path, '/opt/zapret/fakes/tls.bin', 'find isolated Flowseal payload');
    equal(fake_slots('--dpi-desync-fake-tls=/opt/zapret/fakes/tls.bin')[0].name, 'tls.bin', 'preserve isolated payload filename');
    equal(fake_slots(replace_fake(body, '' + slots[0].line, path, '/opt/zapret/fakes/other.bin'))[0].path, '/opt/zapret/fakes/other.bin', 'replace package payload with isolated Flowseal payload');
    equal(fake_slots('--dpi-desync-fake-tls=0x00\n'), [], 'inline fake stays inline');
    let grouped = fake_slots(body + '--new\n#Gv1\n--dpi-desync-fake-unknown-udp=' + path);
    equal(grouped[2].profile, 1, 'profile numbers restart for each strategy');
    equal(grouped[2].global_profile, 3, 'global nfqws profile stays available');
    let files = group_fakes(grouped);
    equal(length(files), 1, 'one file is listed once across parameters and strategies');
    equal(files[0].filename, 'tls.bin', 'group retains original filename');
    equal(files[0].sections, ['v7', 'Gv1'], 'strategy labels are ordered and deduplicated per file');
    equal(map(files[0].slots, (s) => [s.section, s.profile, s.line]),
        map(grouped, (s) => [s.section, s.profile, s.line]), 'group preserves exact replacement targets');
    equal(length(group_fakes([...slots, { ...slots[0], path: '/opt/zapret/fakes/tls.bin' }])),
        2, 'equal basenames at different paths stay separate');
    equal(group_fakes([]), [], 'empty fake list has no groups');
    let ctx = { assets: '/etc/zapret-manager/assets', base: '/opt/zapret', max_file_bytes: 1024 };
    let entry = { target: 'fake', path: 'fakes/test.bin', source: 'flowseal', name: 'test.bin', size: 8, sha256: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' };
    equal(asset_destination(ctx, entry), '/opt/zapret/fakes/test.bin', 'isolated fake path retains the original name');
    rejects(() => asset_destination(ctx, { ...entry, path: '../etc/network' }), 'archive traversal');
    rejects(() => asset_destination(ctx, { ...entry, source: 'other' }), 'only packaged sources');
    rejects(() => asset_destination(ctx, { ...entry, source: 'bol-van', path: 'fakes/bol-van/test.bin' }), 'foreign fake source is rejected');
    equal(asset_destination(ctx, { ...entry, target: 'catalog', name: 'manager.json', path: 'catalogs/manager.json' }), ctx.assets + '/catalogs/manager.json', 'Manager strategies are local assets');
    rejects(() => asset_destination(ctx, { ...entry, target: 'catalog', name: 'unknown.json', path: 'catalogs/unknown.json' }), 'unknown strategy catalog is rejected');
    rejects(() => asset_destination(ctx, { ...entry, size: 0 }), 'empty fake rejected at installation');
    rejects(() => asset_destination(ctx, { ...entry, size: 2048 }), 'asset size bound');
    rejects(() => asset_destination(ctx, { ...entry, sha256: 'bad' }), 'asset digest syntax');
    rejects(() => asset_destination(ctx, { ...entry, target: 'network' }), 'forbidden asset target');
    let resource = { ...entry, target: 'resource', name: 'exclude.txt', path: 'resources/exclude.txt' };
    equal(asset_destination(ctx, resource), ctx.assets + '/resources/exclude.txt', 'lists are local resources');
    rejects(() => asset_destination(ctx, { ...resource, name: 'network', path: '/etc/config/network' }), 'resource whitelist');
    rejects(() => asset_destination(ctx, { ...entry, target: 'default', path: 'defaults/test.bin' }), 'retired duplicate layout is rejected');
    rejects(() => replace_fake(body, '' + slots[0].line, next, path), 'stale selection');
    rejects(() => replace_fake(body, '0', path, next), 'cannot replace heading');
    rejects(() => replace_fake(body, '' + slots[0].line, path, '/etc/config/network'), 'forbidden replacement path');
    rejects(() => fake_filename('../bad.bin'), 'fake path traversal');
    rejects(() => fake_filename('bad.bin?x=1'), 'fake URL injection');
};
