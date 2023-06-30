## feat/box

This authentication method doesn't store any secrets; instead,
we delegate the whole auth to a pre-configured LDAP server. In
the method's implementation, we connect to the LDAP server and
perform a BIND operation which checks user's credentials.

Usage example:

```lua
-- Set the default auth method to LDAP and create a new user.
-- NOTE that we still have to provide a dummy password; otherwise
-- box.schema.user.create will setup an empty auth data.
box.cfg({auth_type = 'ldap'})
box.schema.user.create('demo', { password = '' })

-- Configure LDAP server connection URL and DN format string.
os = require('os')
os.setenv('TT_LDAP_URL', 'ldap://localhost:1389')
os.setenv('TT_LDAP_DN_FMT', 'cn=$USER,ou=users,dc=example,dc=org')

-- Authenticate using the LDAP authentication method via net.box.
conn = require('net.box').connect(uri, {
    user = 'demo',
    password = 'password',
    auth_type = 'ldap',
})
