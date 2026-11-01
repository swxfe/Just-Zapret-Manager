import { http_request } from 'http';
let ctx = { connect_timeout: 1, request_timeout: 1 };
let reply = http_request(ctx, ARGV[0], +ARGV[1], ARGV[2] == '1');
printf('%J\n', reply);
