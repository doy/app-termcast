#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use Test::Requires 'Test::TCP';
use IO::Pty::Easy;

use App::Termcast;

pipe(my $cread, my $swrite);
pipe(my $sread, my $cwrite);

test_tcp(
    client => sub {
        my $port = shift;
        close $swrite;
        close $sread;
        { sysread($cread, my $buf, 1) }
        my $inc = join ':', grep { !ref } @INC;
        my $client_script = <<EOF;
        BEGIN { \@INC = split /:/, '$inc' }
        use App::Termcast;

        no warnings 'redefine';
        local *App::Termcast::_termsize = sub { return (80, 24) };
        use warnings 'redefine';

        my \$tc = App::Termcast->new(host => '127.0.0.1', port => $port,
                                    user => 'test', password => 'tset');
        \$tc->run('$^X', "-e", "print 'foo'");
EOF
        my $pty = IO::Pty::Easy->new;
        $pty->spawn("$^X", "-e", $client_script);
        syswrite($cwrite, 'a');
        { sysread($cread, my $buf, 1) }
        is($pty->read, 'foo', 'got the right thing on stdout');
    },
    server => sub {
        my $port = shift;
        close $cwrite;
        close $cread;
        my $sock = IO::Socket::INET->new(LocalAddr => '127.0.0.1',
                                         LocalPort => $port,
                                         Listen    => 1);
        $sock->accept; # signal to the client that the port is available
        syswrite($swrite, 'a');
        my $client = $sock->accept;
        { sysread($sread, my $buf, 1) }
        my $login;
        $client->recv($login, 4096);
        is($login,
           "hello test tset\n\e\[H\x00{\"geometry\":[80,24]}\xff\e\[H\e\[2J",
           "got the correct login info");
        $client->send("hello, test\n");
        my $output;
        $client->recv($output, 4096);
        is($output, "foo", 'sent the right data to the server');
        syswrite($swrite, 'a');
    },
);

done_testing;
