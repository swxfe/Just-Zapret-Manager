// Only an interactive session owns this cache; transaction workers read fresh state.
export function session_cache(ctx) {
    ctx.cache = {};
};

export function cached(ctx, key, obtain) {
    if (ctx.cache == null) return obtain();
    if (exists(ctx.cache, key)) return ctx.cache[key];
    // User-selected catalogs and paths must not grow the session without a bound.
    if (length(ctx.cache) >= 64) ctx.cache = {};
    let value = obtain();
    ctx.cache[key] = value;
    return value;
};

export function invalidate(ctx) {
    if (ctx.cache != null) ctx.cache = {};
};
