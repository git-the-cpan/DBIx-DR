#!/usr/bin/perl

use warnings;
use strict;
use utf8;
use open qw(:std :utf8);
use lib qw(lib ../lib);

use Test::More tests    => 57;
use Encode qw(decode encode);


BEGIN {
    # Подготовка объекта тестирования для работы с utf8
    my $builder = Test::More->builder;
    binmode $builder->output,         ":utf8";
    binmode $builder->failure_output, ":utf8";
    binmode $builder->todo_output,    ":utf8";

    note "************* DBIx::DR *************";
    use_ok 'DBIx::DR';
    use_ok 'DBD::SQLite';
    use_ok 'File::Temp', 'tempdir';
    use_ok 'File::Path', 'remove_tree';
    use_ok 'File::Spec::Functions', 'catfile';
    use_ok 'File::Basename', 'dirname', 'basename';
}

my $temp_dir = tempdir;
END {
    remove_tree $temp_dir, { verbose => 0 };
    ok !-d $temp_dir, "Temporary dir was removed: $temp_dir";
}
my $test_dir = catfile(dirname($0), 'sql');
ok -d $test_dir, 'Directory contained sqls is found: ' . $test_dir;

ok -d $temp_dir, "Temporary directory was created: $temp_dir";
my $db_file = "$temp_dir/db.sqlite";

my $dbh = DBIx::DR->connect(
    "dbi:SQLite:dbname=$db_file", '', '', { dr_sql_dir => $test_dir });

isa_ok $dbh => 'DBIx::DR::db', 'Connector was created';
ok -r $db_file, 'Database file was created';

ok $dbh->{'private_DBIx::DR_iterator'} eq 'dbix-dr-iterator#new',
    'Default iterator class';
ok $dbh->{'private_DBIx::DR_item'} eq 'dbix-dr-iterator-item#new',
    'Default item class';

my $res =
    $dbh->dr_do('CREATE TABLE tbl (id INTEGER PRIMARY KEY, value CARCHAR(32))');
ok $res ~~ '0E0', 'Table tbl was created';

my @values = (1, 2, 3, 4, 6, 'abc', 'def');
for(@values) {
    $res = $dbh->dr_do(
        'INSERT INTO tbl (value) VALUES (?{value})',
        value  => $_
    );

    ok $res && $res ne '0E0', 'Array item was inserted';
}

$res = $dbh->dr_do(q[
        UPDATE
            tbl
        SET
            value = value || ?{suffix}
        WHERE
            id > ?{id_limit}
    ],
    suffix => '_suffix',
    id_limit => 2
);


ok $res == @values - 2, 'Updated was passed';

$res = $dbh->dr_rows('SELECT * FROM tbl');
isa_ok $res => 'DBIx::DR::Iterator', 'A few rows were fetched';
ok $res->count == @values, 'Rows count has well value';
while(my $v = $res->next) {
    ok $v->id > 0, 'Record identifier: ' . $v->id;
    if ($v->id > 2) {
        ok $v->value eq $values[ $v->id - 1 ] . '_suffix',
            'Record value: ' . $v->value;
    } else {
        ok $v->value eq $values[ $v->id - 1 ], 'Record value: ' . $v->value;
    }
}



my $select_file = catfile $test_dir, 'select.sql';
ok -r $select_file, 'select.sql is found';

ok !exists $dbh->{"private_DBIx::DR_cache"}{$select_file}, 'Cache is empty';
$res = $dbh->dr_rows(
    -f          => 'select',
    ids         => [ 1, 2 ],
    -hash       => 'id',
    -item       => 'my_item_package#new',
    -iterator   => 'my_iterator_package#new'
);

ok 'HASH' eq ref $res->{fetch}, 'SELECT was done';
ok $res->count == 2, 'Rows count has well value';
ok $res->get(1)->value eq $values[0], 'First item';
ok $res->get(2)->value eq $values[1], 'Second item';
ok exists $dbh->{"private_DBIx::DR_cache"}{$select_file}, 'Cache is full';
$res = $dbh->dr_rows(
    -f          => $select_file,
    ids         => [ 1, 2 ],
    -hash       => 'id',
    -item       => 'my_item_package#new',
    -iterator   => 'my_iterator_package#new'
);
isa_ok $res => 'MyIteratorPackage', 'Repeat sql from file';
ok $res->count == 2, 'Rows count has well value';

my @a = $res->all;
ok @a == $res->count, 'Rows count has well value';
ok $a[0]->value eq $values[0], 'First item';
ok $a[1]->value eq $values[1], 'Second item';


package MyItemPackage;
use base 'DBIx::DR::Iterator::Item';
use Test::More;

sub value {
    my ($self) = @_;
    ok @_ == 1, 'Get item value';
    return $self->SUPER::value;
}

package MyIteratorPackage;
use base 'DBIx::DR::Iterator';
use Test::More;

sub count {
    my ($self) = @_;
    ok @_ == 1, 'Get iterator size';
    return $self->SUPER::count;
}

=head1 COPYRIGHT

 Copyright (C) 2011 Dmitry E. Oboukhov <unera@debian.org>
 Copyright (C) 2011 Roman V. Nikolaev <rshadow@rambler.ru>

 This program is free software, you can redistribute it and/or
 modify it under the terms of the Artistic License version 2.0.

=cut
