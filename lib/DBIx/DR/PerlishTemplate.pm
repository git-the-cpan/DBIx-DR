use utf8;
use strict;
use warnings;

package DBIx::DR::PerlishTemplate;
use Mouse;
use Carp;
use Scalar::Util;

has     line_tag        => (is => 'rw', isa => 'Str',   default => '%');
has     open_tag        => (is => 'rw', isa => 'Str',   default => '<%');
has     close_tag       => (is => 'rw', isa => 'Str',   default => '%>');
has     quote_mark      => (is => 'rw', isa => 'Str',   default => '=');
has     immediate_mark  => (is => 'rw', isa => 'Str',   default => '==');

has     sql             => (is => 'ro', isa => 'Str',   default => '');
has     variables       => (is => 'ro', isa => 'ArrayRef');

has     template        => (is => 'rw', isa => 'Str',   default => '');
has     template_file   => (is => 'rw', isa => 'Str',   default => '');
has     utf8_open       => (is => 'rw', isa => 'Bool',  default => 1);

has     stashes         => (is => 'ro', isa => 'ArrayRef');
has     do_croak        => (is => 'ro', isa => 'Bool');
has     pretokens       => (is => 'ro', isa => 'ArrayRef');
has     prepretokens    => (is => 'ro', isa => 'ArrayRef');
has     parsed_template => (is => 'ro', isa => 'Str',   default => '');
has     namespace       => (is => 'rw', isa => 'Str',
                        default => 'DBIx::DR::PerlishTemplate::Sandbox');

sub _render {
    my $_PTPL = shift;

    local $SIG{__DIE__} = sub {
        my $msg = $_PTPL->_fatal_message($_[0]);
        croak $msg if $_PTPL->do_croak;
        die $msg;
    };

    local $SIG{__WARN__} = sub {
        my $msg = $_PTPL->_fatal_message($_[0]);
        if ($_PTPL->do_croak) {
            carp $msg;
            return;
        };
        warn $msg;
    };

    my $_PTSUB;

    unless ($_PTPL->parsed_template) {
        $_PTSUB = $_PTPL->{parsed_template} = $_PTPL->_parse;
    } else {
        $_PTSUB = $_PTPL->parsed_template;
    }


#     printf "=%d========\n%s\n=============\n", $_PTPL->pre_lines, $_PTSUB;

    $_PTPL->{parsed_template} = $_PTSUB;

    my $esub = eval $_PTSUB;
    die $@ if $@;

    $_PTPL->{sql} = '';
    $_PTPL->{variables} = [];

    $esub->( @{ $_PTPL->stashes } );
    1;
}

sub render {
    my ($self, $tpl, @args) = @_;
    $self->{parsed_template} = '';
    $self->template($tpl);
    $self->template_file('');
    $self->{stashes} = \@args;
    $self->clean_namespace;
    return $self->_render;
}

sub render_file {
    my ($self, $file, @args)  = @_;
    croak "File '@{[ $file // 'undef' ]}' not found or readable"
        unless -r $file;
    open my $fh, '<', $file;
    my $data;

    { local $/; $data = <$fh> }
    $self->{parsed_template} = '';
    $self->template_file($file);
    $self->template($data);
    $self->{stashes} = \@args;
    $self->clean_namespace;
    return $self->_render;
}

sub clean_prepends {
    my ($self) = @_;
    $self->{pretokens} = [];
    $self;
}

sub clean_preprepends {
    my ($self) = @_;
    $self->{prepretokens} = [];
    $self;
}

sub _fatal_message($@) {
    my ($self, $msg) = @_;

    my $template;
    if ($self->template_file) {
        $template = $self->template_file;
        $self->{do_croak} = 0;
    } else {
        $self->{do_croak} = 1;
        $template = 'inline template';
    };

#     print "================= $msg =======\n". $self->prepend . $self->preprepend . "=======\n";
    $msg =~ s{ at .*?line (\d+)(\.\s*|,\s+.*?)?$}
        [" at $template line " . ( $1 - $self->pre_lines ) . $2]gsme;
#     print "================= $msg =======\n". $self->pre_lines . "\n";

    return $msg if $1;
    $self->{do_croak} = 1;
    return "$msg\n at $template\n";
}

sub immediate {
    my ($self, $str) = @_;
    if ('DBIx::DR::ByteStream' ~~ Scalar::Util::blessed $str) {
        $self->{sql} .= $str->content;
    } else {
        $self->{sql} .= $str;
    }
    return $self;
}

