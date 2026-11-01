import * as fs from 'fs';
import * as uclient from 'uclient';
import * as uloop from 'uloop';

let http_provider = null, http_provider_path = null;

function http_valid_url(url, allow_http) {
    return type(url) == 'string' && length(url) <= 4096 &&
        match(url, allow_http ? /^https?:\/\/[^[:space:]]+$/ : /^https:\/\/[^[:space:]]+$/);
}

// The explicit provider is for the offline fault-injection harness. It is never
// read from manager.json, remote catalogs or responses.
export function http_request(ctx, url, limit, allow_http, discard) {
    if (!http_valid_url(url, allow_http)) die('неверный URL HTTP');
    let provider = getenv('JZM_HTTP_PROVIDER');
    if (provider != null) {
        if (http_provider == null || http_provider_path != provider) {
            http_provider = loadfile(provider, { strict_declarations: true })();
            http_provider_path = provider;
        }
        let reply = http_provider.request(url, { limit, allow_http,
            connect_timeout: ctx.connect_timeout, request_timeout: ctx.request_timeout });
        if (type(reply) != 'object' || type(reply.body) != 'string' || length(reply.body) > limit ||
            type(reply.status) != 'int' || reply.status < 100 || reply.status > 599 || type(reply.headers) != 'object')
            die('неверный ответ HTTP provider');
        return reply;
    }
    uloop.init();
    let client = null, deadline = null, redirects = 0, total = 0;
    let current = url, headers = {}, status = 0, chunks = [], problem = '', complete = false;
    function stop(message) { problem = message; uloop.end(); }
    function consume() {
        // The oldest supported uclient uses a fixed 4096-byte C read buffer.
        for (let chunk = client.read(4096); chunk != null && length(chunk); chunk = client.read(4096)) {
            total += length(chunk);
            if (total > limit) { stop('ответ HTTP превышает лимит размера'); return; }
            if (!discard) push(chunks, chunk);
        }
    }
    try {
        client = uclient.new(url, null, {
            header_done: () => {
                let info = client.status();
                status = info.status; headers = {};
                for (let name, value in client.get_headers()) headers[lc(name)] = value;
                if (!info.redirect) {
                    let size = headers['content-length'];
                    if (size != null && (!match(size, /^[0-9]+$/) || +size > limit)) stop('ответ HTTP превышает лимит размера');
                    return;
                }
                let location = headers.location;
                if (type(location) != 'string' || ++redirects > 3) { stop('слишком много перенаправлений HTTP'); return; }
                if (substr(location, 0, 2) == '//') location = split(current, ':')[0] + ':' + location;
                else if (substr(location, 0, 1) == '/') {
                    let origin = match(current, /^(https?:\/\/[^/]+)/);
                    location = origin[1] + location;
                }
                else if (!match(location, /^https?:\/\//)) {
                    let origin = match(current, /^(https?:\/\/[^/]+)(\/.*)?$/);
                    let path = split(origin[2] || '/', '?')[0];
                    location = origin[1] + fs.dirname(path) + '/' + location;
                }
                if (!http_valid_url(location, allow_http) || (substr(current, 0, 6) == 'https:' && substr(location, 0, 6) != 'https:')) {
                    stop('небезопасное перенаправление HTTP'); return;
                }
                current = location; chunks = []; total = 0;
                if (!client.set_url(location) || !client.connect() ||
                    !client.request('GET', { headers: { 'User-Agent': 'JZM', Accept: '*/*' } }))
                    stop('ошибка перенаправления HTTP');
            },
            data_read: consume,
            data_eof: () => { consume(); complete = client.status().data_eof == true; uloop.end(); },
            error: (handle, code) => stop('ошибка HTTP transport: ' + code)
        });
        if (client == null) die('не удалось создать HTTP client');
        let ca = getenv('SSL_CERT_FILE') || '/etc/ssl/certs/ca-certificates.crt';
        if (!client.ssl_init({ verify: true, ca_files: [ca] }))
            die('не удалось включить проверку сертификата HTTPS');
        if (!client.set_timeout(ctx.connect_timeout * 1000)) die('не удалось задать таймаут HTTP');
        deadline = uloop.timer(ctx.request_timeout * 1000, () => stop('истёк таймаут HTTP'));
        if (!client.connect() || !client.request('GET', { headers: { 'User-Agent': 'JZM', Accept: '*/*' } }))
            die('не удалось подключиться к HTTP server');
        uloop.run();
        deadline.cancel();
        client.disconnect(); client.free(); client = null;
        if (length(problem)) die(problem);
        if (!complete || status < 100 || status > 599) die('неполный ответ HTTP');
        return { status, headers, body: join('', chunks) };
    }
    catch (e) {
        if (deadline != null) deadline.cancel();
        if (client != null) { client.disconnect(); client.free(); }
        die(e.message);
    }
};
