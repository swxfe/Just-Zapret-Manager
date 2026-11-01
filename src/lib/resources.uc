import * as fs from 'fs';

let resource_cache = {};

export const VERSION = '0.1.2';

// The bundler replaces these accessors with references to generated constants.
export function embedded_data() { return null; };
export function embedded_config() { return null; };
export function embedded_header() { return null; };
export function embedded_footer() { return null; };

export function resource(home, name) {
    let data = embedded_data();
    if (data != null) {
        if (!exists(data, name)) die('неизвестный встроенный ресурс: ' + name);
        return data[name];
    }
    let path = home + '/data/' + name;
    if (exists(resource_cache, path)) return resource_cache[path];
    let body = fs.readfile(path);
    if (body == null) die('не найден ресурс: ' + name);
    if (length(resource_cache) >= 16) resource_cache = {};
    resource_cache[path] = body;
    return body;
};
