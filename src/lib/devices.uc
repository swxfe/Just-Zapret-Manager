import { resource } from 'resources';
import * as fs from 'fs';
import { check, read } from 'common';

export function ipv4(value) {
    check(type(value) == 'string' && match(value, /^[0-9]{1,3}(\.[0-9]{1,3}){3}$/), 'неверный IPv4 адрес');
    let octets = split(value, '.');
    for (let part in octets) check(+part <= 255, 'октет IPv4 вне диапазона');
    return join('.', map(octets, (part) => '' + (+part)));
};

export function legacy_addresses(body) {
    body = trim(replace(body, /\\\r?\n/g, ' '));
    if (!length(body)) return [];
    let lines = split(body, '\n');
    if (length(lines) != 2) return null;
    let m = match(lines[0], /^EXCEPT_SRC='\{ ([0-9., ]+) \}'$/);
    if (!m || replace(trim(lines[1]), /[[:space:]]+/g, ' ') !=
        'nft insert rule inet zapret postrouting_hook index 0 ip saddr $EXCEPT_SRC meta mark set meta mark \\| 0x40000000') return null;
    let values = map(split(m[1], ','), (part) => ipv4(trim(part)));
    check(length(values) <= 256, 'слишком много старых исключений устройств');
    return values;
};

export function legacy_exclusions(ctx) {
    let path = ctx.base + '/init.d/openwrt/custom.d/20-script.sh';
    return fs.stat(path) ? legacy_addresses(read(path, 16384)) : null;
};

export function excluded(ctx) {
    let path = ctx.state + '/devices.txt', result = legacy_exclusions(ctx) || [];
    let body = fs.stat(path) ? read(path, 16384) : '';
    for (let line in split(body, '\n')) {
        line = trim(line);
        if (length(line)) {
            let ip = ipv4(line);
            if (index(result, ip) == -1) push(result, ip);
        }
    }
    check(length(result) <= 256, 'слишком много исключённых устройств');
    return result;
};

export function device_list(ctx) {
    let items = {}, path = ctx.root + '/tmp/dhcp.leases';
    if (fs.stat(path)) {
        for (let line in split(read(path, ctx.max_file_bytes), '\n')) {
            let fields = split(trim(line), /[[:space:]]+/);
            if (length(fields) < 4) continue;
            try {
                let ip = ipv4(fields[2]);
                items[ip] = { ip, name: fields[3] == '*' ? 'устройство' : replace(fields[3], /[^A-Za-z0-9_.:-]/g, '_') };
            }
            catch (e) { /* Incomplete DHCP rows do not become firewall rules. */ }
        }
    }
    for (let ip in excluded(ctx)) if (!exists(items, ip)) items[ip] = { ip, name: 'вне DHCP / offline' };
    return map(sort(keys(items)), (ip) => items[ip]);
};

export function exclusion_hook(ctx, addresses) {
    let cfg = json(resource(ctx.home, 'network.json'));
    for (let key in ['family', 'table', 'chain'])
        check(match(cfg[key], /^[A-Za-z_][A-Za-z0-9_]*$/), 'неверный параметр nft: ' + key);
    check(match(cfg.mark, /^0x[a-fA-F0-9]{1,8}$/), 'неверная метка nft');
    check(length(addresses) <= 256, 'слишком много исключений');
    addresses = map(addresses, (value) => ipv4(value));
    let rule = !length(addresses) ? '    exit 0\n' :
        '    jzm_chain=$(nft -a list chain ' + cfg.family + ' ' + cfg.table + ' ' + cfg.chain + ') || exit 1\n' +
        '    case "$jzm_chain" in *\'comment "jzm_devices"\'*) exit 0;; esac\n' +
        '    nft insert rule ' + cfg.family + ' ' + cfg.table + ' ' + cfg.chain +
        " index 0 ip saddr '{ " + join(', ', addresses) + " }' meta mark set meta mark \\| " + cfg.mark +
        ' comment \'"jzm_devices"\'\n';
    // custom_runner sources each file for daemon, firewall and flush callbacks.
    // Define the nft callback only; restore the caller's shell options after sourcing.
    return '#!/bin/sh\n# shellcheck disable=SC2329\njzm_exclusion_flags=$-\nset -eu\n' +
        'zapret_custom_firewall_nft() (\n    set -eu\n' + rule + ')\n' +
        'case "$jzm_exclusion_flags" in *e*) :;; *) set +e;; esac\n' +
        'case "$jzm_exclusion_flags" in *u*) :;; *) set +u;; esac\n' +
        'unset jzm_exclusion_flags\n';
};
