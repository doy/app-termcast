#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use App::Termcast;
BEGIN {
    eval "use Test::TCP;";
    plan skip_all => "Test::TCP is required for this test" if $@;
    plan tests => 3;
}

test_tcp(
    client => sub {
        my $port = shift;
        my $tc = App::Termcast->new(
            host => '127.0.0.1', port => $port,
            user => 'test', password => 'tset');
        $tc->write_to_termcast('foo');
        ok(!$tc->meta->find_attribute_by_name('pty')->has_value($tc),
           "pty isn't created");
        sleep 1;
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
        my $buf;
        $client->recv($buf, 4096);
        is($buf, 'foo', 'wrote correctly');
    },
);
