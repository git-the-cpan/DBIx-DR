use utf8;
use strict;
use warnings;

use DBIx::DR::Iterator;
use DBIx::DR::Util ();

package DBIx::DR;
our $VERSION = '0.01';
use base 'DBI';
use Carp;
our @CARP_NOT;

sub connect {
    my ($class, $dsn, $user, $auth, $attr) = @_;

    my $dbh = $class->SUPER::connect($dsn, $user, $auth, $attr);

    $attr = {} unless ref $attr;

    $dbh->{"private_DBIx::DR_iterator"} =
        $attr->{dr_iterator} || 'dbix-dr-iterator#new';

    $dbh->{"private_DBIx::DR_item"} =
        $attr->{dr_item} || 'dbix-dr-iterator-item#new';

    $dbh->{"private_DBIx::DR_sql_dir"} = $attr->{dr_sql_dir};

    $dbh->{"private_DBIx::DR_no_cache"} = 1
        if $attr->{dr_no_cache_sql};

    $dbh->{"private_DBIx::DR_cache"} = {};

    return $dbh;
}

package DBIx::DR::st;
use base 'DBI::st';
use Carp;

package DBIx::DR::db;
use base 'DBI::db';
use DBIx::DR::PlaceHolders;
use DBIx::DR::Util;
our @CARP_NOT;
use Carp;

sub _dr_extract_args {
    my $self = shift;

    my ($sql, %args);

    if (@_ % 2) {
        ($sql, %args) = @_;
    } else {
        %args = @_;
        my $file = $args{-f};
        croak "SQL-file wasn't defined" unless $file;

        if (exists $self->{"private_DBIx::DR_cache"}{$file}) {
            $sql = $self->{"private_DBIx::DR_cache"}{$file};
        } else {

            croak "SQL-file wasn't found" unless -r $file;
            open my $fh, '<:utf8', $file or croak "Can't open file $sql: $!";
            local $/;
            $sql = <$fh>;

            $self->{"private_DBIx::DR_cache"}{$file} = $sql
                unless $self->{"private_DBIx::DR_no_cache"};
        }
    }

    my $iterator = $args{-iterator} || $self->{'private_DBIx::DR_iterator'};
    my $item = $args{-item} || $self->{'private_DBIx::DR_item'};


    croak "Iterator class was not defined" unless $iterator;
    croak "Item class was not definded" unless $item;
    croak "SQL wan't defined" unless $sql;

    return (
        $self,
        $sql,
        \%args,
        $item,
        $iterator,
    );
}

sub dr_do {
    my ($self, $sql, $args)= &_dr_extract_args;
    my $req = sql_transform $sql, $args;
    return $self->do($req->{sql}, $args->{-dbi}, @{ $req->{vals} });
}


sub dr_rows {

    my ($self, $sql, $args, $item, $iterator) = &_dr_extract_args;

    my $req = sql_transform $sql, $args;
    my $res;

    if ($args->{-hash}) {
        $res = $self->selectall_hashref(
            $req->{sql}, $args->{-hash}, $args->{-dbi}, @{ $req->{vals} }
        );
    } else {
        my $dbi = $args->{-dbi} // {};
        croak '-dbi argument must be HASHREF' unless 'HASH' eq ref $dbi;
        $res = $self->selectall_arrayref(
            $req->{sql}, { %$dbi, Slice => {} }, @{ $req->{vals} }
        );
    }

    my ($class, $method) = camelize $iterator;

    return $class->$method($res, -item => $item) if $method;
    return bless $res => $class;
}

sub dr_get {

    my ($self, $sql, $args, $item) = &_dr_extract_args;

    my $req = sql_transform $sql, $args;

    my $res = $self->selectrow_hashref($sql, $args->{-dbi}, @{ $req->{vals} });

    my ($class, $method) = camelize $item;
    return $class->$method($res, undef) if $method;
    return bless $res => $class;
}

1;

__END__

=head1 NAME

DBIx::DR - easy DBI helper (named placeholders and blessed results)

=head1 SYNOPSIS

    my $dbh = DBIx::DR->connect($dsn, $login, $passed);

    $dbh->dr_do('SELECT * FROM tbl WHERE id = ?{id}', id => 123);

    my $rowset = $dbh->dr_rows(-f => 'sqlfile.sql', ids => [ 123, 456 ]);

    while(my $row = $rowset->next) {
        print "id: %d, value: %s\n", $row->id, $row->value;
    }

