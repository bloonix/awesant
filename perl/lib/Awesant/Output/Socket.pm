=head1 NAME

Awesant::Output::Socket - Send messages to a tcp socket.

=head1 SYNOPSIS

    my $output = Awesant::Output::Socket->new(
        host => "127.0.0.1",
        port => 4711,
        timeout => 10,
    );

    $output->push($line);

=head1 DESCRIPTION

This transport module connects to a tcp socket and ships data plain or via ssl.

=head1 OPTIONS

=head2 host

The hostname or ip address of the tcp server.

It's possible to set a comma separated list of failover hosts.

    socket {
        host active-server, failover-server-1, failover-server-2
        port 4711
    }

If the connection to one host failed then a connection to the next server is established.

Default: 127.0.0.1

=head2 port

The port number where the tcp server is listen on.

Default: no default

=head2 auth

With this option it's possible to set a username and password, if you want to
authorize the connection to the host.

    user:password

See also the documentation of Awesant::Input::Socket.

=head2 timeout

The timeout in seconds to transport data to the tcp server.

Default: 10

=head2 connect_timeout

The timeout in seconds to connect to the tcp server.

Default: 10

=head2 proto

The protocol to use. At the moment only tcp is allowed.

Default: tcp

=head2 response

If a response is excepted then you can set the excepted message here as a perl regular expression.

If the regular expression matched, then the transport of the message was successful.

Example:

    response ^(ok|yes|accept)$

Default: no default

See also the documentation of Awesant::Input::Socket.

=head2 persistent

Use persistent connections or not.

Default: yes

=head2 ssl_ca_file, ssl_cert_file, ssl_key_file, ssl_verify_mode

If you want to use ssl connections to the server you can set the path to your ca or certificate file.

The option ssl_verify_mode can be set to SSL_VERIFY_PEER, or SSL_VERIFY_NONE. Lowercase is allowed.

This options are equivalent to the options of IO::Socket::SSL.

See cpan http://search.cpan.org/~sullr/IO-Socket-SSL/.

Default: there are no defaults set, so you have to check the defaults of IO::Socket::SSL.
Please check the right version of IO::Socket::SSL.

    perl -MIO::Socket::SSL -e 'print $IO::Socket::SSL::VERSION'

=head1 METHODS

=head2 new

Create a new output object.

=head2 connect

Connect to the tcp server.

=head2 disconnect

Disconnect from the socket.

=head2 push

Push data to the tcp server.

=head2 validate

Validate the configuration that is passed to the C<new> constructor.

=head2 log

Just a accessor to the logger.

=head1 PREREQUISITES

    IO::Socket::INET
    Log::Handler
    Params::Validate

=head1 EXPORTS

No exports.

=head1 REPORT BUGS

Please report all bugs to <support(at)bloonix.de>.

=head1 AUTHOR

Jonny Schulz <support(at)bloonix.de>.

=head1 COPYRIGHT

Copyright (C) 2012 by Jonny Schulz. All rights reserved.

=cut

package Awesant::Output::Socket;

use strict;
use warnings;
use IO::Socket::INET;
use Log::Handler;
use Params::Validate qw();

sub new {
    my $class = shift;
    my $opts = $class->validate(@_);
    my $self = bless $opts, $class;

    $self->{log} = Log::Handler->get_logger("awesant");

    $self->{__alarm_sub} = sub {
        alarm(0);
    };

    $self->{__timeout_sub} = sub {
        die "connection timed out";
    };

    $self->log->notice("$class initialized");

    return $self;
}

sub connect {
    my $self = shift;

    # If the socket is still active, then just return true.
    # This works only if the sock is set to undef on errors.
    if ($self->{sock} && $self->{persistent}) {
        return 1;
    }

    my $module = $self->{sockmod};
    my $port   = $self->{port};
    my $hosts  = $self->{hosts};
    my @order  = @$hosts;
    my $sock;

    # Try to connect to the hosts in the configured order.
    while (my $host = shift @order) {
        # Although the connection was successful, the host is pushed
        # at the end of the array. If the connection lost later, then
        # the next host will be connected.
        push @$hosts, shift @$hosts;

        # Set the currently used host to the object.
        $self->{host} = $host;

        # Set the PeerAddr to the host that we a try to connect.
        $self->{sockopts}->{PeerAddr} = $host;

        # We don't want that the daemon dies if the connection
        # was not successful. The eval block is also great to
        # break out on errors.
        $self->log->notice("connect to server $host:$port");
        eval {
            local $SIG{ALRM} = $self->{__timeout_sub};
            local $SIG{__DIE__} = $self->{__alarm_sub};
            alarm($self->{connect_timeout});
            $sock = $module->new(%{$self->{sockopts}});
            die $! unless $sock;
            if ($self->{auth}) {
                print $sock $self->{auth}, "\n";
                my $ok = <$sock>;
                chomp($ok);
                if (!$ok) {
                    die "not authorized to connect to server";
                }
            }
            alarm(0);
        };

        # If no error message exists and the socket is created,
        # then the connection was successful. In this case we
        # just jump out of the loop.
        if (!$@ && $sock) {
            last;
        }

        # At this point the connection was not successful.
        if ($@) {
            $self->log->error($@);
        }

        $self->log->error("unable to connect to server $host:$port");
    }

    # It's possible that no connection could be established to any host.
    # If a connection could be established, then the socket will be
    # stored to $self->{sock} and autoflush flag is set to the socket.
    if ($sock) {
        $sock->autoflush(1);
        $self->log->notice("connected to server $self->{host}:$self->{port}");
        $self->{sock} = $sock;
        return 1;
    }

    return undef;
}

