#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use Test::Requires 'Test::TCP';

use App::Termcast;

no warnings 'redefine';
local *App::Termcast::_termsize = sub { return (80, 24) };
use warnings 'redefine';

pipe(my $cread, my $swrite);
pipe(my $sread, my $cwrite);

test_tcp(
    client => sub {
        my $port = shift;
        close $swrite;
        close $sread;
        { sysread($cread, my $buf, 1) }
        my $tc = App::Termcast->new(
            host => '127.0.0.1', port => $port,
            user => 'test', password => 'tset');
        $tc->write_to_termcast('foo');
        syswrite($cwrite, 'a');
        { sysread($cread, my $buf, 1) }
        ok(!$tc->meta->find_attribute_by_name('pty')->has_value($tc),
           "pty isn't created");
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
        my $login;
        $client->recv($login, 4096);
        is($login,
           "hello test tset\n\e\[H\x00{\"geometry\":[80,24]}\xff\e\[H\e\[2J",
           "got the correct login info");
        $client->send("hello, test\n");
        { sysread($sread, my $buf, 1) }

        my $buf;
        $client->recv($buf, 4096);
        is($buf, 'foo', 'wrote correctly');
        syswrite($swrite, 'a');
    },
);

done_testing;
