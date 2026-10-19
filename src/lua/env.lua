local ffi = require('ffi')
local os = require('os')
local errno = require('errno')

ffi.cdef[[
    extern char **environ;

    int   setenv(const char *name, const char *value, int overwrite);
    int   unsetenv(const char *name);
    void  tnt_datetime_tz_reload(void);
]]

os.environ = function()
    local environ = ffi.C.environ
    if not environ then
        return nil
    end
    local r = {}
    local i = 0
    while environ[i] ~= nil do
        local e = ffi.string(environ[i])
        local eq = e:find('=')
        if eq then
            r[e:sub(1, eq - 1)] = e:sub(eq + 1)
        end
        i = i + 1
    end
    return r
end

os.setenv = function(key, value)
    local rv
    if value ~= nil then
        rv = ffi.C.setenv(key, value, 1)
    else
        rv = ffi.C.unsetenv(key)
    end
    if rv == -1 then
        error(string.format('error %d: %s', errno(), errno.errstring()))
    end
    -- Let datetime.now() and os.date() see the new zone. Compare the name
    -- as C sees it ('TZ\0x' sets TZ). Call C directly: require('datetime')
    -- may return an overridden module.
    if ffi.string(key) == 'TZ' then
        ffi.C.tnt_datetime_tz_reload()
    end
end
