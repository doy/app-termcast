package App::Termcast;
use Moose;
use IO::Pty::Easy;
use IO::Socket::INET;
use Scope::Guard;
use Term::ReadKey;
with 'MooseX::Getopt::Dashes';

=head1 NAME

App::Termcast - broadcast your terminal sessions for remote viewing

=head1 SYNOPSIS

  termcast [options] [command]

=head1 DESCRIPTION

App::Termcast is a client for the L<http://termcast.org/> service, which allows
broadcasting of a terminal session for remote viewing. It will either run a
command given on the command line, or a shell.

=cut

has host => (
    is      => 'rw',
    isa     => 'Str',
    default => 'noway.ratry.ru',
    documentation => 'Hostname of the termcast server to connect to',
);

has port => (
    is      => 'rw',
    isa     => 'Int',
    default => 31337,
    documentation => 'Port to connect to on the termcast server',
);

has user => (
    is      => 'rw',
    isa     => 'Str',
    default => sub { $ENV{USER} },
    documentation => 'Username for the termcast server',
);

has password => (
    is      => 'rw',
    isa     => 'Str',
    default => 'asdf', # really unimportant
    documentation => "Password for the termcast server\n"
                   . "                              (mostly unimportant)",
);

has bell_on_watcher => (
    is      => 'rw',
    isa     => 'Bool',
    default => 0,
    documentation => "Send a terminal bell when a watcher connects\n"
                   . "                              or disconnects",
);

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

has socket => (
    traits     => ['NoGetopt'],
    is         => 'rw',
    isa        => 'IO::Socket::INET',
    lazy_build => 1,
    init_arg   => undef,
);

sub _build_socket {
    my $self = shift;
    my $socket = IO::Socket::INET->new(PeerAddr => $self->host,
                                       PeerPort => $self->port);
    die "Couldn't connect to " . $self->host . ": $!"
        unless $socket;
    $socket->write('hello '.$self->user.' '.$self->password."\n");
    return $socket;
}

has pty => (
    traits     => ['NoGetopt'],
    is         => 'rw',
    isa        => 'IO::Pty::Easy',
    lazy_build => 1,
    init_arg   => undef,
);

sub _build_pty {
    my $self = shift;
    my @argv = @{ $self->extra_argv };
    push @argv, ($ENV{SHELL} || '/bin/sh') if !@argv;
    my $pty = IO::Pty::Easy->new(raw => 0);
    $pty->spawn(@argv);
    return $pty;
}

sub _build_select_args {
    my $self = shift;
    my $sockfd = fileno($self->socket);
    my $ptyfd  = fileno($self->pty);
    my $infd   = fileno(STDIN);

    my $rin = '';
    vec($rin, $infd   ,1) = 1;
    vec($rin, $ptyfd,  1) = 1;
    vec($rin, $sockfd, 1) = 1;

    my $win = '';
    vec($win, $sockfd, 1) = 1;

    my $ein = '';
    vec($ein, $sockfd, 1) = 1;

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

sub run {
    my $self = shift;

    ReadMode 5;
    my $guard = Scope::Guard->new(sub { ReadMode 0 });

    my ($rin, $win, $ein) = $self->_build_select_args;
    my ($rout, $wout, $eout);

    local $SIG{WINCH} = sub { $self->_got_winch(1) };
    while (1) {
        select($rout = $rin, undef, $eout = $ein, undef);

        if ($self->_socket_ready($eout)) {
            Carp::carp("Lost connection to server ($!), reconnecting...");
            $self->clear_socket;
            ($rin, $win, $ein) = $self->_build_select_args;
        }

        if ($self->_in_ready($rout)) {
            my $buf;
            sysread STDIN, $buf, 4096;
            if (!defined $buf || length $buf == 0) {
                if ($self->_got_winch) {
                    $self->_got_winch(0);
                    redo;
                }
                Carp::croak("Error reading from stdin: $!")
                    unless defined $buf;
                last;
            }

            $self->pty->write($buf);
        }

        if ($self->_pty_ready($rout)) {
            my $buf = $self->pty->read(0);
            if (!defined $buf || length $buf == 0) {
                if ($self->_got_winch) {
                    $self->_got_winch(0);
                    redo;
                }
                Carp::croak("Error reading from pty: $!")
                    unless defined $buf;
                last;
            }

            syswrite STDOUT, $buf;

            my $ready = select(undef, $wout = $win, $eout = $ein, $self->timeout);
            if (!$ready || $self->_socket_ready($eout)) {
                Carp::carp("Lost connection to server ($!), reconnecting...");
                $self->clear_socket;
                ($rin, $win, $ein) = $self->_build_select_args;
            }
            $self->socket->write($buf);
        }

        if ($self->_socket_ready($rout)) {
            my $buf;
            $self->socket->recv($buf, 4096);
            if (!defined $buf || length $buf == 0) {
                if ($self->_got_winch) {
                    $self->_got_winch(0);
                    redo;
                }
                Carp::croak("Error reading from socket: $!")
                    unless defined $buf;
                last;
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

Factor some stuff out so applications can call this standalone?

Use L<MooseX::SimpleConfig> to make configuration easier.

Do something about the watcher notifications that the termcast server sends.

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

=head1 AUTHOR

  Jesse Luehrs <doy at tozt dot net>

=head1 COPYRIGHT AND LICENSE

This software is copyright (c) 2009 by Jesse Luehrs.

This is free software; you can redistribute it and/or modify it under
the same terms as perl itself.

=cut

1;
