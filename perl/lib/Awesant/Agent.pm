=head1 NAME

Awesant::Agent - Ships log files for logstash.

=head1 SYNOPSIS

    Awesant::Agent->run(
        config  => $path_to_configuration,
        pidfile => $path_to_pid_file,
    );

=head1 DESCRIPTION

Awesant is a simple log file shipper for logstash.

It ships log files and sends the data to different transports.

All what you have to do is to call the method C<run> with its expected options.

=head1 METHODS

=head2 run

Start the shipping machine.

Nothing more is there for you to do. That means that you shouldn't touch the
other methods in this module.

=head2 load_output

Load the output modules that are used by configuration.

As example if C<redis> is defined as transport in the output section

    output {
        redis {
            ...
        }
    }

then Awesant is looking for a module called C<Awesant::Output::Redis>.
If you would define a section call C<foo>, then Awesant would try to
C<require> the module C<Awesant::Output::Foo>.

=head2 load_input

The method C<load_input> does in the first step the same like C<load_output>.
It looks for input modules. As example if the input C<file> is configured,
then it tries to load the module C<Awesant::Input::File>.

As next each output module that was pre-loaded is bound to the inputs.
This is done using the parameter C<type>.

=head2 load_module

This method just includes the input and output modules and is called by
C<load_output> and C<load_input>. The process to load the modules is really
simple.

As example if the following sections are configured:

    output {
        redis {
            ...
        }
    }

then the module is loaded as follows:

    my $input_or_output = "output"; # output is the first section
    my $transport = "redis";        # redis is the configured transport

    my $module = join("::",
        "Awesant",
        ucfirst($input_or_output),
        ucfirst($transport)
    );

    require $module;

All clear? :-)

=head2 daemonize

Start the endless loop and calls C<run_agent> in an eval block.

=head2 run_agent

This method is just a wrapper and calls C<run_log_shipper> in an eval block.

=head2 run_server

This methods creates some process groups for each input and just calls C<run_agent>
for each group after the workers are forked.

=head2 run_log_shipper

The main logic of the Awesant agent. It requests the inputs for data to
forward the data to the outputs.

=head2 prepare_message

Each log line is passed to C<prepare_message> and a nice formatted
JSON string is returned, ready for Logstash.

=head2 reap_children

Reap died sub processes.

=head2 spawn_children

Fork new children if less children than the configured workers are running.

=head2 kill_children

Kill all children on signal term.

=head2 sig_child_handler

A handler to reap children.

=head2 get_config

Load the configuration from a file.

=head2 write_pidfile

Writes the PID file.

=head2 remove_pidfile

Removes the PID file.

=head2 create_logger

Create the logger object. As logger C<Log::Handler> is used.

=head2 validate_config, validate_agent_config, validate_add_field_match

Validate the configuration.

=head2 config

Just an accessor to the configuration.

=head2 log

Just an accessor to the logger.

=head1 PREREQUISITES

    Log::Handler
    Params::Validate
    JSON
    POSIX
    Sys::Hostname
    Time::HiRes
    Class::Accessor::Fast

=head1 EXPORTS

No exports.

=head1 REPORT BUGS

Please report all bugs to <support(at)bloonix.de>.

=head1 AUTHOR

Jonny Schulz <support(at)bloonix.de>.

=head1 COPYRIGHT

Copyright (C) 2012 by Jonny Schulz. All rights reserved.

=cut

package Awesant::Agent;

use strict;
use warnings;
use Log::Handler;
use Params::Validate qw();
use JSON;
use POSIX qw(:sys_wait_h);
use Sys::Hostname;
use Time::HiRes qw();
use Awesant::Config;
use base qw(Class::Accessor::Fast);

# On Windows fork() is not really available.
# If the agent will be started on windows
# then awesant runs only as single process.
# TODO: implement threading?
use constant IS_WIN32 => $^O =~ /Win32/i;

# Just some simple accessors
__PACKAGE__->mk_accessors(qw/config log process_group json/);

our $VERSION = "0.6";

sub run {
    my ($class, %args) = @_;

    my $self = bless {
        args     => \%args, # the command line arguments
        done     => 0,      # a flag to stop the daemon on some signals
        child    => { },    # store the pids of each child
        reaped   => { },    # store the pids of each child that was reaped
        inputs   => [ ],    # store the inputs in a array ref
        outputs  => { },    # store the outputs in a hash ref by type
        json     => JSON->new(),
        hostname => Sys::Hostname::hostname(),
    }, $class;

    # The main workflow.
    $self->write_pidfile;
    $self->get_config;
    $self->create_logger;
    $self->load_output;
    $self->load_input;
    $self->daemonize;
    $self->remove_pidfile;
}

