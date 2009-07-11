#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use App::Termcast;
use IO::Pty::Easy;
BEGIN {
    eval "use Test::TCP;";
    plan skip_all => "Test::TCP is required for this test" if $@;
    plan tests => 3;
}

test_tcp(
    client => sub {
        my $port = shift;
        my $client_script = <<EOF;
        use App::Termcast;
        my \$tc = App::Termcast->new(host => '127.0.0.1', port => $port,
                                    user => 'test', password => 'tset',
                                    extra_argv => ["$^X", "-e", "print 'foo'"]);
        \$tc->run;
EOF
        my $pty = IO::Pty::Easy->new;
        $pty->spawn("$^X", "-e", $client_script);
        is($pty->read, 'foo', 'got the right thing on stdout');
        sleep 1; # because the server gets killed when the client exits
    },
    server => sub {
        my $port = shift;
        my $sock = IO::Socket::INET->new(LocalAddr => '127.0.0.1',
                                         LocalPort => $port,
                                         Listen    => 1);
        $sock->accept; # signal to the client that the port is available
        my $client = $sock->accept;
        my $login;
        $client->recv($login, 4096);
        is($login, "hello test tset\n", 'got the correct login info');
        my $output;
        $client->recv($output, 4096);
        is($output, "foo", 'sent the right data to the server');
    },
);
