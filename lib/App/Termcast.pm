package App::Termcast;
use Moose;
# ABSTRACT: broadcast your terminal sessions for remote viewing

with 'MooseX::Getopt::Dashes';

use IO::Socket::INET;
use JSON;
use Scalar::Util 'weaken';
use Select::Retry;
use Term::Filter;
use Term::ReadKey;
use Try::Tiny;

=head1 SYNOPSIS

  my $tc = App::Termcast->new(user => 'foo');
  $tc->run('bash');

=head1 DESCRIPTION

App::Termcast is a client for the L<http://termcast.org/> service, which allows
broadcasting of a terminal session for remote viewing.

=cut

=attr host

Server to connect to (defaults to noway.ratry.ru, the host for the termcast.org
service).

=cut

has host => (
    is      => 'rw',
    isa     => 'Str',
    default => 'noway.ratry.ru',
    documentation => 'Hostname of the termcast server to connect to',
);

=attr port

Port to use on the termcast server (defaults to 31337).

=cut

has port => (
    is      => 'rw',
    isa     => 'Int',
    default => 31337,
    documentation => 'Port to connect to on the termcast server',
);

=attr user

Username to use (defaults to the local username).

=cut

has user => (
    is      => 'rw',
    isa     => 'Str',
    default => sub { $ENV{USER} },
    documentation => 'Username for the termcast server',
);

=attr password

Password for the given user. The password is set the first time that username
connects, and must be the same every subsequent time. It is sent in plaintext
as part of the connection process, so don't use an important password here.
Defaults to 'asdf' since really, a password isn't all that important unless
you're worried about being impersonated.

=cut

has password => (
    is      => 'rw',
    isa     => 'Str',
    default => 'asdf', # really unimportant
    documentation => "Password for the termcast server\n"
                   . "                              (mostly unimportant)",
);

=attr bell_on_watcher

Whether or not to send a bell to the terminal when a watcher connects or
disconnects. Defaults to false.

=cut

has bell_on_watcher => (
    is      => 'rw',
    isa     => 'Bool',
    default => 0,
    documentation => "Send a terminal bell when a watcher connects\n"
                   . "                              or disconnects",
);

=attr timeout

How long in seconds to use for the timeout to the termcast server. Defaults to
5.

=cut

has timeout => (
    is      => 'rw',
    isa     => 'Int',
    default => 5,
    documentation => "Timeout length for the connection to the termcast server",
);

=method establishment_message

Returns the string sent to the termcast server when connecting (typically
containing the username and password)

=cut

has establishment_message => (
    traits     => ['NoGetopt'],
    is         => 'ro',
    isa        => 'Str',
    lazy_build => 1,
);

sub _build_establishment_message {
    my $self = shift;
    return sprintf("hello %s %s\n", $self->user, $self->password);
}

sub _termsize {
    return try { GetTerminalSize() } catch { (undef, undef) };
}

=method termsize_message

Returns the string sent to the termcast server whenever the terminal size
changes.

=cut

sub termsize_message {
    my $self = shift;

    my ($cols, $lines) = $self->_termsize;

    return '' unless $cols && $lines;

    return $self->_form_metadata_string(
        geometry => [ $cols, $lines ],
    );
}

has socket => (
    traits     => ['NoGetopt'],
    is         => 'rw',
    isa        => 'IO::Socket::INET',
    lazy_build => 1,
    init_arg   => undef,
);

sub _form_metadata_string {
    my $self = shift;
    my %data = @_;

    my $json = JSON::encode_json(\%data);

    return "\e[H\x00$json\xff\e[H\e[2J";
}

