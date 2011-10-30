use utf8;
use strict;
use warnings;

package DBIx::DR::Iterator;
use Scalar::Util qw(blessed weaken);
use DBIx::DR::Util;
use Carp;


sub new {
    my ($class, $fetch, %opts) = @_;

    my ($is_hash, $is_array) = (0, 0);

    my $count;

    if ('ARRAY' eq ref $fetch) {
        $is_array = 1;
        if ($count = @$fetch) {
            croak 'You must use array of hashrefs'
                unless 'HASH' eq ref $fetch->[0];
        }
    } elsif ('HASH' eq ref $fetch) {
        $is_hash = 1;
        my ($k) = each %$fetch;
        if ($count = keys %$fetch) {
            croak 'You must use hash of hashrefs'
                unless 'HASH' eq ref $fetch->{$k};
        }


    } else {
        croak "You should bless 'HASHREF' or 'ARRAYREF' value";
    }


    my ($item_class, $item_constructor) =
        camelize($opts{'-item'} || 'dbix-dr-iterator-item#new');

    return bless {
        fetch               => $fetch,
        is_hash             => $is_hash,
        is_array            => $is_array,
        count               => $count,
        iterator            => 0,
        item_class          => $item_class,
        item_constructor    => $item_constructor,
        is_changed          => 0,

    } => ref($class) || $class;
}


sub is_changed {
    my ($self, $value) = @_;
    $self->{is_changed} = $value ? 1 : 0 if @_ > 1;
    return $self->{is_changed};
}


sub count {
    my ($self) = @_;
    return $self->{count};
}


sub reset {
    my ($self) = @_;
    $self->{iterator} = 0;
    keys %{ $self->{fetch} } if $self->{is_hash};
    return;
}


sub next {
    my ($self) = @_;

    if ($self->{is_array}) {
        return $self->get($self->{iterator}++)
            if $self->{iterator} < $self->{count};
        $self->{iterator} = 0;
        return;
    }

    my ($k) = each %{ $self->{fetch} };
    return unless defined $k;
    return $self->get($k);
}


sub get {
    my ($self, $name) = @_;
    croak "Usage \$collection->get('name|number')"
        if @_ <= 1 or !defined($name);
    my $item;
    if ($self->{is_array}) {
        croak "Element number must be digit value" unless $name =~ /^\d+$/;
        croak "Element number is out of arraybound"
            if $name >= $self->{count} || $name < -$self->{count};
        $item = $self->{fetch}[ $name ];
    } else {
        croak "Key '$name' is not exists" unless exists $self->{fetch}{$name};
        $item = $self->{fetch}{ $name };
    }

    unless(blessed $item) {
        if (my $method = $self->{item_constructor}) {
            $item = $self->{item_class}->$method($item, $self);
        } else {
            bless $item => $self->{item_class};
        }
    }
    return $item;
}


sub exists {
    my ($self, $name) = @_;
    croak "Usage \$collection->exists('name|number')"
        if @_ <= 1 or !defined($name);

    if ($self->{is_array}) {
        croak "Element number must be digit value" unless $name =~ /^\d+$/;
        return 0 if $name >= $self->{count} || $name < -$self->{count};
        return 1;
    }

    return exists($self->{fetch}{$name}) or 0;
}


sub all {
    my ($self) = @_;
    return unless defined wantarray;
    my @res;
    if ($self->{is_array}) {
        for (my $i = 0; $i < @{ $self->{fetch} }; $i++) {
            push @res => $self->get($i);
        }
    } else {
        push @res => $self->get($_) for keys %{ $self->{fetch} };
    }
    return @res;
}

sub first {
    my ($self) = @_;

    if ($self->{is_array}) {
        return ($self->{iterator} == 1) ? 1 : 0;
    }

    croak "'first' and 'last' methods aren't provided for hashiterators";
    return;
}

sub last {
    my ($self) = @_;

    if ($self->{is_array}) {
        return ($self->{iterator} == $self->{count}) ? 1 : 0;
    }

    croak "'first' and 'last' methods aren't provided for hashiterators";
    return;
}

package DBIx::DR::Iterator::Item;
use Scalar::Util ();
use Carp ();

# to exclude this method from AUTOLOAD
sub DESTROY {}

