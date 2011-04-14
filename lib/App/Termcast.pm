package App::Termcast;
use Moose;
# ABSTRACT: broadcast your terminal sessions for remote viewing

with 'MooseX::Getopt::Dashes';

use IO::Pty::Easy;
use IO::Socket::INET;
use Scope::Guard;
use Term::ReadKey;

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

has _got_winch => (
    traits   => ['NoGetopt'],
    is       => 'rw',
    isa      => 'Bool',
    default  => 0,
    init_arg => undef,
);

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

has socket => (
    traits     => ['NoGetopt'],
    is         => 'rw',
    isa        => 'IO::Socket::INET',
    lazy_build => 1,
    init_arg   => undef,
);

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

    $socket->syswrite($self->establishment_message);

    # ensure the server accepted our connection info
    # can't use _build_select_args, since that would cause recursion
    {
        my ($rin, $ein, $rout, $eout) = ('') x 4;
        vec($rin, fileno($socket), 1) = 1;
        vec($ein, fileno($socket), 1) = 1;
        my $res = select($rout = $rin, undef, $eout = $ein, undef);
        redo if ($!{EAGAIN} || $!{EINTR}) && $res == -1;
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

    ReadMode 5 if $self->_raw_mode;
    return $socket;
}

before clear_socket => sub {
    my $self = shift;
    Carp::carp("Lost connection to server ($!), reconnecting...");
    ReadMode 0 if $self->_raw_mode;
};

sub new_socket {
    my $self = shift;
    $self->clear_socket;
    $self->socket;
}

has pty => (
    traits     => ['NoGetopt'],
    is         => 'rw',
    isa        => 'IO::Pty::Easy',
    lazy_build => 1,
    init_arg   => undef,
);

sub _build_pty {
    IO::Pty::Easy->new(raw => 0);
}

has _raw_mode => (
    traits  => ['NoGetopt'],
    is      => 'rw',
    isa     => 'Bool',
    default => 0,
    trigger => sub {
        my $self = shift;
        my ($val) = @_;
        if ($val) {
            ReadMode 5;
        }
        else {
            ReadMode 0;
        }
    },
);

sub _build_select_args {
    my $self = shift;
    my @for = @_ ? @_ : (qw(socket pty input));
    my %for = map { $_ => 1 } @for;

    my ($rin, $win, $ein) = ('', '', '');
    if ($for{socket}) {
        my $sockfd = fileno($self->socket);
        vec($rin, $sockfd, 1) = 1;
        vec($win, $sockfd, 1) = 1;
        vec($ein, $sockfd, 1) = 1;
    }
    if ($for{pty}) {
        my $ptyfd  = fileno($self->pty);
        vec($rin, $ptyfd,  1) = 1;
    }
    if ($for{input}) {
        my $infd   = fileno(STDIN);
        vec($rin, $infd   ,1) = 1;
    }

    return ($rin, $win, $ein);
}

sub _socket_ready {
    my $self = shift;
    my ($vec) = @_;
    vec($vec, fileno($self->socket), 1);
}

sub _pty_ready {
    my $self = shift;
    my ($vec) = @_;
    vec($vec, fileno($self->pty), 1);
}

sub _in_ready {
    my $self = shift;
    my ($vec) = @_;
    vec($vec, fileno(STDIN), 1);
}

=method write_to_termcast $BUF

Sends C<$BUF> to the termcast server.

=cut

sub write_to_termcast {
    my $self = shift;
    my ($buf) = @_;

    my ($rin, $win, $ein) = $self->_build_select_args('socket');
    my ($rout, $wout, $eout);
    my $ready = select(undef, $wout = $win, $eout = $ein, $self->timeout);
    if (!$ready || $self->_socket_ready($eout)) {
        $self->clear_socket;
        return $self->write_to_termcast(@_);
    }
    $self->socket->syswrite($buf);
}

=method run @ARGV

Runs the given command in the local terminal as though via C<exec>, but streams
all output from that command to the termcast server. The command may be an
interactive program (in fact, this is the most useful case).

=cut

sub run {
    my $self = shift;
    my @cmd = @_;

    $self->socket;

    $self->_raw_mode(1);
    my $guard = Scope::Guard->new(sub { $self->_raw_mode(0) });

    $self->pty->spawn(@cmd) || die "Couldn't spawn @cmd: $!";

    local $SIG{WINCH} = sub {
        $self->_got_winch(1);
        $self->pty->slave->clone_winsize_from(\*STDIN);
        $self->pty->kill('WINCH', 1);
    };

    while (1) {
        my ($rin, $win, $ein) = $self->_build_select_args;
        my ($rout, $wout, $eout);
        my $select_res = select($rout = $rin, undef, $eout = $ein, undef);
        my $again = $!{EAGAIN} || $!{EINTR};

        if (($select_res == -1 && $again) || $self->_got_winch) {
            $self->_got_winch(0);
            redo;
        }

        if ($self->_socket_ready($eout)) {
            $self->new_socket;
        }

        if ($self->_in_ready($rout)) {
            my $buf;
            sysread STDIN, $buf, 4096;
            if (!defined $buf || length $buf == 0) {
                Carp::croak("Error reading from stdin: $!")
                    unless defined $buf;
                last;
            }

            $self->pty->write($buf);
        }

        if ($self->_pty_ready($rout)) {
            my $buf = $self->pty->read(0);
            if (!defined $buf || length $buf == 0) {
                Carp::croak("Error reading from pty: $!")
                    unless defined $buf;
                last;
            }

            syswrite STDOUT, $buf;

            $self->write_to_termcast($buf);
        }

        if ($self->_socket_ready($rout)) {
            my $buf;
            $self->socket->recv($buf, 4096);
            if (!defined $buf || length $buf == 0) {
                if (defined $buf) {
                    $self->new_socket;
                }
                else {
                    Carp::croak("Error reading from socket: $!");
                }
            }

            if ($self->bell_on_watcher) {
                # something better to do here?
                syswrite STDOUT, "\a";
            }
        }
    }
}

__PACKAGE__->meta->make_immutable;
no Moose;

=head1 TODO

Use L<MooseX::SimpleConfig> to make configuration easier.

=head1 SEE ALSO

L<http://termcast.org/>

=cut

1;
