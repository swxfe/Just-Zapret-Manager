import * as fs from 'fs';
import * as uci from 'uci';

function request(url, options) {
    let root = getenv('ZM_TEST_ROOT');
    let reply = { status: 200, headers: {}, body: '' };
    let flag = (name) => fs.stat(root + '/' + name) != null;
    let contents = (name) => fs.readfile(root + '/' + name);
    if (substr(url, 0, 23) == 'https://api.github.com/') {
        if (flag('api-transport-fail')) die('transport timeout');
        if (flag('api-status')) reply.status = +trim(contents('api-status'));
        if (flag('api-remaining')) reply.headers['x-ratelimit-remaining'] = trim(contents('api-remaining'));
        if (flag('api-body')) { reply.body = contents('api-body'); return reply; }
    }
    if (index(url, '/jzm-fixture/manager/') != -1) {
        if (flag('update-offline')) die('offline update');
        reply.body = index(url, 'api.github.com') != -1 ? '{"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}' : contents('manager-release');
        return reply;
    }
    if (flag('mock-release') && index(url, '/remittor/zapret-openwrt/releases/latest') != -1) {
        reply.body = '{"tag_name":"v72.20260307","assets":[]}'; return reply;
    }
    if (flag('pause-probe')) {
        fs.writefile(root + '/probe-entered', '1');
        sleep(2000);
        fs.unlink(root + '/pause-probe');
    }
    if (!options.allow_http) {
        if (!length(reply.body)) reply.body = contents('download');
        return reply;
    }
    let handle = uci.cursor(root + '/etc/config', '/dev/null', '');
    let opts = handle.get('zapret', '@main[0]', 'NFQWS_OPT') || '';
    let available = flag('state') && (index(opts, 'multisplit') != -1 ||
        (index(opts, 'fake') != -1 && substr(url, 0, 17) == 'https://one.test/'));
    reply.status = available ? 200 : 503;
    return reply;
};

return { request };
