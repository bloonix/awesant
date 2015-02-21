=head1 NAME

Awesant::Input::File - Files as input.

=head1 SYNOPSIS

    # Create a new tail-like object.
    my $input = Awesant::Input::File->new(
        path => "/var/log/messages",
        save_position => "yes", # experimental
    );

    # Pull the next 100 lines that was appended
    # to the log file.
    $input->pull(lines => 100);

=head1 DESCRIPTION

Log files as input. Log file rotation is supported, but note that
you should configure delayed compression for log files.

=head1 OPTIONS

=head2 path

The path to the log file. Multiple paths can be set as comma separated list.

    input {
        file {
            type syslog
            path /var/log/messages, /var/log/syslog
        }
    }

=head2 skip

Define regexes to skip events.

    input {
        file {
            type php-error-log
            path /var/log/php/error.log
            skip PHP (Notice|Warning)
            skip ^any event$
        }
    }

Lines that match the regexes will be skipped.

=head2 save_position

Experimental feature.

If the option save_position is set to 'yes' then the last position
with the inode of the log file is saved to a file. If Awesant is down
then it can resume its work where it was stopped. This is useful if you
want to lose as less data as possible of your log files.

Please note that this feature is experimental and does not keep log file
rotations.

=head1 METHODS

=head2 new

Create a new input object.

=head2 get_lastpos

Get the last position if the option C<save_position> is true.

=head2 open_logfile

Open the log file and store the inode for later checks.

=head2 check_logfile

This method just checks if the inode has changed of the currently opened
file and the file that is found on the file system. If logrotate moved
the file, then the inode changed. In this case the rotated file is read
until its end and then the file will be closed to re-open the new file
on the file system.

=head2 pull(lines => $number)

This methods reads the excepted number of lines or until the end of the
file and returns the lines as a array reference.

=head2 validate

Validate the configuration that is passed to the C<new> constructor.

=head2 log

Just a accessor to the logger.

=head2 check_event

This method is call for each event and checks filters the event by options C<skip> and C<grep>.

=head1 PREREQUISITES

    Fcntl
    Params::Validate
    Log::Handler

=head1 EXPORTS

No exports.

=head1 REPORT BUGS

Please report all bugs to <support(at)bloonix.de>.

=head1 AUTHOR

Jonny Schulz <support(at)bloonix.de>.

=head1 COPYRIGHT

Copyright (C) 2012 by Jonny Schulz. All rights reserved.

=cut


package Awesant::Input::File;

use strict;
use warnings;
use Digest::MD5;
use Fcntl qw( :flock O_WRONLY O_CREAT O_RDONLY );
use Params::Validate qw();
use Log::Handler;

sub new {
    my $class = shift;
    my $opts = $class->validate(@_);
    my $self = bless $opts, $class;

    $self->{log} = Log::Handler->get_logger("awesant");
    $self->{reached_end_of_file} = 0;
    $self->get_lastpos;
    $self->open_logfile;
    $self->log->info("$class initialized");

    return $self;
}

sub get_lastpos {
    my $self = shift;
    my $file = $self->{path};
    my $libdir = $self->{libdir};
    my $inode = "";

    if ($self->{start_position} eq "begin") {
        $self->{lastpos} = 0;
    } else {
        $self->{lastpos} = -e $file ? (stat($file))[7] : 0;
    }

    if (!$self->{save_position}) {
        return;
    }

    my $old_basename = $self->{path};
    $old_basename =~ s!%!%%!g;
    $old_basename =~ s!/!%!g;
    my $old_posfile = "$libdir/awesant-$old_basename.pos";

    my $basename = Digest::MD5::md5_hex($self->{path});
    my $posfile = "$libdir/awesant-$basename.pos";

    if (-e $old_posfile) {
        rename $old_posfile, $posfile;
    }

    if (-e $posfile) {
        $self->log->debug("read last position from $posfile");
        open my $fh, "<", $posfile or die "unable to open '$posfile' for reading - $!";
        my $line = <$fh>;
        my ($inode, $lastpos) = split /:/, $line;

        if (defined $inode && defined $lastpos && $inode =~ /^\d+\z/ && $lastpos =~ /^\d+\z/) {
            $inode =~ s/^0+//;
            $lastpos =~ s/^0+//;

            if (-e $file && (stat($file))[1] eq $inode) {
                $self->{lastpos} = $lastpos;
            }
        }

        close $fh;
    }

    $self->log->debug("last position $self->{lastpos}");
    $self->log->debug("open '$posfile' for writing");
    sysopen my $fhpos, $posfile, O_CREAT | O_WRONLY
        or die "unable to open '$posfile' for writing - $!";

    # autoflush
    my $oldfh = select $fhpos;
    $| = 1;
    select $oldfh;

    # save the file handle for later usage
    $self->{fhpos} = $fhpos;
}