sub load_output {
    my $self = shift;
    my $outputs = $self->config->{output};

    foreach my $output (keys %$outputs) {
        # At first the output module is required.
        # Example: redis => Awesant/Output/Redis.pm
        my $module = $self->load_module(output => $output);

        foreach my $config (@{$outputs->{$output}}) {
            # Option "type" is used by the agent and must be
            # deleted from the output configuration.
            my $types = delete $config->{type};

            # Type is an mandatory parameter. The type is overwritten
            # if incoming json_events has @type set.
            if (!defined $types) {
                die "missing mandatory parameter 'type' of output '$output'";
            }

            # Only a-zA-Z_0-9 is allowed.
            if (!length $types) {
                die "no value passed for parameter 'type' of output '$output'";
            }

            # Create a new output object.
            my $object = $module->new($config);

            # Multiple types are allowed for outputs.
            foreach my $type (split /,/, $types) {
                $type =~ s/^\s+//;
                $type =~ s/\s+\z//;
                push @{$self->{outputs}->{$type}}, $object;
            }
        }
    }
}

sub load_input {
    my $self = shift;
    my $inputs = $self->config->{input};

    foreach my $input (keys %$inputs) {
        # At first load the input modules.
        # Example: file => Awesant/Input/File.pm
        my $module = $self->load_module(input => $input);

        foreach my $config (@{$inputs->{$input}}) {

            # Split the agent configuration parameter from the
            # parameter for the input module.
            my %agent_config;
            foreach my $param (qw/type tags add_field workers format/) {
                if (exists $config->{$param}) {
                    $agent_config{$param} = delete $config->{$param};
                }
            }

            # If the add_field value is a hash then it can contains code
            # instead of a simple string. In this case the code must be
            # executed for every json event.
            foreach my $field (keys %{$agent_config{add_field}}) {
                if (ref $agent_config{add_field}{$field} eq "HASH") {
                    $agent_config{__add_field}{$field} = delete $agent_config{add_field}{$field};
                }
            }

            # A path should be set.
            $agent_config{path} = $config->{path} || "/";

            # The file input can only process on single file, but if a wildcard
            # is used within the path or a comma separated list of files is passed
            # it's necessary to create an input object for each file.
            if ($input eq "file") {
                foreach my $path (split /,/, $config->{path}) {
                    $path =~ s/^\s+//;
                    $path =~ s/\s+\z//;
                    while (my $file = glob $path) {
                        my %c = %$config;
                        my %a = %agent_config;
                        $a{path} = $c{path} = $file;
                        push @{$self->{inputs}}, {
                            time   => scalar Time::HiRes::gettimeofday(),
                            object => $module->new(\%c),
                            config => $self->validate_agent_config(\%a),
                        };
                    }
                }
            } else {
                push @{$self->{inputs}}, {
                    time   => scalar Time::HiRes::gettimeofday(),
                    object => $module->new($config),
                    config => $self->validate_agent_config(\%agent_config),
                };
            }
        }
    }
}

sub load_module {
    my ($self, $io, $type) = @_;

    # output { redis { } }
    #   = Awesant::Output::Redis
    my $module = join("::",
        "Awesant",
        ucfirst($io),
        ucfirst($type),
    );

    eval "require $module";

    if ($@) {
        # The module name may be uppercase.
        # output { tcp { } }
        #    = Awesant::Output::TCP
        $module = join("::",
            "Awesant",
            ucfirst($io),
            uc($type),
        );
        eval "require $module";
        die $@ if $@;
    }

    return $module;
}

sub daemonize {
    my $self = shift;

    # For debugging.
    $SIG{__DIE__}  = sub { $self->log->trace(error   => @_) };
    $SIG{__WARN__} = sub { $self->log->trace(warning => @_) };

    # Ignoring sig hup and pipe by default, because we have no
    # reload mechanism and don't want to break on pipe signals.
    $SIG{HUP} = $SIG{PIPE} = "IGNORE";

    # If one of the following signals are catched then the daemon
    # should stop normally and reap all children first.
    $SIG{TERM} = $SIG{INT} = sub { $self->{done} = 1 };

    if (IS_WIN32) {
        $self->run_agent;
    } else {
        $self->run_server;
    }
}

