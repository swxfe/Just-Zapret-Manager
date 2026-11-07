import { equal, rejects, count } from '../support/assertions.uc';
import { github_response } from 'releases';

export function run() {
    equal(github_response('200\n59\n{"sha":"test"}'), '{"sha":"test"}', 'GitHub success body');
    equal(github_response('200\n\n{}'), '{}', 'GitHub success without remaining header');
    equal(github_response('200\n59\n{"commit":{"message":"Fix rate limit exceeded"}}'),
          '{"commit":{"message":"Fix rate limit exceeded"}}', 'commit message is not an API error');
    function api_error(response, expected) {
        let message = '';
        try { github_response(response); } catch (e) { message = e.message; }
        assert(index(message, expected) != -1, sprintf('API diagnostic: expected %s, got %s', expected, message));
        count();
    }
    for (let response in ['403\n0\n{}', '403\n\n{"message":"API rate limit exceeded for IP"}',
                         '403\n10\n{"message":"You have exceeded a secondary rate limit."}',
                         '429\n\n<html>Too many requests</html>'])
        api_error(response, 'Превышен лимит запросов GitHub API (60/час на ваш IP)');
    api_error('403\n59\n{"message":"Resource not accessible"}', 'ошибка HTTP 403');
    api_error('404\n59\n{"message":"Not Found"}', 'ошибка HTTP 404');
    api_error('503\n\n<html>Unavailable</html>', 'ошибка HTTP 503');
    rejects(() => github_response('broken'), 'reject missing API status');
    rejects(() => github_response('000\n\n{}'), 'reject invalid API status');
};