sub disconnect {
    my $self = shift;
    my $socket = $self->{sock};

    if ($socket) {
        close $socket;
    }
}

sub push {
    my ($self, $data) = @_;

    # At a newline to the end of the data.
    $data = "$data\n";

    # At first try to connect to the server.
    # If the connect was successful, the socket
    # is stored in $self->{sock}.
    $self->connect
        or return undef;

    my $sock = $self->{sock};
    my $timeout = $self->{timeout};
    my $response = "";

    eval {
        local $SIG{ALRM} = $self->{__timeout_sub};
        local $SIG{__DIE__} = $self->{__alarm_sub};
        alarm($timeout);

        my $rest = length($data);
        my $offset = 0;

        if ($self->log->is_debug) {
            $self->log->debug("set timeout to $timeout seconds");
            $self->log->debug("send data to server $self->{host}:$self->{port}: $data");
        }

        while ($rest) {
            my $written = syswrite $sock, $data, $rest, $offset;

            if (!defined $written) {
                die "system write error: $!\n";
            }

            $rest -= $written;
            $offset += $written;
        }

        if ($self->log->is_debug) {
            $self->log->debug("data written to server $self->{host}:$self->{port}");
        }

        if (defined $self->{response}) {
            $self->log->debug("read response from server $self->{host}:$self->{port}");
            $response = <$sock>;
            $self->log->debug("got response from server $self->{host}:$self->{port}: $response");
        }

        alarm(0);
    };

    if (!$self->{persistent}) {
        $self->close_socket;
    }

    if ($@) {
        $self->log->error($@);
        $self->{sock} = undef;
        return undef;
    }

    if (!defined $self->{response}) {
        return 1;
    }

    if (!defined $response) {
        $self->log->error("no response received from server $self->{host}:$self->{port}");
        $self->{sock} = undef;
        return undef;
    }

    if ($response =~ /$self->{response}/) {
        return 1;
    }

    $self->log->error("unknown response from server: $response");
    $self->{sock} = undef;
    return undef;
}

sub validate {
    my $self = shift;

    my %options = Params::Validate::validate(@_, {
        host => {
            type => Params::Validate::SCALAR | Params::Validate::ARRAYREF,
            default => "127.0.0.1",
        },
        port => {
            type => Params::Validate::SCALAR,  
            default => 6379,
        },
        connect_timeout => {
            type => Params::Validate::SCALAR,
            default => 10,
        },
        timeout => {  
            type => Params::Validate::SCALAR,  
            default => 10,
        },
        proto => {
            type => Params::Validate::SCALAR,
            regex => qr/^tcp\z/,
            default => "tcp",
        },
        auth => {
            type => Params::Validate::SCALAR,
            optional => 1,
        },
        response => {
            type => Params::Validate::SCALAR,
            optional => 1,
        },
        persistent => {
            type => Params::Validate::SCALAR,
            regex => qr/^(?:yes|no|0|1)\z/,
            default => "yes",
        },
        ssl_ca_file => {
            type => Params::Validate::SCALAR,
            optional => 1,
        },
        ssl_cert_file => {
            type => Params::Validate::SCALAR,
            optional => 1,
        },
        ssl_key_file => {
            type => Params::Validate::SCALAR,
            optional => 1,
        },
        ssl_verify_mode => {
            type => Params::Validate::SCALAR,
            optional => 1,
            regex => qr!^SSL_VERIFY_(PEER|NONE)\z!,
        },
    });

    if ($options{persistent} eq "no") {
        $options{persistent} = 0;
    }

    if ($options{ssl_cert_file} || $options{ssl_ca_file}) {
        require IO::Socket::SSL;
        $options{sockmod} = "IO::Socket::SSL";
    }

    if (!$options{sockmod}) {
        $options{sockmod} = "IO::Socket::INET";
    }

    my %sockopts = (
        port => 'PeerPort',
        ssl_ca_file   => 'SSL_ca_file',
        ssl_cert_file => 'SSL_cert_file',
        ssl_key_file  => 'SSL_key_file',
    );

    while (my ($opt, $modopt) = each %sockopts) {
        if ($options{$opt}) {
            $options{sockopts}{$modopt} = $options{$opt};
        }
    }

    if ($options{ssl_verify_mode}) {
        $options{ssl_verify_mode} = uc($options{ssl_verify_mode});

        if ($options{ssl_verify_mode} eq "SSL_VERIFY_PEER") {
            $options{sockopts}{SSL_verify_mode} = 0x01;
        } elsif ($options{ssl_verify_mode} eq "SSL_VERIFY_NONE") {
            $options{sockopts}{SSL_verify_mode} = 0x00;
        }
    }

    $options{host} =~ s/\s//g;
    $options{hosts} = [ split /,/, $options{host} ];

    return \%options;
}

sub log {
    my $self = shift;

    return $self->{log};
}

1;
