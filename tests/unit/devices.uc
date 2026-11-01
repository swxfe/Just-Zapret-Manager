import { equal, rejects, count } from '../support/assertions.uc';
import { ipv4, exclusion_hook, legacy_addresses } from 'devices';
import { fixture } from '../setup/unit.uc';

export function run() {
    let f = fixture();
    let ctx = f.ctx;
    equal(legacy_addresses("EXCEPT_SRC='{ 192.168.1.10, 192.168.1.20 }'\nnft insert rule inet zapret postrouting_hook index 0 \\\n  ip saddr $EXCEPT_SRC meta mark set meta mark \\| 0x40000000\n"),
        ['192.168.1.10', '192.168.1.20'], 'recognize original device exclusion hook without executing it');
    equal(legacy_addresses('#!/bin/sh\necho custom\n'), null, 'preserve unrelated custom hooks');
    equal(legacy_addresses("EXCEPT_SRC='{ 192.168.1.1 }'\nnft insert rule inet zapret postrouting_hook index 0 ip saddr $EXCEPT_SRC meta mark set meta mark \\| 0x40000000\nreboot\n"),
        null, 'reject extended legacy hook');
    equal(ipv4('192.168.001.20'), '192.168.1.20', 'canonical IPv4');
    for (let bad in ['256.1.1.1', '1.2.3', '1.2.3.4;id', '1.2.3.-1', '::1']) rejects(() => ipv4(bad), 'reject invalid client address');
    let hook = exclusion_hook(ctx, ['192.168.1.20']);
    assert(index(hook, "ip saddr '{ 192.168.1.20 }'") != -1 && index(hook, '\\| 0x40000000') != -1,
        'generate literal nft match and escaped mark operator'); count();
    rejects(() => exclusion_hook(ctx, ['1.2.3.4;id']), 'never generate shell from invalid address');
};
