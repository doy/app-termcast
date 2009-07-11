package App::Termcast;
use Moose;
use IO::Pty::Easy;
use IO::Socket::INET;
use Term::ReadKey;
with 'MooseX::Getopt';

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
    documentation => 'Password for the termcast server (mostly unimportant)',
);

sub run {
    my $self = shift;
    my @argv = @{ $self->extra_argv };
    push @argv, ($ENV{SHELL} || '/bin/sh') if !@argv;

    my $socket = IO::Socket::INET->new(PeerAddr => $self->host,
                                       PeerPort => $self->port);
    $socket->write('hello '.$self->user.' '.$self->password."\n");
    my $sockfd = fileno($socket);

    my $pty = IO::Pty::Easy->new(raw => 0);
    $pty->spawn(@argv);
    my $ptyfd = fileno($pty);

    my ($rin, $rout) = '';
    vec($rin, fileno(STDIN) ,1) = 1;
    vec($rin, $ptyfd, 1) = 1;
    vec($rin, $sockfd, 1) = 1;
    ReadMode 5;
    while (1) {
        my $ready = select($rout = $rin, undef, undef, undef);
        if (vec($rout, fileno(STDIN), 1)) {
            my $buf;
            sysread STDIN, $buf, 4096;
            if (!defined $buf || length $buf == 0) {
                warn "Error reading from stdin: $!" unless defined $buf;
                last;
            }
            $pty->write($buf);
        }
        if (vec($rout, $ptyfd, 1)) {
            my $buf = $pty->read(0);
            if (!defined $buf || length $buf == 0) {
                warn "Error reading from pty: $!" unless defined $buf;
                last;
            }
            syswrite STDOUT, $buf;
            $socket->write($buf);
        }
        if (vec($rout, $sockfd, 1)) {
            my $buf;
            $socket->recv($buf, 4096);
            if (!defined $buf || length $buf == 0) {
                warn "Error reading from socket: $!" unless defined $buf;
                last;
            }
            # XXX: do something with this? (watcher notification, etc)
        }
    }
    ReadMode 0;
}

__PACKAGE__->meta->make_immutable;
no Moose;

=head1 TODO

Tests! Need to figure out a good way to test this.

Factor some stuff out so applications can call this standalone?

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

=head1 AUTHOR

  Jesse Luehrs <doy at tozt dot net>

=head1 COPYRIGHT AND LICENSE

This software is copyright (c) 2009 by Jesse Luehrs.

This is free software; you can redistribute it and/or modify it under
the same terms as perl itself.

=cut

1;