sub add_bind_value {
    my ($self, @values) = @_;
    push @{ $self->variables } => @values;
}


sub quote {
    my ($self, $variable) = @_;

    return $self->immediate($variable)
        if 'DBIx::DR::ByteStream' ~~ Scalar::Util::blessed $variable;

    $self->{sql} .= '?';
    $self->add_bind_value($variable);
    return $self;
}


sub _parse_token
{
    my ($self, $tpl) = @_;
    my $line_tag       = quotemeta $self->line_tag;
    my $open_tag       = quotemeta $self->open_tag;
    my $close_tag      = quotemeta $self->close_tag;

    if ($tpl =~ s{^(\s*)$line_tag(.*?)$}{$1}sm) {
        return
            { type => 'text', content =>  $` . $1 },
            { type => 'perl', content =>  $2, line => 1 },
            { type => 'text', content =>  $' }
        ;
        next;
    }
    if ($tpl =~ s{$open_tag(.*?)$close_tag}{}s) {
        return
            { type => 'text', content =>  $` },
            { type => 'perl', content =>  $1 },
            { type => 'text', content =>  $' }
        ;
    }

    return {
        type        => 'text',
        content     => $tpl,
        text_only   => 1,
    }
}

sub _put_token {
    my ($self, $token, $next_token) = @_;

    my $content = $token->{content};
    my $variable;

    if ($token->{type} eq 'text') {
        $content =~ s/\}/\\}/g;
        return 'immediate(q{' . $content . '});';
    }

    my $eot = $token->{line} ? "\n" : '';

    my $immediate_mark = quotemeta $self->immediate_mark;
    my $quote_mark = quotemeta $self->quote_mark;

    if ($content =~ /^$immediate_mark/) {
        $content = substr $content, length $self->immediate_mark;
        return 'immediate(' . $content . ");$eot";
    }

    if ($content =~ /^$quote_mark/) {
        $content = substr $content, length $self->quote_mark;
        return 'quote(' . $content . ");$eot";
    }


    return "$content;$eot" if !$next_token or $next_token->{type} ne 'perl';
    return $content . $eot;
}

sub _parse {
    my ($self) = @_;

    my @tokens = { type => 'text', content => $self->template };

    while(1) {
        my $found_token = 0;
        for (reverse 0 .. $#tokens) {
            next unless $tokens[$_]{type} eq 'text';
            next if $tokens[$_]{text_only};
            my @t = $self->_parse_token($tokens[$_]{content});
            next if @t == 1;
            splice @tokens, $_, 1, grep { length $_->{content} } @t;
            $found_token = 1;
        }
        last unless $found_token;
    }

    my $sub = join "" => map {
        $self->_put_token($tokens[$_], $_ == $#tokens ? undef : $tokens[$_ + 1])
    } 0 .. $#tokens;


    return join '',
        'package ', $self->namespace, ';',
        'BEGIN { ',
        '*quote = sub { $_PTPL->quote(@_) };',
        '*immediate = sub { $_PTPL->immediate(@_) };',
        '};',
        $self->preprepend,
        'sub {', $self->prepend, $sub, '}';
}


sub preprepend {
    my ($self, @tokens) = @_;
    $self->{prepretokens} ||= [];
    push @{ $self->prepretokens } => map "$_;\n", @tokens if @tokens;
    return join '' => @{ $self->prepretokens } if defined wantarray;
}

sub prepend {
    my ($self, @tokens) = @_;
    $self->{pretokens} ||= [];
    push @{ $self->pretokens } => map "$_;", @tokens if @tokens;
    return join '' => @{ $self->pretokens } if defined wantarray;
}


sub pre_lines {
    my ($self) = @_;
    my $lines = 0;
    $lines += @{[ /\n/g ]} for $self->preprepend;
    return $lines;
}

sub clean_prepend {
    my ($self) = shift;
    $self->{pretokens} = [];
}

sub clean_namespace {
    my ($self) = @_;
    my $sb = $self->namespace;

    no strict 'refs';
    undef *{$sb . '::' . $_} for keys %{ $sb . '::' };
}

1;

=head1 COPYRIGHT

 Copyright (C) 2011 Dmitry E. Oboukhov <unera@debian.org>
 Copyright (C) 2011 Roman V. Nikolaev <rshadow@rambler.ru>

 This program is free software, you can redistribute it and/or
 modify it under the terms of the Artistic License version 2.0.

=cut