sub AUTOLOAD {
    our $AUTOLOAD;
    my ($method) = $AUTOLOAD =~ /.*::(.*)/;
    my ($self, $value) = @_;

    Carp::croak "Can't find method '$self->$method'" unless ref $self;
    Carp::croak "Can't find method '$method' in this item"
        unless exists $self->{$method};

    if (@_ > 1) {
        my $is_changed;

        if (ref $value and ref $self->{$method}) {
            $is_changed = Scalar::Util::refaddr($value)
                != Scalar::Util::refaddr($self->{$method});
        } elsif(ref($value) ne ref($self->{$method})) {
            $is_changed = 1;
        } elsif(defined $value and defined $self->{$method}) {
            $is_changed = $value ne $self->{$method};
        } elsif(defined $value xor defined $self->{$method}) {
            $is_changed = 1;
        }

        $self->is_changed(1) if $is_changed;
        $self->{$method} = $value;
    }

    return $self->{$method};
}

sub new {
    my ($class, $object, $iterator) = @_;
    return unless defined $object;
    Carp::croak "Usage: DBIx::DR::Iterator::Item->new(HASHREF [, iterator ])"
        unless 'HASH' eq ref $object;
    my $self = bless $object => ref($class) || $class;
    $self->{iterator} = $iterator;
    Scalar::Util::weaken($self->{iterator});
    $self->{is_changed} = 0;
    return $self;
}

sub is_changed {
    my ($self, $value) = @_;
    if (@_ > 1) {{
        $self->{is_changed} = $value ? 1 : 0;

        last unless $self->{is_changed};
        last unless Scalar::Util::blessed $self->{iterator};
        last unless $self->{iterator}->can('is_changed');
        $self->{iterator}->is_changed( 1 );
    }}
    return $self->{is_changed};
}

sub can {
    my ($self, $method) = @_;
    return 1 if ref $self and exists $self->{$method};
    return $self->SUPER::can($method);
}


1;

=head1 SYNOPSIS

    my $it = DBIx::DR::Iterator->new($arrayref);

    printf "Rows count: %d\n", $it->count;

    while(my $row == $it->next) {
        print "Row: %s\n", $row->field;
    }

    my $row = $it->get(15); # element 15



    my $it = DBIx::DR::Iterator->new($hashref);

    printf "Rows count: %d\n", $it->count;

    while(my $row == $it->next) {
        print "Row: %s\n", $row->field;
    }

    my $row = $it->get('abc'); # element with key name eq 'abc'


=head1 DESCRIPTION

The package constructs iterator from HASHREF or ARRAYREF value.

=head1 Methods

=head2 new

Constructor.

    my $i = DBIx::DR::Iterator->new($arrayset [, OPTIONS ]);

Where B<OPTIONS> are:

=over

=item -item => 'decamelized_obj_define';

It will bless (or construct) row into specified class. See below.

By default it constructs L<DBIx::DR::Iterator::Item> objects.

=back

=head2 count

Returns count of elements.

=head2 is_changed

Returns (or set) flag that one of contained elements was changed.

=head2 exists(name|number)

Returns B<true> if element 'B<name|number>' is exists.

=head2 get(name|number)

Returns element by 'B<name|number>'. It will throw exception if element
isn't L<exists|exists(name|number)>.

=head2 next

Returns next element or B<undef>.

=head2 reset

Resets internal iterator (that is used by L<next>).

=head2 all

Returns all elements (as an array).

=head1 DBIx::DR::Iterator::Item

One row. It has methods names coincident with field names. Also it has a few
additional methods:

=head2 new

Constructor. Receives two arguments: B<HASHREF> and link to
L<iterator|DBIx::DR::Iterator>.

    my $row = DBIx::DR::Iterator::Item->new({ id => 1 });
    $row = DBIx::DR::Iterator::Item->new({ id => 1 }, $iterator); }

=head2 iterator

Returns (or set) iterator object. The link is created by constructor.
This is a L<weaken|Scalar::Util/weaken> link.

=head2 is_changed

Returns (or set) flag if the row has been changed. If You change any of
row's fields the flag will be set. Also iterator's flag will be set.


=head1 COPYRIGHT

 Copyright (C) 2011 Dmitry E. Oboukhov <unera@debian.org>
 Copyright (C) 2011 Roman V. Nikolaev <rshadow@rambler.ru>

 This program is free software, you can redistribute it and/or
 modify it under the terms of the Artistic License version 2.0.

=cut