=head1 DESCRIPTION

The package extends L<DBI> and allows You:

=over

=item *

to use named placeholders;

=item *

to bless resultsets into Your package;

=item *

to place Your SQL's into dedicated directory;

=item *

to use usual L<DBI> methods.

=back


=head1 Additional 'L<connect|DBI/connect>' options.

=head2 dr_iterator

A string describes iterator class. Default value is 'B<dbix-dr-iterator#new>'.

=head2 dr_item

A string describes item (one row) class.
Default value is 'B<dbix-dr-iterator-item#new>'.

=head2 dr_sql_dir

Directory path to seek sql files (If You use dedicated SQLs).

=head2 dr_no_cache_sql

If this param is B<true>, L<DBIx::DR> wont cache SQLs that were read from
external files.

=head1 METHODS

All methods receives the following arguments:

=over

=item -f => $sql_file_name

It will load SQL-request from file.

=item -item => 'decamelized_obj_define'

It will bless (or construct) row into specified class. See below.

=item -iterator => 'decamelized_obj_define'

It will bless (or construct) rowset into specified class.

=item -dbi => HASHREF

Additional DBI arguments.

=back

=head2 Decamelized strings

Are strings that represent class [ and method ].

 foo_bar                => FooBar
 foo_bar#subroutine     => FooBar->subroutine
 foo_bar-baz            => FooBar::Baz

=head2 dr_do

Does SQL-request like 'B<UPDATE>', 'B<INSERT>', etc.

    $dbh->dr_do($sql, value => 1, other_value => 'abc');
    $dbh->dr_do(-f => $sql_file_name, value => 1m other_value => 'abc');


=head2 dr_rows

Does SQL-request, pack results into iterator class. By default it uses
L<DBIx::DR::Iterator> class.

    my $res = $dbh->dr_rows(-f => $sql_file_name, value => 1);
    while(my $row = $res->next) {
        printf "RowId: %d, RowValue: %s\n", $row->id, $row->value;
    }

    my $row = $row->get(15);  # row 15

    my $res = $dbh->dr_rows(-f => $sql_file_name,
            value => 1, -hash => 'name');
    while(my $row = $res->next) {
        printf "RowId: %d, RowName: %s\n", $row->id, $row->name;
    }

    my $row = $row->get('Vasya');  # row with name eq 'Vasya'

=head2 dr_get

Does SQL-request that returns one row. Pack results into item class.
Does SQL-request, pack results (one row) into item class. By default it
uses L<DBIx::DR::Iterator::Item|DBIx::DR::Iterator/DBIx::DR::Iterator::Item>
class.


=head1 SQL placeholders


There are a few types of substitution:

=head2 C<?{path}>

General substitution. It will be replaced by item defined by 'B<path>'.

=head3 Example 1

    $sql = q[ SELECT * FROM tbl WHERE id = ?{id} ];
    $rows = $dbh->dr_rows($sql, id => 123);

Result:

    SELECT * FROM tbl WHERE id = 123

=head3 Example 2

    $sql = q[ SELECT * FROM tbl WHERE id = ?{ids.id_important} ];
    $rows = $dbh->dr_rows($sql, ids => { id_important => 123 });

Result:

    SELECT * FROM tbl WHERE id = 123

=head3 Example 3

    $sql = q[ SELECT * FROM tbl WHERE id = ?{ids:id_important} ];
    # object MUST have 'id_important' method
    $rows = $dbh->dr_rows($sql, ids => $object);

Result like:

    sprintf "SELECT * FROM tbl WHERE id = %s", $object->id_important;


=head2 C<?fmt{path}{string}>

Formatted substitution. All symbols 'B<?>' in 'B<string> will be
replaced by value defined by 'B<path>'.

=head3 Example 1

    $sql = q[ SELECT * FROM tbl where col like ?fmt{filter}{%?%} ]
    $rows = $dbh->dr_rows($sql, filter => 'abc');

Result:

    SELECT * FROM tbl where col like '%abc%'

=head2 C<?@{path}>

Array substitution. It will be replaced by items from
array defined by 'B<path>'.

=head3 Example 1

    $sql = q[ SELECT * FROM tbl WHERE id IN ( ?@{ids} ) ];
    $rows = $dbh->dr_rows($sql, ids => [ 1, 2, 3, 4 ]);

Result:

    SELECT * FROM tbl WHERE id IN ( 1, 2, 3, 4 )