sub run_server {
    my $self = shift;
    my $child = $self->{child};
    my $reaped = $self->{reaped};
    my $group = 0;

    # Split the inputs into process groups.
    foreach my $input (@{$self->{inputs}}) {
        if ($input->{config}->{workers}) {
            $group++;
            $self->{process_group}->{$group} = {
                workers => $input->{config}->{workers},
                inputs  => [ $input ],
                child   => { },
            };
        } else {
            $self->{process_group}->{0}->{workers} ||= 1;
            $self->{process_group}->{0}->{child} ||= { };
            push @{$self->{process_group}->{0}->{inputs}}, $input;
        }
    }

    # Handle died children.
    $SIG{CHLD} = sub { $self->sig_child_handler(@_) };

    while ($self->{done} == 0) {
        # Reap died children.
        $self->reap_children;
        # Spawn new children.
        $self->spawn_children;

        foreach my $group (keys %{ $self->process_group }) {
            my $process_group = $self->process_group->{$group};

            $self->log->debug(
                scalar keys %{$process_group->{child}},
                "processes running for process group $group:",
                keys %{$process_group->{child}},
            );
        }

        # Sleep a while
        Time::HiRes::usleep(500_000);
    }

    $self->kill_children;
}

sub run_agent {
    my ($self, $inputs) = @_;

    if ($inputs) {
        $self->{inputs} = $inputs;
    }

    while ($self->{done} == 0) {
        eval { $self->run_log_shipper };

        if ($self->{done} == 0) {
            sleep 3;
        }
    }
}

