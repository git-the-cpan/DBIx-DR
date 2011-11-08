use utf8;
use strict;
use warnings;

use DBIx::DR::Iterator;
use DBIx::DR::Util ();
use DBIx::DR::PlPlaceHolders;

package DBIx::DR;
our $VERSION = '0.11';
use base 'DBI';
use Carp;
$Carp::Internal{ (__PACKAGE__) } = 1;

sub connect {
    my ($class, $dsn, $user, $auth, $attr) = @_;

    my $dbh = $class->SUPER::connect($dsn, $user, $auth, $attr);

    $attr = {} unless ref $attr;

    $dbh->{"private_DBIx::DR_iterator"} =
        $attr->{dr_iterator} || 'dbix-dr-iterator#new';

    $dbh->{"private_DBIx::DR_item"} =
        $attr->{dr_item} || 'dbix-dr-iterator-item#new';

    $dbh->{"private_DBIx::DR_sql_dir"} = $attr->{dr_sql_dir};

    $dbh->{"private_DBIx::DR_template"} = DBIx::DR::PlPlaceHolders->new(
        sql_dir     => $attr->{dr_sql_dir},

    );

    return $dbh;
}

package DBIx::DR::st;
use base 'DBI::st';
use Carp;
$Carp::Internal{ (__PACKAGE__) } = 1;

package DBIx::DR::db;
use base 'DBI::db';
use DBIx::DR::Util;
use File::Spec::Functions qw(catfile);
use Carp;
$Carp::Internal{ (__PACKAGE__) } = 1;


sub set_helper {
    my ($self, %opts) = @_;
    $self->{"private_DBIx::DR_template"}->set_helper(%opts);
}

sub _dr_extract_args_ep {
    my $self = shift;

    my (@sql, %args);

    if (@_ % 2) {
        ($sql[0], %args) = @_;
        delete $args{-f};
    } else {
        %args = @_;
    }

    my $iterator = $args{-iterator} || $self->{'private_DBIx::DR_iterator'};
    my $item = $args{-item} || $self->{'private_DBIx::DR_item'};

    croak "Iterator class was not defined" unless $iterator;
    croak "Item class was not definded" unless $item;
    croak "SQL wasn't defined" unless @sql or $args{-f};

    return (
        $self,
        \@sql,
        \%args,
        $item,
        $iterator,
    );
}

sub select {
    my ($self, $sql, $args, $item, $iterator) = &_dr_extract_args_ep;

    my $req = $self->{"private_DBIx::DR_template"}->sql_transform(
        @$sql,
        %$args
    );

    my $res;

    if (exists $args->{-hash}) {
        $res = eval {
            $self->selectall_hashref(
                $req->sql,
                $args->{-hash},
                $args->{-dbi},
                $req->bind_values
            );
        };

        croak $@ if $@;

    } else {
        my $dbi = $args->{-dbi} // {};
        croak "argument '-dbi' must be HASHREF or undef"
            unless 'HASH' eq ref $dbi;
        $res = eval {
            $self->selectall_arrayref(
                $req->sql,
                { %$dbi, Slice => {} },
                $req->bind_values
            );
        };
        croak $@ if $@;
    }

    my ($class, $method) = camelize $iterator;

    return $class->$method($res, -item => $item) if $method;
    return bless $res => $class;
}

sub single {
    my ($self, $sql, $args, $item) = &_dr_extract_args_ep;
    my $req = $self->{"private_DBIx::DR_template"}->sql_transform(
        @$sql,
        %$args
    );

    my $res = eval {
        $self->selectrow_hashref(
            $req->sql,
            $args->{-dbi},
            $req->bind_values
        );
    };
    croak $@ if $@;

    return unless $res;

    my ($class, $method) = camelize $item;
    return $class->$method($res, undef) if $method;
    return bless $res => $class;
}

sub perform {
    my ($self, $sql, $args) = &_dr_extract_args_ep;
    my $req = $self->{"private_DBIx::DR_template"}->sql_transform(
        @$sql,
        %$args
    );

    my $res = eval {
        $self->do(
            $req->sql,
            $args->{-dbi},
            $req->bind_values
        );
    };
    croak $@ if $@;

    return $res;
}

1;

__END__

=head1 NAME

DBIx::DR - easy DBI helper (named placeholders and blessed results)

=head1 SYNOPSIS

    my $dbh = DBIx::DR->connect($dsn, $login, $passed);

    $dbh->perform(
        'UPDATE tbl SET a = 1 WHERE id = <%= $id %>',
        id => 123
    );

    my $rowset = $dbh->select(
        'SELECT * FROM tbl WHERE id IN (<% list @$ids %>)',
        ids => [ 123, 456 ]
    );
    my $rowset = $dbh->select(-f => 'sqlfile.sql', ids => [ 123, 456 ]);

    while(my $row = $rowset->next) {
        print "id: %d, value: %s\n", $row->id, $row->value;
    }

=head1 DESCRIPTION

The package B<extends> L<DBI> and allows You:

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

=head1 METHODS

All methods receives the following arguments:

=over

=item -f => $sql_file_name

It will load SQL-request from file. It will seek file in directory
that was defined in L<dr_sql_dir> param of connect.

You needn't to use suffixes (B<.sql>) here, but You can.

=item -item => 'decamelized_obj_define'

