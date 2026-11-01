import { equal, rejects, count } from '../support/assertions.uc';
import { domains, urls, validate_list_snapshot } from 'domains';

export function run() {
    equal(domains('EXAMPLE.COM\r\nexample.com # duplicate\nsub.example.com\n', 3),
          ['example.com', 'sub.example.com'], 'normalization and deduplication');
    equal(domains('', 1), [], 'empty list');
    equal(validate_list_snapshot('# package defaults\n127.0.0.0/8\n::1\nfc00::/7\nru\nрф\nexample.com\n', 8, 1024), true, 'backup preserves upstream mixed list formats');
    rejects(() => validate_list_snapshot('a\x00b', 8, 1024), 'backup rejects NUL bytes');
    rejects(() => validate_list_snapshot('a\nb\n', 1, 1024), 'backup list line limit');
    rejects(() => validate_list_snapshot('example.com', 8, 4), 'backup list byte limit');
    let wide_line = '';
    for (let i = 0; i < 512; i++) wide_line += 'я';
    equal(validate_list_snapshot(wide_line + '\n', 1, 4096), true, 'backup accepts exactly 1024 UTF-8 bytes');
    rejects(() => validate_list_snapshot(wide_line + 'x\n', 1, 4096), 'backup byte width is not a Unicode character count');
    equal(validate_list_snapshot(' \t\r\n\nfirst\n \r\nsecond', 2, 4096), true, 'backup counts nonblank lines and final unterminated line');
    rejects(() => validate_list_snapshot('first\n\x01second', 2, 4096), 'backup checks control bytes after newlines');
    for (let bad in ['-host.com', 'host-.com', 'a..com', '*.example.com', 'x.com;id', 'https://x.com', 'a b.com'])
        rejects(() => domains(bad, 8), 'reject domain ' + bad);
    rejects(() => domains('one.com\ntwo.com', 1), 'domain limit');
    let max_label = 'a' + sprintf('%062d', 0);
    equal(domains(max_label + '.test', 1), [max_label + '.test'], 'DNS label accepts 63 bytes');
    rejects(() => domains(max_label + 'x.test', 1), 'DNS label rejects 64 bytes');
    equal(urls('# comment\nhttps://example.com/path?a=1&b=2\n', 2),
          ['https://example.com/path?a=1&b=2'], 'URL parser');
    equal(urls('https://redirector.googlevideo.com/report_mapping\n', 1),
          ['https://redirector.googlevideo.com/report_mapping'], 'Googlevideo mapping URL');
    for (let bad in ['file:///etc/passwd', 'https://example.com\n--output x', '', 'https://user:pw@host.test'])
        rejects(() => urls(bad, 2), 'reject URL');
    rejects(() => urls('https://one.com\nhttps://two.com', 1), 'URL limit');
};
