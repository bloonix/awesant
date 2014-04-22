=head1 NAME

Awesant::Config - Configuration file parser.

=head1 SYNOPSIS

    my $config = Awesant::Config->parse($file);

=head1 DESCRIPTION

This module is just for internal usage.

=head1 CONFIGURATION FORMAT

=head2 SELF-EXPLANATORY

The configuration format is very simple:

    param1 value
    param2 value
    param3 " value value value "
    param4 ' value value value '
    param5 multiline \
           value
    param6 " multiline values " \
           " with whitespaces "

    section1 {
        param1 value
        param2 value

        subsection1 {
            param1 value
            param2 value
        }
    }

=head2 COMMENTS

Add comments to the configuration to explain parameter:

    # Comment
    param1 value # comment
    param2 value#value # comment
    param3 'value \# value' # comment
    param4 multiline \ # comment
           value
    param5 " multiline values " \ # comment
           " with whitespaces " # comment

=head2 HASHES VS ARRRAYS

Please note that if a hash key exists that the values will be pushed into an array:

    param1 value
    param2 value1
    param2 value2

    section1 {
        param value
    }
    section2 {
        param value
    }
    section2 {
        param value
    }

is

    param1 => "value",
    param2 => [ "value1", "value2" ],
    section1 => { param => "value" },
    section2 => [
        { param => "value" },
        { param => "value" }
    ]

=head1 FUNCTIONS

=head2 C<parse>

Pass the configuration file as argument and a hash reference with the
parsed configuration will be returned.

=head1 PREREQUISITES

No prerequisites.

=head1 EXPORTS

No exports.

=head1 REPORT BUGS

Please report all bugs to <support(at)bloonix.de>.

=head1 AUTHOR

Jonny Schulz <support(at)bloonix.de>.

=head1 COPYRIGHT

Copyright (C) 2012 by Jonny Schulz. All rights reserved.

=cut

package Awesant::Config;

use strict;
use warnings;

sub parse {
    my ($class, $file) = @_;

    open my $fh, "<", $file
        or die "Unable to open file '$file' for reading - $!";

    my $config = { };

    $class->_parse_config($fh, $config);

    close $fh;
    return $config;
}

sub _parse_config {
    my ($self, $fh, $config) = @_;
    my ($key, $value, @multiline, $is_multiline);

    while (my $line = <$fh>) {
        # Prepare the line and cut newline, comments
        # and whitespaces from the begin and the end
        # of each line.
        $line =~ s/[\r\n]+\z//;
        $line =~ s/^\s*#.*//;
        $line =~ s/\s+#.+//;
        $line =~ s/\\#/#/g;
        $line =~ s/^\s+//;
        $line =~ s/\s+\z//;

        # Comments and whitespaces was removed.
        # Empty lines will be ignored.
        if (!length $line) {
            next;
        }

        # The end of a section ends with "}"
        if ($line =~ /^\s*\}/) {
            return;
        }

        # If the parameter was marked as multiline parameter
        # then the raw line will be stored as value.
        if ($is_multiline) {
            $value = $line;
        }

        # If a line begins with "keyword {" then it's a sub-section.
        elsif ($line =~ /^([^\s]+)\s*\{/) {
            ($key, $value) = ($1, { });
            $self->_add_key_value($config, $key, $value);
            $self->_parse_config($fh, $value);
            next;
        }
        elsif ($line =~ /^\s*include\s*(.*)/) {
          open my $fh_subconfig, "<", $1
               or die "Unable to open file '$1' for reading - $!";
          $self->_parse_config($fh_subconfig, $config);
          close $fh_subconfig;
          undef $fh_subconfig;
          next;
        }

        # A key value pair. The value can be an empty string.
        elsif ($line =~ /^([^\s]+)\s*(.*)/) {
            ($key, $value) = ($1, $2);
        }

        # Look if the end of the line is marked as multiline.
        $is_multiline = $value =~ s/\s*\\\z//;

        # Remove the quotes of quoted values.
        if ($value =~ /^'(.*)'\z/ || $value =~ /^"(.*)"\z/) {
            $value = $1;
        }

        # If the line is marked as multiline, then just
        # push the value into a temporary array.
        if ($is_multiline) {
            push @multiline, $value;
            next;
        }

        # If the last parsed parameter was a multine parameter,
        # then the array @multiline contains the values.
        if (@multiline) {
            $value = join(" ", @multiline, $value);
            @multiline = ();
        }

        # Add the key value pair to the config.
        $self->_add_key_value($config, $key, $value);
    }
}

sub _add_key_value {
    my ($class, $config, $key, $value) = @_;

    if (!exists $config->{$key}) {
        $config->{$key} = $value;
    } elsif (ref $config->{$key} eq "ARRAY") {
        push @{$config->{$key}}, $value;
    } else {
        $config->{$key} = [ $config->{$key}, $value ];
    }
}

1;
