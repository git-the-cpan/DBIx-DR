#!/usr/bin/perl

use warnings;
use strict;
use utf8;
use open qw(:std :utf8);
use lib qw(lib ../lib);

use Test::More tests    => 33;
use Encode qw(decode encode);


BEGIN {
    # Подготовка объекта тестирования для работы с utf8
    my $builder = Test::More->builder;
    binmode $builder->output,         ":utf8";
    binmode $builder->failure_output, ":utf8";
    binmode $builder->todo_output,    ":utf8";

    note "************* DBIx::DR *************";
    use_ok 'DBIx::DR::Iterator';
}

my $aref = [ { id => 1 }, { id => 2 }, { id => 3 } ];
my $href = {
    a => {id => 'a', value => 1 },
    b => {id => 'b', value => 2 },
    c => {id => 'c', value => 3 },
    d => {id => 'd', value => 4 }
};

my $item;
my $hiter = new DBIx::DR::Iterator $href;
my $aiter = new DBIx::DR::Iterator $aref;

isa_ok $hiter => 'DBIx::DR::Iterator', 'HASH iterator has been created';
ok $hiter->{is_hash} && !$hiter->{is_array}, 'HASH detected properly';
ok $hiter->count == keys %$href, 'HASH size detected properly';

isa_ok $aiter => 'DBIx::DR::Iterator', 'ARRAY iterator has been created';
ok $aiter->{is_array} && !$aiter->{is_hash}, 'ARRAY detected properly';
ok $aiter->count == @$aref, 'ARRAY size detected properly';

my $no = 0;
while(my $i = $aiter->next) {

    if ($no >= $aiter->count) {
        fail 'Array bound exceeded';
        last;
    }

    ok $i->id ~~ $aref->[ $no++ ]{id}, "$no element of array was checked";
}

$no = 0;
while(my $i = $hiter->next) {
    if ($no++ >= $hiter->count) {
        fail 'Hash bound exceeded';
        last;
    }
    ok $i->value ~~ $href->{ $i->id }{value},
        "$no element of hash was checked";
}

ok $aiter->next, 'array element was autoreseted';
$no = 1;
$no++ while $aiter->next;
ok $no == $aiter->count, 'array was autoreseted properly';

ok $hiter->next, 'hash element was autoreseted';
$no = 1;
$no++ while $hiter->next;
ok $no == $hiter->count, 'hash was autoreseted properly';

$aiter->next;
$hiter->next;
$aiter->reset;
$hiter->reset;

$no = 0;
$no++ while $aiter->next;
ok $no == $aiter->count, 'array was reseted properly';

$no = 0;
$no++ while $hiter->next;
ok $no == $hiter->count, 'hash was reseted properly';

$item = $hiter->next;

ok $item, 'Item extracted';
ok $item->iterator, 'Item has iterator link';
undef $hiter;
ok !$item->iterator,
    'Item has undefined iterator link after iterator was destroyed';

$item = $aiter->next;
ok !$item->is_changed, "Item wasn't changed";
ok !$item->iterator->is_changed, "Iterator wasn't changed";
ok !eval { $item->value; 1 }, 'Unknown method';
ok $item->id(123) == 123, 'Change field';
ok $item->is_changed, 'Field was changed';
ok $item->iterator->is_changed, 'Iterator was changed, too';

my $o = { 1 => 2 };
$item->id($o);
$item->iterator->is_changed(0);
$item->is_changed(0);

# the same object
$item->id($o);
ok !$item->is_changed, "Item wasn't changed";
ok !$item->iterator->is_changed, "Iterator wasn't changed";

$item->id([]);
ok $item->is_changed, 'Field was changed';
ok $item->iterator->is_changed, 'Iterator was changed, too';


=head1 COPYRIGHT

 Copyright (C) 2011 Dmitry E. Oboukhov <unera@debian.org>
 Copyright (C) 2011 Roman V. Nikolaev <rshadow@rambler.ru>

 This program is free software, you can redistribute it and/or
 modify it under the terms of the Artistic License version 2.0.

=cut
