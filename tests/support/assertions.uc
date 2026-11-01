let passed = 0;
export function count() { passed++; };
export function equal(value, expected, name) {
    assert(sprintf('%J', value) == sprintf('%J', expected), sprintf('%s: expected %J, got %J', name, expected, value));
    count();
};
export function rejects(fn, name) {
    let failed = false;
    try { fn(); } catch (e) { failed = true; }
    assert(failed, name);
    count();
};
export function checks() { return passed; };
