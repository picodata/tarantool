## bugfix/core

* An SSL connection closed by the server no longer waits for the peer's
  `close_notify`. With a silent peer this blocked the IPROTO thread, so no
  request got a response and the instance could not stop.

* An SSL error on one connection no longer breaks the next read or write on
  another connection served by the same thread. Such a connection used to
  fail with an error like `ssl_read: Resource temporarily unavailable`, which
  could be sent back to the client as the response to its request.
