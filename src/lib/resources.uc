import * as fs from 'fs';

export const VERSION = '0.1.1';

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
    let body = fs.readfile(home + '/data/' + name);
    if (body == null) die('не найден ресурс: ' + name);
    return body;
};
