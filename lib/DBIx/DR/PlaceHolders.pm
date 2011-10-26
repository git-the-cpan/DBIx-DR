use utf8;
use strict;
use warnings;

package DBIx::DR::PlaceHolders;
use Scalar::Util qw(blessed);
use base qw(Exporter);
our @EXPORT = qw(sql_transform);
our @CARP_NOT;
use Carp;
use Data::Dumper;

my $field_re  = qr{[a-zA-Z_][a-zA-Z0-9_]*};
my $path_re   = qr{[\.:]?$field_re(?:[\.:]$field_re)*};

sub val_by_path($$) {
    my ($path, $val) = @_;

    $path = ".$path" unless $path =~ /^[\.:]/;

    my @sp = split /\s*([\.:])\s*/, $path;
    shift @sp;

    my $rp = '';
    for (my $i = 0; $i < @sp; $i++) {
        if ($sp[$i] eq '.') {
            $i++;
            $rp .= ".$sp[$i]";
            croak "Path $rp is not a HASH" unless 'HASH' eq ref $val;
            $val = $val->{ $sp[$i] };
            next;
        }

        if ($sp[$i] eq ':') {
            my $method = $sp[++$i];
            $rp .= ":$sp[$i]";
            croak "Path $rp is not an OBJECT" unless blessed $val;
            croak "Method '$method' is not found" unless $val->can($method);
            $val = $val->$method;
            next;
        }

        croak "Internal error: can't parse path: $path";
    }
    return $val;
}

sub exists_path($$) {
    my ($path, $val) = @_;

    my @sp = ('.' , split /\s*([\.:])\s*/, $path);

    my $rp = '';
    for (my $i = 0; $i < @sp; $i++) {
        if ($sp[$i] eq '.') {
            $i++;
            $rp .= ".$sp[$i]";
            return 0 unless 'HASH' eq ref $val;
            return 0 unless exists $val->{ $sp[$i] };
            $val = $val->{ $sp[$i] };
            next;
        }

        if ($sp[$i] eq ':') {
            my $method = $sp[++$i];
            $rp .= ":$sp[$i]";
            return 0 unless blessed $val;
            return 0 unless $val->can($method);
            $val = $val->$method;
            next;
        }

        croak "Internal error: can't parse path: $path";
    }
    return 1;
}

