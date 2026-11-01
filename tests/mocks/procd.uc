import * as fs from 'fs';
import * as ubus from 'ubus';
import * as uloop from 'uloop';

let root = ARGV[0];
uloop.init();
let bus = ubus.connect(root + '/tmp/ubus.sock');
assert(bus != null, 'connect fixture ubus');
let object = bus.publish('service', {
    list: { args: { name: '' }, call: (request) => {
        if (fs.stat(root + '/procd-invalid')) return request.reply({ zapret: { instances: false } });
        // procd remains authoritative even if the init script fails.
        let running = fs.stat(root + '/procd-running') || fs.stat(root + '/state');
        request.reply({ zapret: { instances: { nfqws: { running: running != null } } } });
    } }
});
assert(object != null, 'publish fixture service: ' + ubus.error());
fs.writefile(root + '/tmp/procd-ready', '1');
uloop.run();