sub _build_socket {
    my $self = shift;

    my $socket;
    {
        $socket = IO::Socket::INET->new(PeerAddr => $self->host,
                                        PeerPort => $self->port);
        if (!$socket) {
            Carp::carp "Couldn't connect to " . $self->host . ": $!";
            sleep 5;
            redo;
        }
    }

    syswrite $socket, $self->establishment_message . $self->termsize_message;

    # ensure the server accepted our connection info
    # can't use _build_select_args, since that would cause recursion
    {
        my ($rout, $eout) = retry_select('r', undef, $socket);

        if (vec($eout, fileno($socket), 1)) {
            Carp::croak("Invalid password");
        }
        elsif (vec($rout, fileno($socket), 1)) {
            my $buf;
            $socket->recv($buf, 4096);
            if (!defined $buf || length $buf == 0) {
                Carp::croak("Invalid password");
            }
            elsif ($buf ne ('hello, ' . $self->user . "\n")) {
                Carp::carp("Unknown login response from server: $buf");
            }
        }
    }

    # XXX Term::Filter should maybe handle this?
    ReadMode 5 if $self->_has_term && $self->_term->_raw_mode;
    return $socket;
}

before clear_socket => sub {
    my $self = shift;
    Carp::carp("Lost connection to server ($!), reconnecting...");
    # XXX Term::Filter should maybe handle this?
    ReadMode 0 if $self->_has_term && $self->_term->_raw_mode;
};

sub _new_socket {
    my $self = shift;
    $self->clear_socket;
    $self->socket;
}

has _needs_termsize_update => (
    traits  => ['NoGetopt'],
    is      => 'rw',
    isa     => 'Bool',
    default => 0,
);

has _term => (
    is        => 'ro',
    isa       => 'Term::Filter',
    lazy      => 1,
    predicate => '_has_term',
    default   => sub {
        my $_self = shift;
        weaken(my $self = $_self);
        Term::Filter->new(
            callbacks => {
                setup => sub {
                    my ($term) = @_;
                    $term->add_input_handle($self->socket);
                },
                winch => sub {
                    # for the sake of sending a clear to the client anyway
                    syswrite $self->output, "\e[H\e[2J";
                    $self->_needs_termsize_update(1);
                },
                read_error => sub {
                    my ($term, $eout) = @_;
                    if (vec($eout, fileno($self->socket), 1)) {
                        $self->_new_socket;
                    }
                },
                read => sub {
                    my ($term, $rout) = @_;
                    if (vec($rout, fileno($self->socket), 1)) {
                        my $got = $term->_read_from_handle(
                            $self->socket, "socket"
                        );
                        $self->_new_socket unless defined $got;

                        if ($self->bell_on_watcher) {
                            # something better to do here?
                            syswrite $self->output, "\a";
                        }
                    }
                },
                munge_output => sub {
                    my ($event, $buf) = @_;
                    $self->write_to_termcast($buf);
                    $buf;
                },
            },
        );
    },
    handles => [ 'run', 'input', 'output' ],
);

=method write_to_termcast $BUF

Sends C<$BUF> to the termcast server.

=cut

sub write_to_termcast {
    my $self = shift;
    my ($buf) = @_;

    my $socket = $self->socket;

    my ($wout, $eout) = retry_select(
        'w', $self->timeout, $socket
    );

    if (!vec($wout, fileno($socket), 1) || vec($eout, fileno($socket), 1)) {
        $self->clear_socket;
        return $self->write_to_termcast(@_);
    }

    if ($self->_needs_termsize_update) {
        $buf = $self->termsize_message . $buf;
        $self->_needs_termsize_update(0);
    }

    $self->socket->syswrite($buf);
}

=method run @ARGV

Runs the given command in the local terminal as though via C<exec>, but streams
all output from that command to the termcast server. The command may be an
interactive program (in fact, this is the most useful case).

=cut

__PACKAGE__->meta->make_immutable;
no Moose;

=head1 TODO

Use L<MooseX::SimpleConfig> to make configuration easier.

=head1 BUGS

No known bugs.

Please report any bugs through RT: email
C<bug-app-termcast at rt.cpan.org>, or browse to
L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=App-Termcast>.

=head1 SEE ALSO

L<http://termcast.org/>

=head1 SUPPORT

You can find this documentation for this module with the perldoc command.

    perldoc App::Termcast

You can also look for information at:

=over 4

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/App-Termcast>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/App-Termcast>

=item * RT: CPAN's request tracker

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=App-Termcast>

=item * Search CPAN

L<http://search.cpan.org/dist/App-Termcast>

=back

=cut

1;