sub sql_transform($;@) {
    my ($sql, $args);
    $sql = shift;

    if (@_ % 2) {
        $args = shift;
        croak 'Usage: sql_transform $sql [, key => $value, .. ]'
            unless 'HASH' eq ref $args;
    } else {
        $args = { @_ };
    }

    croak 'Usage: sql_transform $sql [, key => $value, .. ]' unless $sql;

    my @vals;

    while(1) {

        # if, ife, ifd
        last unless $sql =~ s[
                \?

                ( if[de]? )             # $1

                \s*

                \{
                    \s*
                    (                   # $2
                        $path_re
                    )
                    \s*
                \}

                (                       # $3
                    \s*

                    \{
                        (               # $4
                            (?: (?> [^\}\{]+ ) | (?-2) )*
                        )
                    \}
                )

                (                       # $5
                    \s*

                    \{
                        (               # $6
                            (?: (?> [^\}\{]+ ) | (?-2) )*
                        )
                    \}
                )?
        ][]xs;


        my $before         = $`;
        my $found          = $&;
        my $mod            = $1;
        my $path           = $2;
        my $block          = $3;
        my $block_content  = $4;
        my $eblock         = $5;
        my $eblock_content = $6;


        # if exists
        if ($mod eq 'ife') {
            if (exists_path $path, $args) {
                substr $sql, length($before), 0, $block_content;
                next;
            }
            next unless defined $eblock_content;
            substr $sql, length($before), 0, $eblock_content;
        }
        my $val = val_by_path $path, $args;

        croak "Syntax error: '$mod\{$path}{BLOCK NOT FOUND}'"
            unless defined $block;

        # if
        if ($mod eq 'if') {
            if ($val) {
                substr $sql, length($before), 0, $block_content;
                next;
            }
            next unless defined $eblock_content;
            substr $sql, length($before), 0, $eblock_content;
        }

        # if defined
        if ($mod eq 'ifd') {
            if (defined $val) {
                substr $sql, length($before), 0, $block_content;
                next;
            }
            next unless defined $eblock_content;
            substr $sql, length($before), 0, $eblock_content;
        }
    }

    # ?sub{ code }
    while(1) {
        last unless $sql =~ s[

                \?
                (q?)                        # $1

                (                           # $2
                    sub \s*
                    (                       # $3
                        \s*

                        \{
                            (               # $4
                                (?: (?> [^\}\{]+ ) | (?-2) )*
                            )
                        \}
                    )
                )
        ][]xs;

        my $before = $`;
        my $quote = $1;
        my $sub = eval $2;
        croak $@ if $@;

        my $res = eval { $sub->($args) };
        croak $@ if $@;
        if ($quote) {
            substr $sql, length($before), 0, '?' . scalar @vals;
            push @vals => $res;
        } else {
            substr $sql, length($before), 0, $res
                if defined $res and length $res;
        }
    }


    # ?{name} and ?@{name}
    while($sql =~ s# \? (\@)?  \{ \s* ( $path_re ) \s* \} ##xs) {
        my $before      = $`;
        my $found       = $&;
        my $mod         = $1;
        my $path        = $2;
        my $val = val_by_path $path, $args;
        unless($mod) {
            substr $sql, length($before), 0, '?' . scalar @vals;
            push @vals => $val;
            next;
        }

        if ($mod eq '@') {
            croak "Path '$path' is not ARRAYREF" unless 'ARRAY' eq ref $val;
            my $no = @vals;
            push @vals => @$val;
            substr $sql, length($before), 0,
                join ',' => map '?' . $no++ => @$val;
            next;
        }
        croak "Internal error: unknown modifier: $mod";
    }

    # ?{(name)}
    while($sql =~ s# \? \@  \{ \s* \( \s* (  $path_re ) \s* \) \s* \} ##xs) {
        my $before      = $`;
        my $found       = $&;
        my $path        = $1;
        my $val = val_by_path $path, $args;

        croak "Path '$path' is not ARRAYREF" unless 'ARRAY' eq ref $val;
        my $no = @vals;
        push @vals => @$val;
        substr $sql, length($before), 0,
            join ',' => map '(?' . $no++ . ')' => @$val;
    }

    # ?%{name}{field,field,field}
    while(1) {
        last unless $sql =~ s#
            \?\%
            \{ \s* ( $path_re ) \s* }\s*
            \{ \s* ( $path_re (?: \s*,\s* $path_re)* ) \s* \}
        ##xs;

        my $before = $`;
        my $path = $1;
        my $fields = $2;
        my $val = val_by_path $path, $args;

        croak "Path '$path' is not ARRAYREF" unless 'ARRAY' eq ref $val;

        my @subfields = split /\s*,\s*/, $fields;

        my $no = @vals;
        substr $sql, length($before), 0,
            join ',' => map {
                join ',' => map '?' . $no++, @subfields
            } @$val;

        for my $v (@$val) {
            for (@subfields) {
                push @vals => val_by_path $_, $v;
            }
        }
    }


    # ?fmt{name}{format_string}
    while(1) {

        last unless $sql =~ s[
            \?fmt
            \s*
            \{ \s* ( $path_re ) \s* }\s*    # $1

            (                               # $2
                \s*

                \{
                    (                       # $3
                        (?: (?> [^\}\{]+ ) | (?-2) )*
                    )
                \}
            )
        ][]xs;

        my $before = $`;
        my $path = $1;
        my $valres = $3;

        my $value = val_by_path $path, $args;

        $valres =~ s/\?/$value/g;

        substr $sql, length($before), 0, '?' . scalar @vals;
        push @vals => $valres;

    }
    # ?%{(name)}{field,field,field}
    while(1) {
        last unless $sql =~ s#
            \?\%
            \{ \s* \( \s* ( $path_re ) \s* \) \s* }\s*
            \{ \s* ( $path_re (?: \s*,\s* $path_re)* ) \s* \}
        ##xs;

        my $before = $`;
        my $path = $1;
        my $fields = $2;
        my $val = val_by_path $path, $args;


        croak "Path '$path' is not ARRAYREF" unless 'ARRAY' eq ref $val;

        my $no = @vals;

        my @subfields = split /\s*,\s*/, $fields;
        substr $sql, length($before), 0,
            join ',' => map {
                '(' . join(',', map '?' . $no++, @subfields) . ')'
            } @$val;
        for my $v (@$val) {
            push @vals => val_by_path $_, $v for @subfields;
        }
    }

    my @ordered_values;
    if (@vals) {
        push @ordered_values, $vals[$1] while $sql =~ s/\?(\d+)/?/;
    }

    return { sql => $sql, vals => \@ordered_values };
}

1;


=head1 COPYRIGHT

 Copyright (C) 2011 Dmitry E. Oboukhov <unera@debian.org>
 Copyright (C) 2011 Roman V. Nikolaev <rshadow@rambler.ru>

 This program is free software, you can redistribute it and/or
 modify it under the terms of the Artistic License version 2.0.

=cut