=head2 C<?@{(path)}>

Array substitution. It will be replaced by items from
array defined by 'B<path>'. Each element will be in brackets.

=head3 Example 1

    $sql = q[ INSERT INTO tbl (value) VALUES ?@{(values)} ];
    $dbh->dr_do($sql, values => [ 1, 2, 3, 4 ]);

Result:

    INSERT INTO tbl (value) VALUES (1), (2), (3), (4);

=head2 C<?%{path}{subpath1,subpath2...}>

Array substitution. Array (B<path>) of hashes will be expanded.

=head3 Example 1

    $sql = q[ INSERT INTO
            tbl (id, value)
        VALUES (?%{values}{id,value})
    ];
    $dbh->dr_do($sql, values => [ { id => 1, value => 'abc' } ]);

Result:

    INSERT INTO tbl (id, value) VALUES (1, 'abc')


=head2 C<?%{(path)}{subpath1,subpath2...}>

Array substitution. Array (B<path>) of hashes will be expanded.
Each elementset will be in brackets.

=head3 Example 1

    $sql = q[
        INSERT INTO
            tbl (id, value)
        VALUES (?%{values}{id,value})
    ];
    $dbh->dr_do(
        $sql,
        values => [
            { id => 1, value => 'abc' },
            { id => 2, value => 'cde' }
        ]
    );

Result:

    INSERT INTO tbl (id, value) VALUES (1, 'abc'), (2, 'cde')

=head2 C<?sub{ perl code }>

Eval perl code.

=head3 Example 1

    $sql = q[ INSERT INTO tbl (time) VALUES ?sub{time} ];
    $dbh->dr_do(q[ INSERT INTO tbl (time) VALUES (?sub{time})  ]);

Result:

    INSERT INTO tbl (time) VALUES (1319638498)

=head2 C<?qsub{ perl code }>

Eval perl code and quote result.

=head3 Example 1

    $sql = q[ INSERT INTO tbl (time) VALUES ?qsub{scalar localtime} ];
    $dbh->dr_do(q[ INSERT INTO tbl (time) VALUES (?sub{time})  ]);

Result:

    INSERT INTO tbl (time) VALUES ('Thu Oct 27 00:19:14 2011')

=head1 Conditional blocks

=head2 C<?if{path}{block}[{else-block}]> | C<?ifd{path}{block}[{else-block}]> |
C<?ife{path}{block}[{else-block}]>

If variable defined by 'B<path>' is true (B<if>), defined (B<ifd>) or
exists (B<ife>), 'B<block>' will be expanded.
Otherwise 'B<else-block>' will be expanded (if it is present).

=head3 Example 1

    $sql = q[
        SELECT
            *
        FROM
            tbl
        WHERE
            sid = 1
            ?if{filter}{ AND filter = ?{ filter_value } }
    ];

    $dbh->dr_rows($sql, filter => 0, filter_value = 123);

Result:

    SELECT * FROM tbl WHERE sid = 1

=head3 Example 2

    $sql = q[
        SELECT
            *
        FROM
            tbl
        WHERE
            sid = 1
            ?if{filter}{ AND filter = ?{ filter_value } }
    ];

    $dbh->dr_rows($sql, filter => 1, filter_value = 123);

Result:

    SELECT * FROM tbl WHERE sid = 1 AND filter = 123

=head3 Example 3

    $sql = q[
        SELECT
            *
        FROM
            tbl
        WHERE
            sid = 1
            AND filter
                ?ifd{filter}{ = ?{ filter } }{ IS NULL }
    ];

    $dbh->dr_rows($sql, filter => 1)

Result:

    SELECT * FROM tbl WHERE sid = 1 AND filter = 1

=head3 Example 4

    $sql = q[
        SELECT
            *
        FROM
            tbl
        WHERE
            sid = 1
            AND filter
                ?ifd{filter}{ = ?{ filter } }{ IS NULL }
    ];

    $dbh->dr_rows($sql, filter => undef);

Result:

    SELECT * FROM tbl WHERE sid = 1 AND filter IS NULL

=head1 COPYRIGHT

 Copyright (C) 2011 Dmitry E. Oboukhov <unera@debian.org>
 Copyright (C) 2011 Roman V. Nikolaev <rshadow@rambler.ru>

 This program is free software, you can redistribute it and/or
 modify it under the terms of the Artistic License version 2.0.

=cut