sub run_log_shipper {
    my $self = shift;
    my $poll = $self->config->{poll} / 1000;
    my $inputs = $self->{inputs};
    my $outputs = $self->{outputs};
    my $max_lines = $self->config->{lines};
    my $messurement = Time::HiRes::gettimeofday();
    my $count_lines = 0;
    my $count_bytes = 0;
    my $benchmark = $self->config->{benchmark};
    my (%failed);

    while ($self->{done} == 0) {
        # If no lines was received, then the agent should
        # sleep for a while - low cost cpu :-)
        my $time = Time::HiRes::gettimeofday() + $poll;

        # otype = output type
        # itype = input type
        #
        # If an event couldn't be send, then all left lines are
        # stored with the output object to the %failed hash and
        # the type of the input is used as the hash key.
        # If the hash %failed is not empty, then all inputs with
        # no type and all input types that are stored in %failed
        # will be skipped until %failed is empty. That means that
        # no events will be read from the inputs.
        foreach my $input (@$inputs) {
            # Some data for benchmarks. The count of lines and bytes are printed each second.
            if ($benchmark) {
                my $delta = sprintf("%.6f", Time::HiRes::gettimeofday() - $messurement);
                if ($delta > 1) {
                    $count_bytes = sprintf("%.3fM", $count_bytes > 0 ? $count_bytes / 1_048_576 : 0);
                    $self->log->notice("processed $count_lines lines / $count_bytes bytes in $delta seconds");
                    $messurement = Time::HiRes::gettimeofday();
                    $count_lines = 0;
                    $count_bytes = 0;
                }
            }

            # Check if it's time to process the input.
            if ($input->{time} - Time::HiRes::gettimeofday() > 0) {
                next;
            }

            # The type of the input. Note that the type can be
            # overwritten if the input format is a json event.
            my $itype = $input->{config}->{type};
            my $ipath = $input->{config}->{path};

            # If there are errors detected and no type is set,
            # then shipping log data is blocked for inputs
            # with no type until %failed is empty.
            if (!defined $itype && scalar keys %failed) {
                next;
            }

            # If there exists errors for this type, then the stored
            # lines must be flushed to the outputs first.
            if ($failed{$itype}) {
                $self->log->info("found failed events for input type $itype");

                # Process each failed output until no further outputs exists.
                while (my $ref = shift @{$failed{$itype}}) {
                    my $output = $ref->{output};
                    my $otype  = $ref->{type};
                    my $count  = 0;
                    my $bytes  = 0;

                    # Process each line until the array is empty.
                    $self->log->info("try to process", scalar @{$ref->{lines}}, "events for output type $otype");
                    while (my $line = shift @{$ref->{lines}}) {
                        my ($otype, $event) = $self->prepare_message($input->{config}, $line)
                            or next;

                        # If the output is not available then the last line
                        # is stored back to the array.
                        if (!$output->push($event)) {
                            unshift @{$ref->{lines}}, $line;
                            last;
                        }

                        $count += 1;
                        $bytes += length($line);
                        $count_lines += 1;
                        $count_bytes += $bytes;
                    }

                    if ($count) {
                        $self->log->notice(
                            "output $otype is reachable again -",
                            "flushed $count lines with $bytes bytes"
                        );
                    }

                    # If it wasn't possilbe to ship all events then the
                    # output returns an error. In this case the output
                    # is stored back to the %failed hash.
                    if (@{$ref->{lines}}) {
                        # The error message should only be logged if the output died again.
                        if ($count) {
                            $count = scalar @{$ref->{lines}};
                            $bytes = length join("", @{$ref->{lines}});
                            $self->log->error(
                                "output $otype returns an error again -",
                                "held $count lines with $bytes bytes in stash"
                            );
                        }
                        unshift @{$failed{$itype}}, $ref;
                        last;
                    }
                }

                # If no items left, then the input type can be deleted
                # and processed again in the next run.
                if (!@{$failed{$itype}}) {
                    delete $failed{$itype};
                }

                # Process the next input.
                next;
            }

            # Get events from the input.
            $self->log->debug("pull lines from input type $itype path $ipath");
            my $lines = $input->{object}->pull(lines => $max_lines);

            # If no lines exists, just jump to the next input and
            # process the input at time + poll.
            if (!$lines || !@$lines) {
                $input->{time} = Time::HiRes::gettimeofday() + $poll;
                next;
            }

            # If the input return events then the global interval
            # is set to now, so the sleep value should be 0.
            $time = Time::HiRes::gettimeofday();
            $self->log->debug("pulled", scalar @$lines, "lines from input type $itype path $ipath");

            # Process each event and store each event by the output type.
            my (%prepared_events, %lines_by_type);
            while (my $line = shift @$lines) {
                my ($otype, $event) = $self->prepare_message($input->{config}, $line)
                    or next;
                push @{$prepared_events{$otype}}, $event;
                push @{$lines_by_type{$otype}}, $line;
            }

            foreach my $otype (keys %prepared_events) {
                my $events = $prepared_events{$otype};
                if (!exists $outputs->{$otype}) {
                    $self->log->warning("received events from input type $itype with an non existent output type $otype");
                }
                foreach my $output (@{$outputs->{$otype}}) {
                    for (my $i=0; $i <= $#{$events}; $i++) {
                        if (!$output->push($events->[$i])) {
                            my $left  = [ @{$lines_by_type{$otype}}[$i..$#{$events}] ];
                            my $count = $#{$events} - $i;
                            my $bytes = length join("", @$left);
                            $self->log->error(
                                "output $otype returns an error -",
                                "stashing $count lines with $bytes bytes"
                            );
                            push @{$failed{$itype}}, {
                                type   => $otype,
                                output => $output,
                                lines  => $left,
                            };
                            last;
                        } else {
                            $count_lines += 1;
                            $count_bytes += length $lines_by_type{$otype}[$i];
                            $self->log->debug("wrote event $i/$#{$events} to output $otype");
                        }
                    }
                }
            }
        }

        $time -= Time::HiRes::gettimeofday();

        if ($time > 0 && $self->{done} == 0) {
            $self->log->debug(sprintf("sleep for %.6f seconds", $time));
            Time::HiRes::usleep($time * 1_000_000);
        }
    }
}

sub prepare_message {
    my ($self, $input, $line) = @_;
    my ($event, $type, $timestamp);

    $self->log->debug("prepare message for input type $input->{type} path $input->{path}");
    $self->log->debug("event: $line");

    if ($input->{format} eq "json_event") {
        eval { $event = $self->json->decode($line) };
        if ($@) {
            $self->log->error("unable to decode json event for input $input->{type}:", $@);
            $self->log->error($line);
            return ();
        }
        $event->{'@type'} ||= $input->{type};
        push @{$event->{'@tags'}}, @{$input->{tags}};
        foreach my $field (keys %{$input->{add_field}}) {
            $event->{$field} = $input->{add_field}->{$field};
        }
    } elsif ($input->{format} eq "plain") {
        $timestamp = POSIX::strftime("%Y-%m-%dT%H:%M:%S%z", localtime(time));
        $timestamp =~ s/(\d{2})(\d{2})\z/$1:$2/;
        $event = {
            '@timestamp'   => $timestamp,
            '@source'      => "file://" . $self->{hostname} . $input->{path},
            '@source_host' => $self->{hostname},
            '@source_path' => $input->{path},
            '@type'        => $input->{type},
            '@fields'      => $input->{add_field},
            '@tags'        => $input->{tags},
            '@message'     => $line,
        };
    };

    if ($input->{__add_field}) {
        foreach my $code (@{$input->{__add_field_code}}) {
            &$code($event);
        }
    }

    return ($event->{'@type'}, $self->json->encode($event));
}

sub get_config {
    my $self = shift;

    my $config = Awesant::Config->parse(
        $self->{args}->{config}
    );

    $self->{config} = $self->validate_config($config);
}

sub write_pidfile {
    my $self = shift;                                                                                                               
    open my $fh, ">", $self->{args}->{pidfile}
        or die "unable to write pid file $self->{args}->{pidfile}: $!";
    print $fh $$;
    close $fh;
}

sub remove_pidfile {
    my $self = shift;

    if (-f $self->{args}->{pidfile}) {
        unlink($self->{args}->{pidfile});
            # "or die" is not necessaray because
            # awesant stop running
    }
}

sub create_logger {
    my $self = shift;

    $self->{log} = Log::Handler->create_logger("awesant");

    if ($self->config->{logger}) {
        $self->{log}->config(config => $self->config->{logger});
    }
}

sub spawn_children {
    my $self = shift;

    foreach my $group (keys %{ $self->process_group }) {
        my $process_group = $self->process_group->{$group};
        my $current_worker = scalar keys %{$process_group->{child}};
        my $wanted_worker = $process_group->{workers};

        if ($current_worker < $wanted_worker) {
            for (1..$wanted_worker - $current_worker) {
                # Fork a new child.
                my $pid = fork;

                if ($pid) {
                    # If $pid is set, then it's the parent.
                    $self->{child}->{$pid} = $group;
                    # The pid is stored to the process group just to
                    # count how many processes are running for the group.
                    $process_group->{child}->{$pid} = $group;
                    # Hoa yeah! A new perl machine was born! .-)
                    $self->log->info("forked child $pid for process group $group");
                } elsif (!defined $pid) {
                    # If the $pid is undefined then fork failed.
                    die "unable to fork - $!";
                } else {
                    # If the pid is defined then it's the child.
                    eval { $self->run_agent($process_group->{inputs}) };
                    exit($? ? 9 : 0);
                }
            }
        }
    }
}

sub reap_children {
    my $self = shift;
    my $child = $self->{child};
    my $reaped = $self->{reaped};
    my @reaped = keys %$reaped;

    foreach my $pid (@reaped) {
        my $group = delete $child->{$pid};
        delete $self->process_group->{$group}->{child}->{$pid};
        delete $reaped->{$pid};
    }
}

sub kill_children {
    my $self  = shift;
    my $child = $self->{child};
    my @chld  = keys %$child;

    # Don't TERM the daemon. At first we reap all children.
    local $SIG{TERM} = "IGNORE";

    # Give the children 15 seconds time to stop.
    my $wait = time + 15;

    # Try to kill the agents soft.
    $self->log->info("send sig term to children", @chld);
    kill 15, @chld;

    while (@chld && $wait > time) {
        $self->log->info("wait for children", @chld);
        sleep 1;
        $self->reap_children;
        @chld = keys %$child;
    }

    # All left children will be killed hard.
    if (scalar keys %$child) {
        @chld = keys %$child;
        $self->log->info("send sig kill to children", @chld);
        kill 9, @chld;
    }
}

sub sig_child_handler {
    my $self = shift;

    while ((my $child = waitpid(-1, WNOHANG)) > 0) {
        if ($? > 0) {
            $self->log->error("child $child died: $?");
        } else {
            $self->log->notice("child $child died: $?");
        }

        # Store the PID to delete the it later from $self->{child}
        $self->{reaped}->{$child} = $child;
    }

    $SIG{CHLD} = sub { $self->sig_child_handler(@_) };
}

sub validate_config {
    my $self = shift;

    my %options = Params::Validate::validate(@_, {
        poll => {
            type => Params::Validate::SCALAR,
            regex => qr/^(?:[1-9]\d\d\d|[1-9]\d\d)\z/,
            default => 500,
        },
        lines => {
            type => Params::Validate::SCALAR,
            default => 100,
        },
        output => {
            type => Params::Validate::HASHREF,
        },
        input => {
            type => Params::Validate::HASHREF,
        },
        logger => {
            type => Params::Validate::HASHREF,
            optional => 1,
        },
        benchmark => {
            type => Params::Validate::SCALAR,
            regex => qr/^(?:yes|no|0|1)\z/,
            default => 0,
        },
    });

    if ($options{benchmark} eq "no") {
        $options{benchmark} = 0;
    }

    foreach my $key (qw/output input/) {
        my $ref = $options{$key};
        foreach my $type (keys %$ref) {
            if (ref $ref->{$type} eq "HASH") {
                $ref->{$type} = [ $ref->{$type} ];
            }
        }
    }

    return \%options;
}

sub validate_agent_config {
    my $self = shift;

    my %options = Params::Validate::validate(@_, {
        type => {
            type => Params::Validate::SCALAR,
        },
        tags => {
            type => Params::Validate::SCALAR
                    | Params::Validate::ARRAYREF,
            default => [ ],
        },
        format => {
            type => Params::Validate::SCALAR,
            regex => qr/^(?:plain|json_event)\z/,  
            default => "plain",
        },
        add_field => {
            type => Params::Validate::SCALAR
                    | Params::Validate::HASHREF
                    | Params::Validate::ARRAYREF,
            default => { },
        },
        __add_field => {
            type => Params::Validate::HASHREF,
            optional => 1,
        },
        path => {
            type => Params::Validate::SCALAR,
            default => "/",
        },
        workers => {
            type => Params::Validate::SCALAR,
            regex => qr/^\d+\z/,
            default => 0,
        },
    });

    # add_field => {
    #     domain => {
    #         key    => '@source_path',
    #         match  => "([a-z]+\.[a-z]+)/([a-z]+)/[^/]+$",
    #         concat => "$2.$1",
    #     }
    # }

    if (defined $options{add_field}) {
        if (ref $options{add_field} eq "ARRAY") {
            $options{add_field} = { @{$options{add_field}} };
        } elsif (ref $options{add_field} ne "HASH") {
            my @fields;
            foreach my $field (split /,/, $options{add_field}) {
                $field =~ s/^\s+//;
                $field =~ s/\s+\z//;
                push @fields, $field;
            }
            $options{add_field} = { @fields };
        }
    }

    if (defined $options{__add_field}) {
        foreach my $field (keys %{$options{__add_field}}) {
            my $ref = $options{__add_field}{$field};

            # The code generation. I'm sorry that it's a bit unreadable.
            my $func = "sub { my (\$e) = \@_; if (\$e->{'$ref->{field}'} =~ m!$ref->{match}!) { ";
            $func .= "\$e->{'\@fields'}->{'$field'} = \"$ref->{concat}\"; }";
            if (defined $ref->{default}) {
                $func .= " else { \$e->{'\@fields'}->{'$field'} = '$ref->{default}'; } ";
            }
            $func .= "}";

            # Eval the code.
            my $code = eval $func;
            push @{$options{__add_field_func}}, $func;
            push @{$options{__add_field_code}}, $code;
        }
    }

    if (defined $options{tags} && ref $options{tags} ne "ARRAY") {
        my $tags = $options{tags};
        $options{tags} = [ ];
        foreach my $tag (split /,/, $tags) {
            $tag =~ s/^\s+//;
            $tag =~ s/\s+\z//;
            push @{$options{tags}}, $tag;
        }
    }

    return \%options;
}

sub validate_add_field_match {
    my $self = shift;

    my %options = Params::Validate::validate(@_, {
        field => {
            type => Params::Validate::SCALAR,
            regex => qr/^\w+\z/,
        },
        match => {
            type => Params::Validate::SCALAR,
        },
        concat => {
            type => Params::Validate::SCALAR,
            regex => qr/^[^"]+\z/,
        },
        default => {
            type => Params::Validate::SCALAR,
            regex => qr/^[^']+\z/,
            optional => 1,
        },
    });

    return \%options;
}

1;
