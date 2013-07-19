# Awesant::Output::Socket

## Options

### host

The hostname or ip address of the tcp server.

It's possible to set a comma separated list of failover hosts.

    socket {
        host active-server, failover-server-1, failover-server-2
        port 4711
    }

If the connection to one host failed then a connection to the next server is established.

Default: 127.0.0.1

### port

The port number where the tcp server is listen on.

Default: no default

### auth

With this option it's possible to set a username and password, if you want to
authorize the connection to the host.

    user:password

See also the documentation of Awesant::Input::Socket.

### timeout

The timeout in seconds to transport data to the tcp server.

Default: 10

### connect_timeout

The timeout in seconds to connect to the tcp server.

Default: 10

### proto

The protocol to use. At the moment only tcp is allowed.

Default: tcp

### response

If a response is excepted then you can set the excepted message here as a perl regular expression.

If the regular expression matched, then the transport of the message was successful.

Example:

    response ^(ok|yes|accept)$

Default: no default

See also the documentation of Awesant::Input::Socket.

### persistent

Use persistent connections or not.

Default: yes

### ssl_ca_file, ssl_cert_file, ssl_key_file, ssl_verify_mode

If you want to use ssl connections to the server you can set the path to your ca or certificate file.

The option ssl_verify_mode can be set to SSL_VERIFY_PEER, or SSL_VERIFY_NONE. Lowercase is allowed.

This options are equivalent to the options of IO::Socket::SSL.

See cpan http://search.cpan.org/~sullr/IO-Socket-SSL/.

Default: there are no defaults set, so you have to check the defaults of IO::Socket::SSL.
Please check the right version of IO::Socket::SSL.

    perl -MIO::Socket::SSL -e 'print $IO::Socket::SSL::VERSION'

