#!/usr/bin/env perl
use strict;
use warnings;
use Test::More tests => 1;

package Foo;
::use_ok('App::Termcast')
    or ::BAIL_OUT("couldn't load App::Termcast");
