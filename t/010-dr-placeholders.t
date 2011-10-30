#!/usr/bin/perl

use warnings;
use strict;
use utf8;
use open qw(:std :utf8);
use lib qw(lib ../lib);

use Test::More tests => 56;
use Encode qw(decode encode);


BEGIN {
    # Подготовка объекта тестирования для работы с utf8
    my $builder = Test::More->builder;
    binmode $builder->output,         ":utf8";
    binmode $builder->failure_output, ":utf8";
    binmode $builder->todo_output,    ":utf8";

    note "************* DBIx::DR::PlaceHolders *************";
    use_ok 'DBIx::DR::PlaceHolders';
}

can_ok 'main' => 'sql_transform';

my $sql = q#
    SELECT
        *
    FROM
        table
    WHERE
        ?if{abc}{AND abc = TRUE}{AND abc = 0}
        ?ifd{abc}{ifd IS NOT NULL}
        ?ife{abc}{ife IS NOT NULL}

    LIMIT 10
#;


my $res = sql_transform $sql, abc => 0;
ok $res->{sql} !~ /abc = TRUE/, 'if condition: FALSE (block1)';
ok $res->{sql} =~ /abc = 0/, 'if condition: FALSE (block2)';
ok $res->{sql} =~ /ifd IS NOT NULL/, 'ifd condition: TRUE';
ok $res->{sql} =~ /ife IS NOT NULL/, 'ife condition: TRUE';
ok $res->{sql} !~ /[\{\}]/, 'All blocks were replaced';
ok @{$res->{vals}} == map($_, $res->{sql} =~ /(\?)/g), 'Variables count';
ok !@{$res->{vals}}, 'No variables in the first SQL';

$res = sql_transform $sql, abc => 1;
ok $res->{sql} =~ /abc = TRUE/, 'if condition: TRUE (block1)';
ok $res->{sql} !~ /abc = 0/, 'if condition: TRUE (block2)';
ok $res->{sql} =~ /ifd IS NOT NULL/, 'ifd condition: TRUE';
ok $res->{sql} =~ /ife IS NOT NULL/, 'ife condition: TRUE';
ok $res->{sql} !~ /[\{\}]/, 'All blocks were replaced';
ok @{$res->{vals}} == map($_, $res->{sql} =~ /(\?)/g), 'Variables count';
ok !@{$res->{vals}}, 'No variables in the first SQL';

$res = sql_transform $sql;
ok $res->{sql} !~ /ifd IS NOT NULL/, 'ifd condition: FALSE';
ok $res->{sql} !~ /ife IS NOT NULL/, 'ife condition: FALSE';
ok $res->{sql} !~ /[\{\}]/, 'All blocks were replaced';
ok @{$res->{vals}} == map($_, $res->{sql} =~ /(\?)/g), 'Variables count';
ok !@{$res->{vals}}, 'No variables in the first SQL';


$sql = q#
    SELECT
        *
    FROM
        table
    WHERE
        id IN ( ?@{ abc } )
        AND
            test = ?{test}
#;

ok !eval { sql_transform $sql; 1 }, "Not 'ARRAYREF'";

