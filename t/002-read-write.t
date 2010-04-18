#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use App::Termcast;
use IO::Pty::Easy;
BEGIN {
    eval "use Test::TCP;";
    plan skip_all => "Test::TCP is required for this test" if $@;
    plan tests => 5;
}

test_tcp(
    client => sub {
        my $port = shift;
        my $client_script = <<EOF;
        use App::Termcast;
        my \$tc = App::Termcast->new(
            host => '127.0.0.1', port => $port,
            user => 'test', password => 'tset');
        \$tc->run('$^X', "-e", "while (<>) { last if /\\\\./; print }");
EOF
        my $pty = IO::Pty::Easy->new;
        $pty->spawn("$^X", "-e", $client_script);
        $pty->write("foo\n");
        sleep 1; # give the subprocess time to generate its output
        is($pty->read, "foo\r\nfoo\r\n", 'got the right thing on stdout');
        $pty->write("bar\n");
        sleep 1; # give the subprocess time to generate its output
        is($pty->read, "bar\r\nbar\r\n", 'got the right thing on stdout');
        $pty->write(".\n");
        is($pty->read, ".\r\n", "didn't get too much data");
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
        my $total_out = '';
        while (1) {
            $client->recv($output, 4096);
            last unless defined($output) && length($output);
            $total_out .= $output;
        }
        is($total_out, "foo\r\nfoo\r\nbar\r\nbar\r\n.\r\n",
           'sent the right data to the server');
    },
);
