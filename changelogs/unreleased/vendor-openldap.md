## feature/build

Add libldap (part of OpenLDAP) as a vendored third-party dependency.
OpenLDAP builds everything (including MAN pages) unconditionally,
thus we have to patch its sources so as not to install soelim (Groff).

```shell
sed -i.old "/SUBDIRS/s/clients servers tests doc//" Makefile.in
```