It will bless (or construct) row into specified class. See below.

=item -iterator => 'decamelized_obj_define'

It will bless (or construct) rowset into specified class.

=item -dbi => HASHREF

Additional DBI arguments.

=item -hash => FIELDNAME

Selects into HASH. Iterator will operate by names (not numbers).

=back

=head2 Decamelized strings

Are strings that represent class [ and method ].

 foo_bar                => FooBar
 foo_bar#subroutine     => FooBar->subroutine
 foo_bar-baz            => FooBar::Baz

=head2 perform

Does SQL-request like 'B<UPDATE>', 'B<INSERT>', etc.

    $dbh->perform($sql, value => 1, other_value => 'abc');
    $dbh->perform(-f => $sql_file_name, value => 1m other_value => 'abc');


=head2 select

Does SQL-request, pack results into iterator class. By default it uses
L<DBIx::DR::Iterator> class.

    my $res = $dbh->select(-f => $sql_file_name, value => 1);
    while(my $row = $res->next) {
        printf "RowId: %d, RowValue: %s\n", $row->id, $row->value;
    }

    my $row = $row->get(15);  # row 15

    my $res = $dbh->select(-f => $sql_file_name,
            value => 1, -hash => 'name');
    while(my $row = $res->next) {
        printf "RowId: %d, RowName: %s\n", $row->id, $row->name;
    }

    my $row = $row->get('Vasya');  # row with name eq 'Vasya'

=head2 single

Does SQL-request that returns one row. Pack results into item class.
Does SQL-request, pack results (one row) into item class. By default it
uses L<DBIx::DR::Iterator::Item|DBIx::DR::Iterator/DBIx::DR::Iterator::Item>
class.


=head1 Template language

You can use perl inside Your SQL requests:

    % my $foo = 1;
    % my $bar = 2;
    <% my $foo_bar = $foo + $bar %>

    ..

    % use POSIX;
    % my $gid = POSIX::getgid;


There are two function is available inside perl:


=head2 quote

Replaces argument to '?', add argument value into bindlist.
You can also use shortcut 'B<=>' instead of the function.

=head3 Example 1

    SELECT
        *
    FROM
        tbl
    WHERE
        id = <% quote $id %>

=head4 Result

    SELECT
        *
    FROM
        tbl
    WHERE
        id = ?

and L<bind_values> will contain B<id> value.

If You use B<DBIx::DR::ByteStream> in place of string the function will
recall L<immediate> function.

=head3 Example 2

    SELECT
        *
    FROM
        tbl
    WHERE
        id = <%= $id %>


=head2 immediate

Replaces argument to its value.
You can also use shortcut 'B<==>' instead of the function.


=head3 Example 1

    SELECT
        *
    FROM
        tbl
    WHERE
        id = <% immediate $id %>


=head4 Result

    SELECT
        *
    FROM
        tbl
    WHERE
        id = 123

Where 123 is B<id> value.

Be carful! Using the operator You can produce code that will be
amenable to SQL-injection.

=head3 Example 2

    SELECT
        *
    FROM
        tbl
    WHERE
        id = <%== $id %>



=head1 Helpers

There are a few default helpers.

=head2 list

Expands array into Your SQL request.

=head3 Example

    SELECT
        *
    FROM
        tbl
    WHERE
        status IN (<% list @$ids %>)

=head4 Result

    SELECT
        *
    FROM
        tbl
    WHERE
        status IN (?,?,? ...)

and L<bind_values> will contain B<ids> values.


=head2 hlist

Expands array of hash into Your SQL request. The first argument can
be list of required keys. Places each group into brackets.

=head3 Example


    INSERT INTO
        tbl
            ('a', 'b')
    VALUES
        <% hlist ['a', 'b'] => @$inserts


=head4 Result


    INSERT INTO
        tbl
            ('a', 'b')
    VALUES
        (?, ?), (?, ?) ...


and L<bind_values> will contain all B<inserts> values.


=head2 include

Includes the other SQL-part.

=head3 Example

    % include 'other_sql', argument1 => 1, argument2 => 2;


=head1 User's helpers

You can add Your helpers using method L<set_helper>.

=head2 set_helper

Sets (or replaces) helpers.

    $dbh->set_helper(foo => sub { ... }, bar => sub { ... });

Each helper receives template object as the first argument.

Examples:

    $dbh->set_helper(foo_AxB => sub {
        my ($tpl, $a, $b) = @_;
        $tpl->quote($a * $b);
    });

You can use L<quote> and L<immediate> functions inside Your helpers.

If You want use the other helper inside Your helper You have to do that
by Yourself. To call the other helper You can also use C<< $tpl->call_helper >>
function.

=head3 call_helper

    $dbh->set_helper(
        foo => sub {
            my ($tpl, $a, $b) = @_;
            $tpl->quote('foo' . $a . $b);
        },
        bar => sub {
            my $tpl = shift;
            $tpl->call_helper(foo => 'b', 'c');
        }
    );

=head1 COPYRIGHT

 Copyright (C) 2011 Dmitry E. Oboukhov <unera@debian.org>
 Copyright (C) 2011 Roman V. Nikolaev <rshadow@rambler.ru>

 This program is free software, you can redistribute it and/or
 modify it under the terms of the Artistic License version 2.0.

=cut