my @test = (1, 2, 3);
$res = sql_transform $sql, abc => \@test, test => 127;
ok $res->{sql} =~ m/\?(?:,\?){$#test}/, 'Placeholders count';

push @test, 127;
ok @{ $res->{vals} } ~~ @test, 'Values';
ok @{[$res->{sql} =~ m/\?/g]} == @test, 'Placeholders count';
ok $res->{sql} =~ /test\s*=\s*\?/, '?{...}';
ok $res->{vals}[-1] ~~ 127, 'Last variable';

$sql = q#
    SELECT
        *
    FROM
        table
    WHERE
        id IN ( ?@{ (abc) } )
#;
ok !eval { sql_transform $sql; 1 }, "Not 'ARRAYREF'";

$res = sql_transform $sql, abc => \@test;
ok @{ $res->{vals} } ~~ @test, 'Values';
ok $res->{sql} =~ m/\(\?\)(?:,\(\?\)){$#test}/, 'Placeholders count';


$sql = q#
    INSERT INTO
        table
            (p1, p2)
        VALUES
            ( ?%{ abc }{p1,p2} )
#;
$res = sql_transform $sql,
    abc => [ { p1 => 1, p2 => 2 }, { p1 => 3, p2 => 4 } ];

ok $res->{sql} =~ /\?(\,\?){3}/, '?%{name}{a,b}';
ok 4 == @{$res->{vals}}, 'Placeholders count';

$sql = q#
    INSERT INTO
        table
            (p1, p2)
        VALUES
            ( ?%{ ( abc ) }{p1,p2.a,p3} )
#;
$res = sql_transform $sql,
    abc => [ { p1 => 1, p2 => { a => 1 } }, { p1 => 3, p2 => {} } ];

ok $res->{sql} =~ /(\(\?(?:,\?){2}\)),\1/, '?%{name}{a,b.c,d}';
ok 6 == @{$res->{vals}}, 'Placeholders count';

my $o = bless \undef => 'TestItem';

$sql = q#
    INSERT INTO
        table
            (p1, p2)
        VALUES
            ( ?%{ ( abc ) }{:a,:b} )
#;

$res = sql_transform $sql, abc => [ $o ];

ok $res->{sql} =~ /\(\?,\?\)/, '?%{(name)}{:a,:b}';
ok 2 == @{$res->{vals}}, 'Placeholders count';


$sql = q#SELECT ?sub{ $_[0]{abc} - 500 }#;

$res = sql_transform $sql, abc => 523;

ok $res->{sql} =~ /SELECT\s+23/s, 'sub{ ... }';
ok @{$res->{vals}} == 0, 'Placeholders count';

$sql = q#SELECT ?qsub{ $_[0]{abc} - 500 }, ?qsub{ $_[0]{def} }#;
$res = sql_transform $sql, abc => 523, def => undef;
ok $res->{sql} =~ /SELECT \?,\s*\?/, 'qsub{ ... }';
ok @{ $res->{vals} } == 2, 'PlaceHolders count';
ok $res->{vals}[0] == 23, 'PlaceHolder 1';
ok !defined $res->{vals}[1], 'PlaceHolder 2';


$sql = q#
    SELECT
            ?fmt{cde}{aaa?bbb?ccc}, -- :0
            ?@{(abc)},              -- :1
            ?@{abc},                -- :2
            ?%{def}{d,e},           -- :3
            ?%{(def)}{d,e},         -- :4
            ?{cde},                 -- :5
            ?qsub{ 'qsub' },        -- :6
            ?sub{ 'sub' },          -- :7

            ?!{indirect},           -- :8

#;

$res = sql_transform $sql,
    abc => [ 'a', 'b', 'c' ],
    def => [ { d => 'd1', e => 'e1' }, { d => 'd2', e => 'e2' } ],
    cde => 'cde',
    indirect => 'Indirect';

my @res = (
    'aaacdebbbcdeccc',
    'a', 'b', 'c',
    'a', 'b', 'c',
    'd1', 'e1', 'd2', 'e2',
    'd1', 'e1', 'd2', 'e2',
    'cde',
    'qsub'
);

# note explain $res;

ok @{[ $res->{sql} =~ /\?/g ]} == @res, 'All placeholders';
ok @{ $res->{vals} } == @res, 'PlaceHolders count';
ok $res->{sql} =~ /^\s*Indirect,\s+-- :8\s*$/ms, 'Indirect substitution';
ok $res->{sql} =~ /^\s*sub,\s+-- :7\s*$/ms, 'Indirect subroutine substitution';
ok $res->{sql} =~ /^\s*\?,\s+-- :6\s*$/ms, 'Quoted subroutine substitution';
ok $res->{sql} =~ /^\s*\?,\s+-- :5\s*$/ms, 'General substitution';
ok $res->{sql} =~ /^\s*(\(\?,\?\)),\1,\s+-- :4\s*$/ms,
    'Array of hashrefs in brackets';
ok $res->{sql} =~ /^\s*\?(?:,\?){3},\s+-- :3\s*$/ms, 'Array of hashrefs';
ok $res->{sql} =~ /^\s*\?(?:,\?){2},\s+-- :2\s*$/ms, 'Array';
ok $res->{sql} =~ /^\s*\(\?\)(?:,\(\?\)){2},\s+-- :1\s*$/ms,
    'Array in brackets';
ok $res->{sql} =~ /^\s*\?,\s+-- :0\s*$/ms, 'Format placeholder';


ok @res ~~ @{ $res->{vals} }, 'All values are in their places';


package TestItem;
use Test::More;

sub a {  ok 1, 'function "a" was called'; return 'value a' };
sub b {  ok 1, 'function "b" was called'; return 'value b' };



=head1 COPYRIGHT

 Copyright (C) 2011 Dmitry E. Oboukhov <unera@debian.org>
 Copyright (C) 2011 Roman V. Nikolaev <rshadow@rambler.ru>

 This program is free software, you can redistribute it and/or
 modify it under the terms of the Artistic License version 2.0.

=cut