sub open_logfile {
    my $self = shift;
    my $file = $self->{path};
    my $fhlog = $self->{fhlog};

    if ($fhlog && $self->check_logfile) {
        return $fhlog;
    }

    $self->log->info("open '$file' for reading");

    open $fhlog, "<", $file or do {
        $self->log->info("unable to open logfile '$file' for reading - $!");
        return undef;
    };

    # Store the inode for the logfile to check
    # later if the inode changed because logrotate
    # moves the file.
    $self->{inode} = (stat($file))[1];
    $self->log->debug("stored inode $self->{inode} for file '$file'");

    # If fhlog is already set then we just reopen the next
    # file and jump to the start of the file, otherwise
    # a log file wasn't opened before and we jump to the
    # position of get_lastpos
    if ($self->{fhlog}) {
        $self->{lastpos} = 0;
    }

    $self->log->info("seek to position $self->{lastpos} of file '$file'");
    seek($fhlog, $self->{lastpos}, 0);
    $self->{fhlog} = $fhlog;
    return $fhlog;
}

sub check_logfile {
    my $self  = shift;
    my $file  = $self->{path};
    my $inode = $self->{inode};
    my $fhlog = $self->{fhlog};

    # If the end logfile of the logfile is not reached... go forward.
    if ($self->{reached_end_of_file} == 0) {
        #$self->log->debug("skip check logfile - reached_end_of_file=$self->{reached_end_of_file}");
        return 1;
    }

    # If the end of the logfile is reached and we see that the logfile does
    # not exist or the inode has changed, the rest of the logfile is read.
    # Then, if reached_end_of_file is set higher than 9 it means that the
    # real end is reached. (reached_end_of_file of 20 = 20 loops * 500ms = 10seconds)
    if ($self->{reached_end_of_file} < 20 && (!-e $file || $inode != (stat($file))[1])) {
        return 1
    }

    # Clean up the eof marker
    $self->{reached_end_of_file} = 0;

    # Check if the logfile exists.
    if (!-e $file) {
        $self->log->info("the log file '$file' does not exists any more");
        close $fhlog;
        $self->{fhlog} = undef;
        return 0;
    }

    # Check if the inode has changed, because it's possible
    # that logrotate.d rotates the log file.
    if ($inode != (stat($file))[1]) {
        $self->log->info("inode of file '$file' changed - closing file handle");
        $self->{fhlog} = undef;
        close $fhlog;
        return 0;
    }

    # Check if the the current position where the log file was
    # read is higher than the file size. It's possible that
    # the logfile was flushed.
    if ((stat($file))[7] < $self->{lastpos}) {
        $self->log->info("the size of file '$file' shrinks - seeking back");
        seek($fhlog, 0, 0);
        $self->{lastpos} = 0;
    } 

    return 1;
}

sub pull {
    my ($self, %opts) = @_;

    local $SIG{PIPE} = "IGNORE";

    my $max_lines = $opts{lines} || 1;
    my $lines = [ ];
    my $fhpos = $self->{fhpos};
    my $fhlog = $self->open_logfile
        or return undef;

    while (my $line = <$fhlog>) {
        chomp $line;

        if ($self->check_event($line)) {
            push @$lines, $line;
        }

        #$self->log->debug("read", length($line), "bytes from file");
        last unless --$max_lines;
    }

    # Store the last position
    $self->{lastpos} = tell($fhlog);

    if ($self->{fhpos}) {
        seek($fhpos, 0, 0);
        printf $fhpos "%014d:%014d", $self->{inode}, $self->{lastpos};
    }

    # If EOF is reached then the logfile should be
    # checked if the file was rotated.
    if ($max_lines > 0) {
        $self->log->debug("reached end of file");
        $self->{reached_end_of_file}++;
    }

    return $lines;
}

sub validate {
    my $self = shift;

    my %options = Params::Validate::validate(@_, {
        libdir => {
            type => Params::Validate::SCALAR,
            default => "/var/lib/awesant"
        },
        start_position => {
            type => Params::Validate::SCALAR,
            default => "end",
            regex => qr/^(begin|end)\z/
        },
        save_position => {
            type => Params::Validate::SCALAR,
            default => 0,
            regex => qr/^(?:yes|no|1|0)\z/
        },
        path => {
            type => Params::Validate::SCALAR,
        },
        skip => {
            type => Params::Validate::SCALAR | Params::Validate::ARRAYREF,
            default => undef
        },
        grep => {
            type => Params::Validate::SCALAR | Params::Validate::ARRAYREF,
            default => undef
        }
    });

    foreach my $key (qw/skip grep/) {
        if (defined $options{$key} && ref $options{$key} ne "ARRAY") {
            $options{$key} = [ $options{$key} ];
        }
    }

    if ($options{save_position} eq "no") {
        $options{save_position} = 0;
    }

    return \%options;
}

sub log {
    my $self = shift;

    return $self->{log};
}

sub check_event {
    my ($self, $event) = @_;

    if ($self->{skip}) {
        foreach my $regex (@{$self->{skip}}) {
            if ($event =~ /$regex/) {
                return 0;
            }
        }
    }

    if ($self->{grep}) {
        foreach my $regex (@{$self->{grep}}) {
            if ($event =~ /$regex/) {
                return 1;
            }
        }
        return 0;
    }

    return 1;
}

1;
