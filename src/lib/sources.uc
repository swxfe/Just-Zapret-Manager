import { cached } from 'cache';
import * as fs from 'fs';
import { check, read } from 'common';
import { parse_catalog } from 'strategies';

export function source_file(ctx, kind) {
    check(kind == 'flowseal' || kind == 'manager', 'неизвестный источник');
    return ctx.assets + '/catalogs/' + kind + '.json';
};

export function source_data(ctx, kind, wanted) {
    let file = source_file(ctx, kind);
    check(fs.stat(file) != null, 'каталог ассетов не установлен; переустановите JZM с jzm-assets.tar.gz');
    let value = cached(ctx, 'source-document:' + file, () => json(read(file, ctx.max_file_bytes)));
    check(value.format == 1 && value.source == kind && type(value.revision) == 'string' &&
          match(value.revision, /^[a-f0-9]{40}$/) && type(value.catalog) == 'string', 'повреждён каталог ассетов');
    let strategies = cached(ctx, 'source-presets:' + kind + ':' + sprintf('%J', wanted), () => parse_catalog(ctx, value.catalog, wanted));
    return { ...value, strategies: map(strategies, (s) => ({ ...s, missing: (value.unavailable || {})[s.name] || [] })) };
};
