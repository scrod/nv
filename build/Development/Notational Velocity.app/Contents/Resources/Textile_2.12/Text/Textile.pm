package Text::Textile;

use strict;
use warnings;

use base 'Exporter';
our @EXPORT_OK = qw(textile);
our $VERSION = 2.12;
our $debug = 0;

sub new {
    my $class = shift;
    my %options = @_;
    $options{filters} ||= {};
    $options{charset} ||= 'iso-8859-1';

    for ( qw( char_encoding do_quotes smarty_mode ) ) {
        $options{$_} = 1 unless exists $options{$_};
    }
    for ( qw( trim_spaces preserve_spaces head_offset disable_encode_entities ) ) {
        $options{$_} = 0 unless exists $options{$_};
    }

    my $self = bless \%options, $class;
    if (exists $options{css}) {
        $self->css($options{css});
    }
    $options{macros} ||= $self->default_macros();
    if (exists $options{flavor}) {
        $self->flavor($options{flavor});
    } else {
        $self->flavor('xhtml1/css');
    }
    return $self;
}

# getter/setter methods...

sub set {
    my $self = shift;
    my $opt = shift;
    if (ref $opt eq 'HASH') {
        $self->set($_, $opt->{$_}) foreach %{$opt};
    } else {
        my $value = shift;
        # the following options have special set methods
        # that activate upon setting:
        if ($opt eq 'charset') {
            $self->charset($value);
        } elsif ($opt eq 'css') {
            $self->css($value);
        } elsif ($opt eq 'flavor') {
            $self->flavor($value);
        } else {
            $self->{$opt} = $value;
        }
    }
    return;
}

sub get {
    my $self = shift;
    return $self->{shift} if @_;
    return undef;
}

sub disable_html {
    my $self = shift;
    if (@_) {
        $self->{disable_html} = shift;
    }
    return $self->{disable_html} || 0;
}

sub head_offset {
    my $self = shift;
    if (@_) {
        $self->{head_offset} = shift;
    }
    return $self->{head_offset} || 0;
}

sub flavor {
    my $self = shift;
    if (@_) {
        my $flavor = shift;
        $self->{flavor} = $flavor;
        if ($flavor =~ m/^xhtml(\d)?(\D|$)/) {
            if ($1 eq '2') {
                $self->{_line_open} = '<l>';
                $self->{_line_close} = '</l>';
                $self->{_blockcode_open} = '<blockcode>';
                $self->{_blockcode_close} = '</blockcode>';
                $self->{css_mode} = 1;
            } else {
                # xhtml 1.x
                $self->{_line_open} = '';
                $self->{_line_close} = '<br />';
                $self->{_blockcode_open} = '<pre><code>';
                $self->{_blockcode_close} = '</code></pre>';
                $self->{css_mode} = 1;
            }
        } elsif ($flavor =~ m/^html/) {
            $self->{_line_open} = '';
            $self->{_line_close} = '<br>';
            $self->{_blockcode_open} = '<pre><code>';
            $self->{_blockcode_close} = '</code></pre>';
            $self->{css_mode} = $flavor =~ m/\/css/;
        }
        $self->_css_defaults() if $self->{css_mode} && !exists $self->{css};
    }
    return $self->{flavor};
}

sub css {
    my $self = shift;
    if (@_) {
        my $css = shift;
        if (ref $css eq 'HASH') {
            $self->{css} = $css;
            $self->{css_mode} = 1;
        } else {
            $self->{css_mode} = $css;
            $self->_css_defaults() if $self->{css_mode} && !exists $self->{css};
        }
    }
    return $self->{css_mode} ? $self->{css} : 0;
}

sub charset {
    my $self = shift;
    if (@_) {
        $self->{charset} = shift;
        if ($self->{charset} =~ m/^utf-?8$/i) {
            $self->char_encoding(0);
        } else {
            $self->char_encoding(1);
        }
    }
    return $self->{charset};
}

sub docroot {
    my $self = shift;
    $self->{docroot} = shift if @_;
    return $self->{docroot};
}

sub trim_spaces {
    my $self = shift;
    $self->{trim_spaces} = shift if @_;
    return $self->{trim_spaces};
}

sub filter_param {
    my $self = shift;
    $self->{filter_param} = shift if @_;
    return $self->{filter_param};
}

sub preserve_spaces {
    my $self = shift;
    $self->{preserve_spaces} = shift if @_;
    return $self->{preserve_spaces};
}

sub filters {
    my $self = shift;
    $self->{filters} = shift if @_;
    return $self->{filters};
}

sub char_encoding {
    my $self = shift;
    $self->{char_encoding} = shift if @_;
    return $self->{char_encoding};
}

sub disable_encode_entities {
    my $self = shift;
    $self->{disable_encode_entities} = shift if @_;
    return $self->{disable_encode_entities};
}

sub handle_quotes {
    my $self = shift;
    $self->{do_quotes} = shift if @_;
    return $self->{do_quotes};
}

# end of getter/setter methods

# a URL discovery regex. This is from Mastering Regex from O'Reilly.
# Some modifications by Brad Choate <brad@bradchoate.com>
use vars qw($urlre $blocktags $clstyre $clstypadre $clstyfiltre
            $alignre $valignre $halignre $imgalignre $tblalignre
            $codere $punct);
$urlre = qr{
    # Must start out right...
    (?=[a-zA-Z0-9./#])
    # Match the leading part (proto://hostname, or just hostname)
    (?:
        # ftp://, http://, or https:// leading part
        (?:ftp|https?|telnet|nntp)://(?:\w+(?::\w+)?@)?[-\w]+(?:\.\w[-\w]*)+
        |
        (?:mailto:)?[-\+\w]+\@[-\w]+(?:\.\w[-\w]*)+
        |
        # or, try to find a hostname with our more specific sub-expression
        (?i: [a-z0-9] (?:[-a-z0-9]*[a-z0-9])? \. )+ # sub domains
        # Now ending .com, etc. For these, require lowercase
        (?-i: com\b
            | edu\b
            | biz\b
            | gov\b
            | in(?:t|fo)\b # .int or .info
            | mil\b
            | net\b
            | org\b
            | museum\b
            | aero\b
            | coop\b
            | name\b
            | pro\b
            | [a-z][a-z]\b # two-letter country codes
        )
    )?

    # Allow an optional port number
    (?: : \d+ )?

    # The rest of the URL is optional, and begins with / . . .
    (?:
     /?
     # The rest are heuristics for what seems to work well
     [^.!,?;:"'<>()\[\]{}\s\x7F-\xFF]*
     (?:
        [.!,?;:]+  [^.!,?;:"'<>()\[\]{}\s\x7F-\xFF]+ #'"
     )*
    )?
}x;

$punct = qr{[\!"#\$%&'()\*\+,\-\./:;<=>\?@\[\\\]\^_`{\|}\~]};
$valignre = qr/[\-^~]/;
$tblalignre = qr/[<>=]/;
$halignre = qr/(?:<>|[<>=])/;
$alignre = qr/(?:$valignre|<>$valignre?|$valignre?<>|$valignre?$halignre?|$halignre?$valignre?)(?!\w)/;
$imgalignre = qr/(?:[<>]|$valignre){1,2}/;

$clstypadre = qr/
  (?:\([A-Za-z0-9_\- \#]+\))
  |
  (?:{
      (?: \( [^)]+ \) | [^}] )+
     })
  |
  (?:\(+? (?![A-Za-z0-9_\-\#]) )
  |
  (?:\)+?)
  |
  (?: \[ [a-zA-Z\-]+? \] )
/x;

$clstyre = qr/
  (?:\([A-Za-z0-9_\- \#]+\))
  |
  (?:{
      [A-Za-z0-9_\-](?: \( [^)]+ \) | [^}] )+
     })
  |
  (?: \[ [a-zA-Z\-]+? \] )
/x;

$clstyfiltre = qr/
  (?:\([A-Za-z0-9_\- \#]+\))
  |
  (?:{
      [A-Za-z0-9_\-](?: \( [^)]+ \) | [^}] )+
     })
  |
  (?:\|[^\|]+\|)
  |
  (?:\(+?(?![A-Za-z0-9_\-\#]))
  |
  (?:\)+)
  |
  (?: \[ [a-zA-Z]+? \] )
/x;

$codere = qr/
    (?:
      [\[{]
      @                           # opening
      (?:\[([A-Za-z0-9]+)\])?     # $1: language id
      (.+?)                       # $2: code
      @                           # closing
      [\]}]
    )
    |
    (?:
      (?:^|(?<=[\s\(]))
      @                           # opening
      (?:\[([A-Za-z0-9]+)\])?     # $3: language id
      ([^\s].*?[^\s]?)            # $4: code itself
      @                           # closing
      (?:$|(?=$punct{1,2}|\s))
    )
/x;

$blocktags = qr{
    <
    (( /? ( h[1-6]
     | p
     | pre
     | div
     | table
     | t[rdh]
     | [ou]l
     | li
     | block(?:quote|code)
     | form
     | input
     | select
     | option
     | textarea
     )
    [ >]
    )
    | !--
    )
}x;

sub process {
    my $self = shift;
    return $self->textile(@_);
}

sub textile {
    my $self = shift;
    my ($str) = @_;

    # disable warnings for the sake of various regex that
    # have optional matches
    local $^W = 0;

    if (!ref $self) {
        # oops -- procedural technique used, so make
        # set $str to $self and instantiate a new object
        # for self
        $str = $self;
        $self = new Text::Textile;
    }

    # quick translator for abbreviated block names
    # to their tag
    my %macros = ('bq' => 'blockquote');

    # an array to hold any portions of the text to be preserved
    # without further processing by Textile
    my @repl;

    # strip out extra newline characters. we're only matching for \n herein
    #$str =~ s!(?:\r?\n|\r)!\n!g;
    $str =~ s!(?:\015?\012|\015)!\n!g;

    # optionally remove trailing spaces
    $str =~ s/ +$//gm if $self->{trim_spaces};

    # preserve contents of the '==', 'pre', 'blockcode' sections
    $str =~ s{(^|\n\n)==(.+?)==($|\n\n)}
             {$1."\n\n"._repl(\@repl, $self->format_block(text => $2))."\n\n".$3}ges;

    unless ($self->{disable_html}) {
        # preserve style, script tag contents
        $str =~ s{(<(style|script)(?:>| .+?>).*?</\2>)}{_repl(\@repl, $1)}ges;

        # preserve HTML comments
        $str =~ s{(<!--.+?-->)}{_repl(\@repl, $1)}ges;

        # preserve pre block contents, encode contents by default
        my $pre_start = scalar(@repl);
        $str =~ s{(<pre(?: [^>]*)?>)(.+?)(</pre>)}
                 {"\n\n"._repl(\@repl, $1.$self->encode_html($2, 1).$3)."\n\n"}ges;
        # fix code tags within pre blocks we just saved.
        for (my $i = $pre_start; $i < scalar(@repl); $i++) {
            $repl[$i] =~ s{&lt;(/?)code(.*?)&gt;}{<$1code$2>}gs;
        }

        # preserve code blocks by default, encode contents
        $str =~ s{(<code(?: [^>]+)?>)(.+?)(</code>)}
                 {_repl(\@repl, $1.$self->encode_html($2, 1).$3)}ges;

        # encode blockcode tag (an XHTML 2 tag) and encode it's
        # content by default
        $str =~ s{(<blockcode(?: [^>]+)?>)(.+?)(</blockcode>)}
                 {"\n\n"._repl(\@repl, $1.$self->encode_html($2, 1).$3)."\n\n"}ges;

        # preserve PHPish, ASPish code
        $str =~ s!(<([\?\%]).*?(\2)>)!_repl(\@repl, $1)!ges;
    }

    # pass through and remove links that follow this format
    # [id_without_spaces (optional title text)]url
    # lines like this are stripped from the content, and can be
    # referred to using the "link text":id_without_spaces syntax
    my %links;
    $str =~ s{(?:\n|^) [ ]* \[ ([^ ]+?) [ ]*? (?:\( (.+?) \) )?  \] ((?:(?:ftp|https?|telnet|nntp)://|/)[^ ]+?) [ ]* (\n|$)}
             {($links{$1} = {url => $3, title => $2}),"$4"}gemx;
    local $self->{links} = \%links;

    # eliminate starting/ending blank lines
    $str =~ s/^\n+//s;
    $str =~ s/\n+$//s;

    # split up text into paragraph blocks, capturing newlines too
    my @para = split /(\n{2,})/, $str;
    my ($block, $bqlang, $filter, $class, $sticky, @lines,
        $style, $stickybuff, $lang, $clear);

    my $out = '';

    foreach my $para (@para) {
        if ($para =~ m/^\n+$/s) {
            if ($sticky && defined $stickybuff) {
                $stickybuff .= $para;
            } else {
                $out .= $para;
            }
            next;
        }

        if ($sticky) {
            $sticky++;
        } else {
            $block = undef;
            $class = undef;
            $style = '';
            $lang = undef;
        }

        my ($id, $cite, $align, $padleft, $padright, @lines, $buffer);
        if ($para =~ m/^(h[1-6]|p|bq|bc|fn\d+)
                        ((?:$clstyfiltre*|$halignre)*)
                        (\.\.?)
                        (?::(\d+|$urlre))?\ /gx) {
            if ($sticky) {
                if ($block eq 'bc') {
                    # close our blockcode section
                    $out =~ s/\n\n$//;
                    $out .= $self->{_blockcode_close}."\n\n";
                } elsif ($block eq 'bq') {
                    $out =~ s/\n\n$//;
                    $out .= '</blockquote>'."\n\n";
                } elsif ($block eq 'table') {
                    my $table_out = $self->format_table(text => $stickybuff);
                    $table_out = '' if !defined $table_out;
                    $out .= $table_out;
                    $stickybuff = undef;
                } elsif ($block eq 'dl') {
                    my $dl_out = $self->format_deflist(text => $stickybuff);
                    $dl_out = '' if !defined $dl_out;
                    $out .= $dl_out;
                    $stickybuff = undef;
                }
                $sticky = 0;
            }
            # block macros: h[1-6](class)., bq(class)., bc(class)., p(class).
            #warn "paragraph: [[$para]]\n\tblock: $1\n\tparams: $2\n\tcite: $4";
            $block = $1;
            my $params = $2;
            $cite = $4;
            if ($3 eq '..') {
                $sticky = 1;
            } else {
                $sticky = 0;
                $class = undef;
                $bqlang = undef;
                $lang = undef;
                $style = '';
                $filter = undef;
            }
            if ($block =~ m/^h([1-6])$/) {
                if ($self->{head_offset}) {
                    $block = 'h' . ($1 + $self->{head_offset});
                }
            }
            if ($params =~ m/($halignre+)/) {
                $align = $1;
                $params =~ s/$halignre+//;
            }
            if (defined $params) {
                if ($params =~ m/\|(.+)\|/) {
                    $filter = $1;
                    $params =~ s/\|.+?\|//;
                }
                if ($params =~ m/{([^}]+)}/) {
                    $style = $1;
                    $style =~ s/\n/ /g;
                    $params =~ s/{[^}]+}//g;
                }
                if ($params =~ m/\(([A-Za-z0-9_\-\ ]+?)(?:\#(.+?))?\)/ ||
                    $params =~ m/\(([A-Za-z0-9_\-\ ]+?)?(?:\#(.+?))\)/) {
                    if ($1 || $2) {
                        $class = $1;
                        $id = $2;
                        if ($class) {
                            $params =~ s/\([A-Za-z0-9_\-\ ]+?(#.*?)?\)//g;
                        } elsif ($id) {
                            $params =~ s/\(#.+?\)//g;
                        }
                    }
                }
                if ($params =~ m/(\(+)/) {
                    $padleft = length($1);
                    $params =~ s/\(+//;
                }
                if ($params =~ m/(\)+)/) {
                    $padright = length($1);
                    $params =~ s/\)+//;
                }
                if ($params =~ m/\[(.+?)\]/) {
                    $lang = $1;
                    if ($block eq 'bc') {
                        $bqlang = $lang;
                        $lang = undef;
                    }
                    $params =~ s/\[.+?\]//;
                }
            }
            #warn "settings:\n\tblock: $block\n\tpadleft: $padleft\n\tpadright: $padright\n\tclass: $class\n\tstyle: $style\n\tid: $id\n\tfilter: $filter\n\talign: $align\n\tlang: $lang\n\tsticky: $sticky";
            $para = substr($para, pos($para));
        } elsif ($para =~ m/^<textile#(\d+)>$/) {
            $buffer = $repl[$1-1];
        } elsif ($para =~ m/^clear([<>]+)?\.$/) {
            if ($1 eq '<') {
                $clear = 'left';
            } elsif ($1 eq '>') {
                $clear = 'right';
            } else {
                $clear = 'both';
            }
            next;
        } elsif ($sticky && (defined $stickybuff) &&
                 ($block eq 'table' || $block eq 'dl')) {
            $stickybuff .= $para;
            next;
        } elsif ($para =~ m/^(?:$halignre|$clstypadre*)*
                             [\*\#]
                             (?:$halignre|$clstypadre*)*
                             \ /x) {
            # '*', '#' prefix means a list
            $buffer = $self->format_list(text => $para);
        } elsif ($para =~ m/^(?:table(?:$tblalignre|$clstypadre*)*
                             (\.\.?)\s+)?
                             (?:_|$alignre|$clstypadre*)*\|/x) {
            # handle wiki-style tables
            if (defined $1 && ($1 eq '..')) {
                $block = 'table';
                $stickybuff = $para;
                $sticky = 1;
                next;
            } else {
                $buffer = $self->format_table(text => $para);
            }
        } elsif ($para =~ m/^(?:dl(?:$clstyre)*(\.\.?)\s+)/) {
            # handle definition lists
            if (defined $1 && ($1 eq '..')) {
                $block = 'dl';
                $stickybuff = $para;
                $sticky = 1;
                next;
            } else {
                $buffer = $self->format_deflist(text => $para);
            }
        }
        if (defined $buffer) {
            $out .= $buffer;
            next;
        }
        @lines = split /\n/, $para;
        next unless @lines;

        $block ||= 'p';

        $buffer = '';
        my $pre = '';
        my $post = '';

        if ($block eq 'bc') {
            if ($sticky <= 1) {
                $pre .= $self->{_blockcode_open};
                $pre =~ s/>$//s;
                $pre .= qq{ language="$bqlang"} if $bqlang;
                if ($align) {
                    my $alignment = _halign($align);
                    if ($self->{css_mode}) {
                        if (($padleft || $padright) &&
                            (($alignment eq 'left') || ($alignment eq 'right'))) {
                            $style .= ';float:'.$alignment;
                        } else {
                            $style .= ';text-align:'.$alignment;
                        }
                        $class .= ' '.$self->{css}{"class_align_$alignment"} || $alignment;
                    } else {
                        $pre .= qq{ align="$alignment"} if $alignment;
                    }
                }
                $style .= qq{;padding-left:${padleft}em} if $padleft;
                $style .= qq{;padding-right:${padright}em} if $padright;
                $style .= qq{;clear:${clear}} if $clear;
                $class =~ s/^ // if $class;
                $pre .= qq{ class="$class"} if $class;
                $pre .= qq{ id="$id"} if $id;
                $style =~ s/^;// if $style;
                $pre .= qq{ style="$style"} if $style;
                $pre .= qq{ lang="$lang"} if $lang;
                $pre .= '>';
                $lang = undef;
                $bqlang = undef;
                $clear = undef;
            }
            $para =~ s{(?:^|(?<=[\s>])|([{[]))
                       ==(.+?)==
                       (?:$|([\]}])|(?=$punct{1,2}|\s))}
                      {_repl(\@repl, $self->format_block(text => $2, inline => 1, pre => $1, post => $3))}gesx;
            $buffer .= $self->encode_html_basic($para, 1);
            $buffer =~ s/&lt;textile#(\d+)&gt;/<textile#$1>/g;
            if ($sticky == 0) {
                $post .= $self->{_blockcode_close};
            }
            $out .= $pre . $buffer . $post;
            next;
        } elsif ($block eq 'bq') {
            if ($sticky <= 1) {
                $pre .= '<blockquote';
                if ($align) {
                    my $alignment = _halign($align);
                    if ($self->{css_mode}) {
                        if (($padleft || $padright) &&
                            (($alignment eq 'left') || ($alignment eq 'right'))) {
                            $style .= ';float:'.$alignment;
                        } else {
                            $style .= ';text-align:'.$alignment;
                        }
                        $class .= ' '.$self->{css}{"class_align_$alignment"} || $alignment;
                    } else {
                        $pre .= qq{ align="$alignment"} if $alignment;
                    }
                }
                $style .= qq{;padding-left:${padleft}em} if $padleft;
                $style .= qq{;padding-right:${padright}em} if $padright;
                $style .= qq{;clear:${clear}} if $clear;
                $class =~ s/^ // if $class;
                $pre .= qq{ class="$class"} if $class;
                $pre .= qq{ id="$id"} if $id;
                $style =~ s/^;// if $style;
                $pre .= qq{ style="$style"} if $style;
                $pre .= qq{ lang="$lang"} if $lang;
                $pre .= q{ cite="} . $self->format_url(url => $cite) . '"' if defined $cite;
                $pre .= '>';
                $clear = undef;
            }
            $pre .= '<p>';
        } elsif ($block =~ m/fn(\d+)/) {
            my $fnum = $1;
            $pre .= '<p';
            $class .= ' '.$self->{css}{class_footnote} if $self->{css}{class_footnote};
            if ($align) {
                my $alignment = _halign($align);
                if ($self->{css_mode}) {
                    if (($padleft || $padright) &&
                        (($alignment eq 'left') || ($alignment eq 'right'))) {
                        $style .= ';float:'.$alignment;
                    } else {
                        $style .= ';text-align:'.$alignment;
                    }
                    $class .= $self->{css}{"class_align_$alignment"} || $alignment;
                } else {
                    $pre .= qq{ align="$alignment"};
                }
            }
            $style .= qq{;padding-left:${padleft}em} if $padleft;
            $style .= qq{;padding-right:${padright}em} if $padright;
            $style .= qq{;clear:${clear}} if $clear;
            $class =~ s/^ // if $class;
            $pre .= qq{ class="$class"} if $class;
            $pre .= qq{ id="}.($self->{css}{id_footnote_prefix}||'fn').$fnum.'"';
            $style =~ s/^;// if $style;
            $pre .= qq{ style="$style"} if $style;
            $pre .= qq{ lang="$lang"} if $lang;
            $pre .= '>';
            $pre .= '<sup>'.$fnum.'</sup> ';
            # we can close like a regular paragraph tag now
            $block = 'p';
            $clear = undef;
        } else {
            $pre .= '<' . ($macros{$block} || $block);
            if ($align) {
                my $alignment = _halign($align);
                if ($self->{css_mode}) {
                    if (($padleft || $padright) &&
                        (($alignment eq 'left') || ($alignment eq 'right'))) {
                        $style .= ';float:'.$alignment;
                    } else {
                        $style .= ';text-align:'.$alignment;
                    }
                    $class .= ' '.$self->{css}{"class_align_$alignment"} || $alignment;
                } else {
                    $pre .= qq{ align="$alignment"};
                }
            }
            $style .= qq{;padding-left:${padleft}em} if $padleft;
            $style .= qq{;padding-right:${padright}em} if $padright;
            $style .= qq{;clear:${clear}} if $clear;
            $class =~ s/^ // if $class;
            $pre .= qq{ class="$class"} if $class;
            $pre .= qq{ id="$id"} if $id;
            $style =~ s/^;// if $style;
            $pre .= qq{ style="$style"} if $style;
            $pre .= qq{ lang="$lang"} if $lang;
            $pre .= qq{ cite="} . $self->format_url(url => $cite) . '"' if defined $cite && $block eq 'bq'; #'
            $pre .= '>';
            $clear = undef;
        }

        $buffer = $self->format_paragraph(text => $para);

        if ($block eq 'bq') {
            $post .= '</p>' if $buffer !~ m/<p[ >]/;
            if ($sticky == 0) {
                $post .= '</blockquote>';
            }
        } else {
            $post .= '</' . $block . '>';
        }

        if ($buffer =~ m/$blocktags/) {
            $buffer =~ s/^\n\n//s;
            $out .= $buffer;
        } else {
            $buffer = $self->format_block(text => "|$filter|".$buffer, inline => 1) if defined $filter;
            $out .= $pre . $buffer . $post;
        }
    }

    if ($sticky) {
        if ($block eq 'bc') {
            # close our blockcode section
            $out .= $self->{_blockcode_close}; # . "\n\n";
        } elsif ($block eq 'bq') {
            $out .= '</blockquote>'; # . "\n\n";
        } elsif (($block eq 'table') && ($stickybuff)) {
            my $table_out = $self->format_table(text => $stickybuff);
            $out .= $table_out if defined $table_out;
        } elsif (($block eq 'dl') && ($stickybuff)) {
            my $dl_out = $self->format_deflist(text => $stickybuff);
            $out .= $dl_out if defined $dl_out;
        }
    }

    # cleanup-- restore preserved blocks
    my $i = scalar(@repl);
    $out =~ s!(?:<|&lt;)textile#$i(?:>|&gt;)!$_!, $i-- while local $_ = pop @repl;

    # scan for br, hr tags that are not closed and close them
    # only for xhtml! just the common ones -- don't fret over input
    # and the like.
    if ($self->{flavor} =~ m/^xhtml/i) {
        $out =~ s/(<(?:img|br|hr)[^>]*?(?<!\/))>/$1 \/>/g;
    }

    return $out;
}

sub format_paragraph {
    my $self = shift;
    my (%args) = @_;
    my $buffer = defined $args{text} ? $args{text} : '';

    my @repl;
    $buffer =~ s{(?:^|(?<=[\s>])|([{[]))
                 ==(.+?)==
                 (?:$|([\]}])|(?=$punct{1,2}|\s))}
                {_repl(\@repl, $self->format_block(text => $2, inline => 1, pre => $1, post => $3))}gesx;

    my $tokens;
    if ($buffer =~ m/</ && (!$self->{disable_html})) {  # optimization -- no point in tokenizing if we
                            # have no tags to tokenize
        $tokens = _tokenize($buffer);
    } else {
        $tokens = [['text', $buffer]];
    }
    my $result = '';
    foreach my $token (@{$tokens}) {
        my $text = $token->[1];
        if ($token->[0] eq 'tag') {
            $text =~ s/&(?!amp;)/&amp;/g;
            $result .= $text;
        } else {
            $text = $self->format_inline(text => $text);
            $result .= $text;
        }
    }

    # now, add line breaks for lines that contain plaintext
    my @lines = split /\n/, $result;
    $result = '';
    my $needs_closing = 0;
    foreach my $line (@lines) {
        if (($line !~ m/($blocktags)/)
            && (($line =~ m/^[^<]/ || $line =~ m/>[^<]/)
                || ($line !~ m/<img /))) {
            if ($self->{_line_open}) {
                $result .= "\n" if $result ne '';
                $result .= $self->{_line_open} . $line . $self->{_line_close};
            } else {
                if ($needs_closing) {
                    $result .= $self->{_line_close} ."\n";
                } else {
                    $needs_closing = 1;
                    $result .= "\n" if $result ne '';
                }
                $result .= $line;
            }
        } else {
            if ($needs_closing) {
                $result .= $self->{_line_close} ."\n";
            } else {
                $result .= "\n" if $result ne '';
            }
            $result .= $line;
            $needs_closing = 0;
        }
    }

    # at this point, we will restore the \001's to \n's (reversing
    # the step taken in _tokenize).
    #$result =~ s/\r/\n/g;
    $result =~ s/\001/\n/g;

    my $i = scalar(@repl);
    $result =~ s|<textile#$i>|$_|, $i-- while local $_ = pop @repl;

    # quotalize
    if ($self->{do_quotes}) {
        $result = $self->process_quotes($result);
    }

    return $result;
}

{
my @qtags = (['**', 'b',      '(?<!\*)\*\*(?!\*)', '\*'],
             ['__', 'i',      '(?<!_)__(?!_)', '_'],
             ['??', 'cite',   '\?\?(?!\?)', '\?'],
             ['*',  'strong', '(?<!\*)\*(?!\*)', '\*'],
             ['_',  'em',     '(?<!_)_(?!_)', '_'],
             ['-',  'del',    '(?<!\-)\-(?!\-)', '-'],
             ['+',  'ins',    '(?<!\+)\+(?!\+)', '\+'],
             ['++', 'big',    '(?<!\+)\+\+(?!\+)', '\+\+'],
             ['--', 'small',  '(?<!\-)\-\-(?!\-)', '\-\-'],
             ['~',  'sub',    '(?<!\~)\~(?![\\\/~])', '\~']);


sub format_inline {
    my $self = shift;
    my (%args) = @_;
    my $text = defined $args{text} ? $args{text} : '';

    my @repl;

    no warnings 'uninitialized';
    $text =~ s{$codere}{_repl(\@repl, $self->format_code(text => $2.$4, lang => $1.$3))}gem;

    # images must be processed before encoding the text since they might
    # have the <, > alignment specifiers...

    # !blah (alt)! -> image
    $text =~ s!(?:^|(?<=[\s>])|([{[]))     # $1: open brace/bracket
               \!                          # opening
               ($imgalignre?)              # $2: optional alignment
               ($clstypadre*)              # $3: optional CSS class/id
               ($imgalignre?)              # $4: optional alignment
               (?:\s*)                     # space between alignment/css stuff
               ([^\s\(\!]+)                # $5: filename
               (\s*[^\(\!]*(?:\([^\)]+\))?[^\!]*) # $6: extras (alt text)
               \!                          # closing
               (?::(\d+|$urlre))?          # $7: optional URL
               (?:$|([\]}])|(?=$punct{1,2}|\s))# $8: closing brace/bracket
              !_repl(\@repl, $self->format_image(pre => $1, src => $5, align => $2||$4, extra => $6, url => $7, clsty => $3, post => $8))!gemx;

    $text =~ s!(?:^|(?<=[\s>])|([{[]))     # $1: open brace/bracket
               \%                          # opening
               ($halignre?)                # $2: optional alignment
               ($clstyre*)                 # $3: optional CSS class/id
               ($halignre?)                # $4: optional alignment
               (?:\s*)                     # spacing
               ([^\%]+?)                   # $5: text
               \%                          # closing
               (?::(\d+|$urlre))?          # $6: optional URL
               (?:$|([\]}])|(?=$punct{1,2}|\s))# $7: closing brace/bracket
              !_repl(\@repl, $self->format_span(pre => $1,text => $5,align => $2||$4, cite => $6, clsty => $3, post => $7))!gemx;

    $text = $self->encode_html($text);
    $text =~ s!&lt;textile#(\d+)&gt;!<textile#$1>!g;
    $text =~ s!&amp;quot;!&#34;!g;
    $text =~ s!&amp;(([a-z]+|#\d+);)!&$1!g;
    $text =~ s!&quot;!"!g; #"

    # These create markup with entities. Do first and 'save' result for later:
    # "text":url -> hyperlink
    # links with brackets surrounding
    my $parenre = qr/\( (?: [^()] )* \)/x;
    $text =~ s!(
               [{[]
               (?:
                   (?:"                    # quote character
                      ($clstyre*)?         # $2: optional CSS class/id
                      ([^"]+?)             # $3: link text
                      (?:\( ( (?:[^()]|$parenre)*) \))? # $4: optional link title
                      "                    # closing quote
                   )
                   |
                   (?:'                    # open single quote
                      ($clstyre*)?         # $5: optional CSS class/id
                      ([^']+?)             # $6: link text
                      (?:\( ( (?:[^()]|$parenre)*) \))? # $7: optional link title
                      '                    # closing quote
                   )
               )
               :(.+?)                      # $8: URL suffix
               [\]}]
              )
              !_repl(\@repl,
                    $self->format_link(
                        text     => $1,
                        linktext => defined $3 ? $3 : $6,
                        title    => $self->encode_html_basic( defined $4 ? $4 : $7 ),
                        url      => $8,
                        clsty    => defined $2 ? $2 : $5)
                )!gemx;

    $text =~ s!((?:^|(?<=[\s>\(]))         # $1: open brace/bracket
               (?: (?:"                    # quote character "
                      ($clstyre*)?         # $2: optional CSS class/id
                      ([^"]+?)             # $3: link text "
                      (?:\( ( (?:[^()]|$parenre)*) \))?    # $4: optional link title
                      "                    # closing quote # "
                   )
                   |
                   (?:'                    # open single quote '
                      ($clstyre*)?         # $5: optional CSS class/id
                      ([^']+?)             # $6: link text '
                      (?:\( ( (?:[^()]|$parenre)*) \))?  # $7: optional link title
                      '                    # closing quote '
                   )
               )
               :(\d+|$urlre)               # $8: URL suffix
               (?:$|(?=$punct{1,2}|\s)))   # $9: closing brace/bracket
              !_repl(\@repl,
                    $self->format_link(
                        text     => $1,
                        linktext => defined $3 ? $3 : $6,
                        title    => $self->encode_html_basic( defined $4 ? $4 : $7 ),
                        url      => $8,
                        clsty    => defined $2 ? $2 : $5)
                )!gemx;

    if ($self->{flavor} =~ m/^xhtml2/) {
        # citation with cite link
        $text =~ s!(?:^|(?<=[\s>'"\(])|([{[])) # $1: open brace/bracket '
                   \?\?                        # opening '??'
                   ([^\?]+?)                   # $2: characters (can't contain '?')
                   \?\?                        # closing '??'
                   :(\d+|$urlre)               # $3: optional citation URL
                   (?:$|([\]}])|(?=$punct{1,2}|\s))# $4: closing brace/bracket
                  !_repl(\@repl, $self->format_cite(pre => $1,text => $2,cite => $3,post => $4))!gemx;
    }

    # footnotes
    if ($text =~ m/[^ ]\[\d+\]/) {
        my $fntag = '<sup';
        $fntag .= ' class="'.$self->{css}{class_footnote}.'"' if $self->{css}{class_footnote};
        $fntag .= '><a href="#'.($self->{css}{id_footnote_prefix}||'fn');
        $text =~ s{([^ ])\[(\d+)\]}{$1$fntag$2">$2</a></sup>}g;
    }

    # translate macros:
    $text =~ s{(\{)(.+?)(\})}
              {$self->format_macro(pre => $1, post => $3, macro => $2)}gex;

    # these were present with textile 1 and are common enough
    # to not require macro braces...
    # (tm) -> &trade;
    $text =~ s{[\(\[]TM[\)\]]}{&#8482;}gi;
    # (c) -> &copy;
    $text =~ s{[\(\[]C[\)\]]}{&#169;}gi;
    # (r) -> &reg;
    $text =~ s{[\(\[]R[\)\]]}{&#174;}gi;

    if ($self->{preserve_spaces}) {
        # replace two spaces with an em space
        $text =~ s/(?<!\s)\ \ (?!=\s)/&#8195;/g;
    }

    my $redo = $text =~ m/[\*_\?\-\+\^\~]/;
    my $last = $text;
    while ($redo) {
        # simple replacements...
        $redo = 0;
        foreach my $tag (@qtags) {
            my ($f, $r, $qf, $cls) = @{$tag};
            if ($text =~ s/(?:^|(?<=[\s>'"])|([{[])) # "' $1 - pre
                           $qf                       #
                           (?:($clstyre*))?          # $2 - attributes
                           ([^$cls\s].*?)            # $3 - content
                           (?<=\S)$qf                #
                           (?:$|([\]}])|(?=$punct{1,2}|\s)) # $4 - post
                          /$self->format_tag(tag => $r, marker => $f, pre => $1, text => $3, clsty => $2, post => $4)/gemx) {
                    $redo ||= $last ne $text;
                    $last = $text;
            }
        }
    }

    # superscript is an even simpler replacement...
    $text =~ s/(?<!\^)\^(?!\^)(.+?)(?<!\^)\^(?!\^)/<sup>$1<\/sup>/g;

    # ABC(Aye Bee Cee) -> acronym
    $text =~ s{\b([A-Z][A-Za-z0-9]*?[A-Z0-9]+?)\b(?:[(]([^)]*)[)])}
              {_repl(\@repl,qq{<acronym title="}.$self->encode_html_basic($2).qq{">$1</acronym>})}ge;

    # ABC -> 'capped' span
    if (my $caps = $self->{css}{class_caps}) {
        $text =~ s/(^|[^"][>\s])  # "
                   ((?:[A-Z](?:[A-Z0-9\.,']|\&amp;){2,}\ *)+?) # '
                   (?=[^A-Z\.0-9]|$)
                  /$1._repl(\@repl, qq{<span class="$caps">$2<\/span>})/gemx;
    }

    # nxn -> n&times;n
    $text =~ s{((?:[0-9\.]0|[1-9]|\d['"])\ ?)x(\ ?\d)}{$1&#215;$2}g;

    # translate these entities to the Unicode equivalents:
    $text =~ s/&#133;/&#8230;/g;
    $text =~ s/&#145;/&#8216;/g;
    $text =~ s/&#146;/&#8217;/g;
    $text =~ s/&#147;/&#8220;/g;
    $text =~ s/&#148;/&#8221;/g;
    $text =~ s/&#150;/&#8211;/g;
    $text =~ s/&#151;/&#8212;/g;

    # Restore replacements done earlier:
    my $i = scalar(@repl);
    $text =~ s|<textile#$i>|$_|, $i-- while local $_ = pop @repl;

    # translate entities to characters for highbit stuff since
    # we're using utf8
    # removed for backward compatability with older versions of Perl
    #if ($self->{charset} =~ m/^utf-?8$/i) {
    #    # translate any unicode entities to native UTF-8
    #    $text =~ s/\&\#(\d+);/($1 > 127) ? pack('U',$1) : chr($1)/ge;
    #}

    $text;
}
}

{
    # pull in charnames, but only for Perl 5.8 or later (and
    # disable strict subs for backward compatability
    my $Have_Charnames = 0;
    if ($] >= 5.008) {
        eval 'use charnames qw(:full);';
        $Have_Charnames = 1;
    }

    sub format_macro {
        my $self = shift;
        my %attrs = @_;
        my $macro = $attrs{macro};
        if (defined $self->{macros}->{$macro}) {
            return $self->{macros}->{$macro};
        }

        # handle full unicode name translation
        if ($Have_Charnames) {
            # charnames::vianame is only available in Perl 5.8.0 and later...
            if (defined (my $unicode = charnames::vianame(uc($macro)))) {
                return '&#'.$unicode.';';
            }
        }

        return $attrs{pre}.$macro.$attrs{post};
    }
}

sub format_cite {
    my $self = shift;
    my (%args) = @_;
    my $pre  = defined $args{pre}  ? $args{pre}  : '';
    my $text = defined $args{text} ? $args{text} : '';
    my $post = defined $args{post} ? $args{post} : '';
    my $cite = $args{cite};
    _strip_borders(\$pre, \$post);
    my $tag = $pre.'<cite';
    if (($self->{flavor} =~ m/^xhtml2/) && defined $cite && $cite) {
        $cite = $self->format_url(url => $cite);
        $tag .= qq{ cite="$cite"};
    } else {
        $post .= ':';
    }
    $tag .= '>';
    return $tag . $self->format_inline(text => $text) . '</cite>'.$post;
}

sub format_code {
    my $self = shift;
    my (%args) = @_;
    my $code = defined $args{text} ? $args{text} : '';
    my $lang = $args{lang};
    $code = $self->encode_html($code, 1);
    $code =~ s/&lt;textile#(\d+)&gt;/<textile#$1>/g;
    my $tag = '<code';
    $tag .= " language=\"$lang\"" if $lang;
    return $tag . '>' . $code . '</code>';
}

sub format_classstyle {
    my $self = shift;
    my ($clsty, $class, $style) = @_;

    $style = ''      if not defined $style;
    $class =~ s/^ // if     defined $class;

    my ($lang, $padleft, $padright, $id);
    if ($clsty && ($clsty =~ m/{([^}]+)}/)) {
        my $_style = $1;
        $_style =~ s/\n/ /g;
        $style .= ';'.$_style;
        $clsty =~ s/{[^}]+}//g;
    }
    if ($clsty && ($clsty =~ m/\(([A-Za-z0-9_\- ]+?)(?:#(.+?))?\)/ ||
                   $clsty =~ m/\(([A-Za-z0-9_\- ]+?)?(?:#(.+?))\)/)) {
        if ($1 || $2) {
            if ($class) {
                $class = $1 . ' ' . $class;
            } else {
                $class = $1;
            }
            $id = $2;
            if ($class) {
                $clsty =~ s/\([A-Za-z0-9_\- ]+?(#.*?)?\)//g;
            }
            if ($id) {
                $clsty =~ s/\(#.+?\)//g;
            }
        }
    }
    if ($clsty && ($clsty =~ m/(\(+)/)) {
        $padleft = length($1);
        $clsty =~ s/\(+//;
    }
    if ($clsty && ($clsty =~ m/(\)+)/)) {
        $padright = length($1);
        $clsty =~ s/\)+//;
    }
    if ($clsty && ($clsty =~ m/\[(.+?)\]/)) {
        $lang = $1;
        $clsty =~ s/\[.+?\]//g;
    }
    my $attrs = '';

    $style .= qq{;padding-left:${padleft}em} if $padleft;
    $style .= qq{;padding-right:${padright}em} if $padright;
    $style =~ s/^;//;

    if ( $class ) {
        $class =~ s/^ //;
        $class =~ s/ $//;
        $attrs .= qq{ class="$class"};
    }
    $attrs .= qq{ id="$id"} if $id;
    $attrs .= qq{ style="$style"} if $style;
    $attrs .= qq{ lang="$lang"} if $lang;
    $attrs =~ s/^ //;

    return $attrs;
}

sub format_tag {
    my $self = shift;
    my (%args) = @_;
    my $tagname = $args{tag};
    my $text  = defined $args{text}  ? $args{text}  : '';
    my $pre   = defined $args{pre}   ? $args{pre}   : '';
    my $post  = defined $args{post}  ? $args{post}  : '';
    my $clsty = defined $args{clsty} ? $args{clsty} : '';
    _strip_borders(\$pre, \$post);
    my $tag = "<$tagname";
    my $attr = $self->format_classstyle($clsty);
    $tag .= qq{ $attr} if $attr;
    $tag .= qq{>$text</$tagname>};

    return $pre.$tag.$post;
}

sub format_deflist {
    my $self = shift;
    my (%args) = @_;
    my $str = defined $args{text} ? $args{text} : '';
    my $clsty;
    my @lines = split /\n/, $str;
    if ($lines[0] =~ m/^(dl($clstyre*?)\.\.?(?:\ +|$))/) {
        $clsty = $2;
        $lines[0] = substr($lines[0], length($1));
    }


    my ($dt, $dd);
    my $out = '';
    foreach my $line (@lines) {
        if ($line =~ m/^((?:$clstyre*)(?:[^\ ].*?)(?<!["'\ ])):([^\ \/].*)$/) {
            $out .= add_term($self, $dt, $dd) if ($dt && $dd);
            $dt = $1;
            $dd = $2;
        } else {
            $dd .= "\n" . $line;
        }
    }
    $out .= add_term($self, $dt, $dd) if $dt && $dd;

    my $tag = '<dl';
    my $attr;
    $attr = $self->format_classstyle($clsty) if $clsty;
    $tag .= qq{ $attr} if $attr;
    $tag .= '>'."\n";

    return $tag.$out."</dl>\n";
}

sub add_term {
    my ($self, $dt, $dd) = @_;
    my ($dtattr, $ddattr);
    my $dtlang;
    if ($dt =~ m/^($clstyre*)/) {
        my $param = $1;
        $dtattr = $self->format_classstyle($param);
        if ($param =~ m/\[([A-Za-z]+?)\]/) {
            $dtlang = $1;
        }
        $dt = substr($dt, length($param));
    }
    if ($dd =~ m/^($clstyre*)/) {
        my $param = $1;
        # if the language was specified for the term,
        # then apply it to the definition as well (unless
        # already specified of course)
        if ($dtlang && ($param =~ m/\[([A-Za-z]+?)\]/)) {
            undef $dtlang;
        }
        $ddattr = $self->format_classstyle(($dtlang ? "[$dtlang]" : '') . $param);
        $dd = substr($dd, length($param));
    }
    my $out = '<dt';
    $out .= qq{ $dtattr} if $dtattr;
    $out .= '>' . $self->format_inline(text => $dt) . '</dt>' . "\n";
    if ($dd =~ m/\n\n/) {
        $dd = $self->textile($dd) if $dd =~ m/\n\n/;
    } else {
        $dd = $self->format_paragraph(text => $dd);
    }
    $out .= '<dd';
    $out .= qq{ $ddattr} if $ddattr;
    $out .= '>' . $dd . '</dd>' . "\n";

    return $out;
}


sub format_list {
    my $self = shift;
    my (%args) = @_;
    my $str = defined $args{text} ? $args{text} : '';

    my %list_tags = ('*' => 'ul', '#' => 'ol');

    my @lines = split /\n/, $str;

    my @stack;
    my $last_depth = 0;
    my $item = '';
    my $out = '';
    foreach my $line (@lines) {
        if ($line =~ m/^((?:$clstypadre*|$halignre)*)
                       ([\#\*]+)
                       ((?:$halignre|$clstypadre*)*)
                       \ (.+)$/x) {
            if ($item ne '') {
                if ($item =~ m/\n/) {
                    if ($self->{_line_open}) {
                        $item =~ s/(<li[^>]*>|^)/$1$self->{_line_open}/gm;
                        $item =~ s/(\n|$)/$self->{_line_close}$1/gs;
                    } else {
                        $item =~ s/(\n)/$self->{_line_close}$1/gs;
                    }
                }
                $out .= $item;
                $item = '';
            }
            my $type = substr($2, 0, 1);
            my $depth = length($2);
            my $blockparam = $1;
            my $itemparam = $3;
            $line = $4;
            my ($blockclsty, $blockalign, $blockattr, $itemattr, $itemclsty,
                $itemalign);
            if ($blockparam =~ m/($clstypadre+)/) {
                $blockclsty = $1;
            }
            if ($blockparam =~ m/($halignre+)/) {
                $blockalign = $1;
            }
            if ($itemparam =~ m/($clstypadre+)/) {
                $itemclsty = $1;
            }
            if ($itemparam =~ m/($halignre+)/) {
                $itemalign = $1;
            }
            $itemattr = $self->format_classstyle($itemclsty) if $itemclsty;
            if ($depth > $last_depth) {
                for (my $j = $last_depth; $j < $depth; $j++) {
                    $out .= qq{<$list_tags{$type}};
                    push @stack, $type;
                    if ($blockclsty) {
                        $blockattr = $self->format_classstyle($blockclsty);
                        $out .= ' '.$blockattr if $blockattr;
                    }
                    $out .= ">\n<li";
                    $out .= qq{ $itemattr} if $itemattr;
                    $out .= ">";
                }
            } elsif ($depth < $last_depth) {
                for (my $j = $depth; $j < $last_depth; $j++) {
                    $out .= "</li>\n" if $j == $depth;
                    my $type = pop @stack;
                    $out .= qq{</$list_tags{$type}>\n</li>\n};
                }
                if ($depth) {
                    $out .= '<li';
                    $out .= qq{ $itemattr} if $itemattr;
                    $out .= '>';
                }
            } else {
                $out .= "</li>\n<li";
                $out .= qq{ $itemattr} if $itemattr;
                $out .= '>';
            }
            $last_depth = $depth;
        }
        $item .= "\n" if $item ne '';
        $item .= $self->format_paragraph(text => $line);
    }

    if ($item =~ m/\n/) {
        if ($self->{_line_open}) {
            $item =~ s/(<li[^>]*>|^)/$1$self->{_line_open}/gm;
            $item =~ s/(\n|$)/$self->{_line_close}$1/gs;
        } else {
            $item =~ s/(\n)/$self->{_line_close}$1/gs;
        }
    }
    $out .= $item;

    for (my $j = 1; $j <= $last_depth; $j++) {
        $out .= '</li>' if $j == 1;
        my $type = pop @stack;
        $out .= "\n".'</'.$list_tags{$type}.'>';
        $out .= '</li>' if $j != $last_depth;
    }

    return $out;
}

sub format_block {
    my $self = shift;
    my (%args) = @_;
    my $str    = defined $args{text} ? $args{text} : '';
    my $pre    = defined $args{pre}  ? $args{pre}  : '';
    my $post   = defined $args{post} ? $args{post} : '';
    my $inline = $args{inline};
    _strip_borders(\$pre, \$post);
    my ($filters) = $str =~ m/^(\|(?:(?:[a-z0-9_\-]+)\|)+)/;
    if ($filters) {
        my $filtreg = quotemeta($filters);
        $str =~ s/^$filtreg//;
        $filters =~ s/^\|//;
        $filters =~ s/\|$//;
        my @filters = split /\|/, $filters;
        $str = $self->apply_filters(text => $str, filters => \@filters);
        my $count = scalar(@filters);
        if ($str =~ s!(<p>){$count}!$1!gs) {
            $str =~ s!(</p>){$count}!$1!gs;
            $str =~ s!(<br( /)?>){$count}!$1!gs;
        }
    }
    if ($inline) {
        # strip off opening para, closing para, since we're
        # operating within an inline block
        $str =~ s/^\s*<p[^>]*>//;
        $str =~ s/<\/p>\s*$//;
    }

    return $pre.$str.$post;
}

sub format_link {
    my $self = shift;
    my (%args) = @_;
    my $text     = defined $args{text}     ? $args{text}     : '';
    my $linktext = defined $args{linktext} ? $args{linktext} : '';
    my $title    = $args{title};
    my $url      = $args{url};
    my $clsty    = $args{clsty};

    if (!defined $url || $url eq '') {
        return $text;
    }
    if ($self->{links} && $self->{links}{$url}) {
        $title ||= $self->{links}{$url}{title};
        $url     = $self->{links}{$url}{url};
    }
    $linktext =~ s/ +$//;
    $linktext = $self->format_paragraph(text => $linktext);
    $url = $self->format_url(linktext => $linktext, url => $url);
    my $tag = qq{<a href="$url"};
    my $attr = $self->format_classstyle($clsty);
    $tag .= qq{ $attr} if $attr;
    if (defined $title) {
        $title =~ s/^\s+//;
        $tag .= qq{ title="$title"} if length($title);
    }
    $tag .= qq{>$linktext</a>};

    return $tag;
}

sub format_url {
    my $self = shift;
    my (%args) = @_;
    my $url = defined $args{url} ? $args{url} : '';
    if ($url =~ m/^(mailto:)?([-\+\w]+\@[-\w]+(\.\w[-\w]*)+)$/) {
        $url = 'mailto:'.$self->mail_encode($2);
    }
    if ($url !~ m{^(/|\./|\.\./|#)}) {
        $url = "http://$url" if $url !~ m{^(?:https?|ftp|mailto|nntp|telnet)};
    }
    $url =~ s/&(?!amp;)/&amp;/g;
    $url =~ s/ /\+/g;
    $url =~ s/^((?:.+?)\?)(.+)$/$1.$self->encode_url($2)/ge;

    return $url;
}

sub format_span {
    my $self = shift;
    my (%args) = @_;
    my $text = defined $args{text} ? $args{text} : '';
    my $pre  = defined $args{pre}  ? $args{pre}  : '';
    my $post = defined $args{post} ? $args{post} : '';
    my $cite = defined $args{cite} ? $args{cite} : '';
    my $align = $args{align};
    my $clsty = $args{clsty};
    _strip_borders(\$pre, \$post);
    my ($class, $style);
    my $tag  = qq{<span};
    $style = '';
    if (defined $align) {
        if ($self->{css_mode}) {
            my $alignment = _halign($align);
            $style .= qq{;float:$alignment} if $alignment;
            $class .= ' '.$self->{css}{"class_align_$alignment"} if $alignment;
        } else {
            my $alignment = _halign($align) || _valign($align);
            $tag .= qq{ align="$alignment"} if $alignment;
        }
    }
    my $attr = $self->format_classstyle($clsty, $class, $style);
    $tag .= qq{ $attr} if $attr;
    if (defined $cite) {
        $cite =~ s/^://;
        $cite = $self->format_url(url => $cite);
        $tag .= qq{ cite="$cite"};
    }

    return $pre.$tag.'>'.$self->format_paragraph(text => $text).'</span>'.$post;
}

sub format_image {
    my $self = shift;
    my (%args) = @_;
    my $src   = defined $args{src}  ? $args{src}  : '';
    my $pre   = defined $args{pre}  ? $args{pre}  : '';
    my $post  = defined $args{post} ? $args{post} : '';
    my $extra = $args{extra};
    my $align = $args{align};
    my $link  = $args{url};
    my $clsty = $args{clsty};
    _strip_borders(\$pre, \$post);
    return $pre.'!!'.$post if length($src) == 0;
    my $tag;
    if ($self->{flavor} =~ m/^xhtml2/) {
        my $type; # poor man's mime typing. need to extend this externally
        if ($src =~ m/(?:\.jpeg|\.jpg)$/i) {
            $type = 'image/jpeg';
        } elsif ($src =~ m/\.gif$/i) {
            $type = 'image/gif';
        } elsif ($src =~ m/\.png$/i) {
            $type = 'image/png';
        } elsif ($src =~ m/\.tiff$/i) {
            $type = 'image/tiff';
        }
        $tag = qq{<object};
        $tag .= qq{ type="$type"} if $type;
        $tag .= qq{ data="$src"};
    } else {
        $tag = qq{<img src="$src"};
    }
    my ($class, $style);
    if (defined $align) {
        if ($self->{css_mode}) {
            my $alignment = _halign($align);
            $style .= qq{;float:$alignment} if $alignment;
            $class .= ' '.$alignment if $alignment;
            $alignment = _valign($align);
            if ($alignment) {
                my $imgvalign = ($alignment =~ m/(top|bottom)/ ? 'text-' . $alignment : $alignment);
                $style .= qq{;vertical-align:$imgvalign} if $imgvalign;
                $class .= ' '.$self->{css}{"class_align_$alignment"} if $alignment;
            }
        } else {
            my $alignment = _halign($align) || _valign($align);
            $tag .= qq{ align="$alignment"} if $alignment;
        }
    }
    my ($pctw, $pcth, $w, $h, $alt);
    if (defined $extra) {
        ($alt) = $extra =~ m/\(([^\)]+)\)/;
        $extra =~ s/\([^\)]+\)//;
        my ($pct) = ($extra =~ m/(^|\s)(\d+)%(\s|$)/)[1];
        if (!$pct) {
            ($pctw, $pcth) = ($extra =~ m/(^|\s)(\d+)%x(\d+)%(\s|$)/)[1,2];
        } else {
            $pctw = $pcth = $pct;
        }
        if (!$pctw && !$pcth) {
            ($w,$h) = ($extra =~ m/(^|\s)(\d+|\*)x(\d+|\*)(\s|$)/)[1,2];
            $w = '' if $w eq '*';
            $h = '' if $h eq '*';
            if (!$w) {
                ($w) = ($extra =~ m/(^|[,\s])(\d+)w([\s,]|$)/)[1];
            }
            if (!$h) {
                ($h) = ($extra =~ m/(^|[,\s])(\d+)h([\s,]|$)/)[1];
            }
        }
    }
    $alt = '' unless defined $alt;
    if ($self->{flavor} !~ m/^xhtml2/) {
        $tag .= ' alt="' . $self->encode_html_basic($alt) . '"';
    }
    if ($w && $h) {
        if ($self->{flavor} !~ m/^xhtml2/) {
            $tag .= qq{ height="$h" width="$w"};
        } else {
            $style .= qq{;height:$h}.qq{px;width:$w}.q{px};
        }
    } else {
        my ($image_w, $image_h) = $self->image_size($src);
        if (($image_w && $image_h) && ($w || $h)) {
            # image size determined, but only width or height specified
            if ($w && !$h) {
                # width defined, scale down height proportionately
                $h = int($image_h * ($w / $image_w));
            } elsif ($h && !$w) {
                $w = int($image_w * ($h / $image_h));
            }
        } else {
            $w = $image_w;
            $h = $image_h;
        }
        if ($w && $h) {
            if ($pctw || $pcth) {
                $w = int($w * $pctw / 100);
                $h = int($h * $pcth / 100);
            }
            if ($self->{flavor} !~ m/^xhtml2/) {
                $tag .= qq{ height="$h" width="$w"};
            } else {
                $style .= qq{;height:$h}.qq{px;width:$w}.q{px};
            }
        }
    }
    my $attr = $self->format_classstyle($clsty, $class, $style);
    $tag .= qq{ $attr} if $attr;
    if ($self->{flavor} =~ m/^xhtml2/) {
        $tag .= '><p>' . $self->encode_html_basic($alt) . '</p></object>';
    } elsif ($self->{flavor} =~ m/^xhtml/) {
        $tag .= ' />';
    } else {
        $tag .= '>';
    }
    if (defined $link) {
        $link =~ s/^://;
        $link = $self->format_url(url => $link);
        $tag = '<a href="'.$link.'">'.$tag.'</a>';
    }

    return $pre.$tag.$post;
}

sub format_table {
    my $self = shift;
    my (%args) = @_;
    my $str = defined $args{text} ? $args{text} : '';

    my @lines = split /\n/, $str;
    my @rows;
    my $line_count = scalar(@lines);
    for (my $i = 0; $i < $line_count; $i++) {
       if ($lines[$i] !~ m/\|\s*$/) {
           if ($i + 1 < $line_count) {
               $lines[$i+1] = $lines[$i] . "\n" . $lines[$i+1] if $i+1 <= $#lines;
           } else {
               push @rows, $lines[$i];
           }
       } else {
           push @rows, $lines[$i];
       }
    }
    my ($tid, $tpadl, $tpadr, $tlang);
    my $tclass = '';
    my $tstyle = '';
    my $talign = '';
    if ($rows[0] =~ m/^table[^\.]/) {
        my $row = $rows[0];
        $row =~ s/^table//;
        my $params = 1;
        # process row parameters until none are left
        while ($params) {
            if ($row =~ m/^($tblalignre)/) {
                # found row alignment
                $talign .= $1;
                $row = substr($row, length($1)) if $1;
                redo if $1;
            }
            if ($row =~ m/^($clstypadre)/) {
                # found a class/id/style/padding indicator
                my $clsty = $1;
                $row = substr($row, length($clsty)) if $clsty;
                if ($clsty =~ m/{([^}]+)}/) {
                    $tstyle = $1;
                    $clsty =~ s/{([^}]+)}//;
                    redo if $tstyle;
                }
                if ($clsty =~ m/\(([A-Za-z0-9_\- ]+?)(?:#(.+?))?\)/ ||
                    $clsty =~ m/\(([A-Za-z0-9_\- ]+?)?(?:#(.+?))\)/) {
                    if ($1 || $2) {
                        $tclass = $1;
                        $tid = $2;
                        redo;
                    }
                }
                $tpadl = length($1) if $clsty =~ m/(\(+)/;
                $tpadr = length($1) if $clsty =~ m/(\)+)/;
                $tlang = $1 if $clsty =~ m/\[(.+?)\]/;
                redo if $clsty;
            }
            $params = 0;
        }
        $row =~ s/\.\s+//;
        $rows[0] = $row;
    }
    my $out = '';
    my @cols = split /\|/, $rows[0].' ';
    my (@colalign, @rowspans);
    foreach my $row (@rows) {
        my @cols = split /\|/, $row.' ';
        my $colcount = $#cols;
        pop @cols;
        my $colspan = 0;
        my $row_out = '';
        my ($rowclass, $rowid, $rowalign, $rowstyle, $rowheader);
        $cols[0] = '' if !defined $cols[0];
        if ($cols[0] =~ m/_/) {
            $cols[0] =~ s/_//g;
            $rowheader = 1;
        }
        if ($cols[0] =~ m/{([^}]+)}/) {
            $rowstyle = $1;
            $cols[0] =~ s/{[^}]+}//g;
        }
        if ($cols[0] =~ m/\(([^\#]+?)?(#(.+))?\)/) {
            $rowclass = $1;
            $rowid = $3;
            $cols[0] =~ s/\([^\)]+\)//g;
        }
        $rowalign = $1 if $cols[0] =~ m/($alignre)/;
        for (my $c = $colcount - 1; $c > 0; $c--) {
            if ($rowspans[$c]) {
                $rowspans[$c]--;
                next if $rowspans[$c] > 1;
            }
            my ($colclass, $colid, $header, $colparams, $colpadl, $colpadr, $collang);
            my $colstyle = '';
            my $colalign = $colalign[$c];
            my $col = pop @cols;
            $col ||= '';
            my $attrs = '';
            if ($col =~ m/^(((_|[\/\\]\d+|$alignre|$clstypadre)+)\. )/) {
                my $colparams = $2;
                $col = substr($col, length($1));
                my $params = 1;
                # keep processing column parameters until there
                # are none left...
                while ($params) {
                    if ($colparams =~ m/^(_|$alignre)/g) {
                        # found alignment or heading indicator
                        $attrs .= $1;
                        $colparams = substr($colparams, pos($colparams)) if $1;
                        redo if $1;
                    }
                    if ($colparams =~ m/^($clstypadre)/g) {
                        # found a class/id/style/padding marker
                        my $clsty = $1;
                        $colparams = substr($colparams, pos($colparams)) if $clsty;
                        if ($clsty =~ m/{([^}]+)}/) {
                            $colstyle = $1;
                            $clsty =~ s/{([^}]+)}//;
                        }
                        if ($clsty =~ m/\(([A-Za-z0-9_\- ]+?)(?:#(.+?))?\)/ ||
                            $clsty =~ m/\(([A-Za-z0-9_\- ]+?)?(?:#(.+?))\)/) {
                            if ($1 || $2) {
                                $colclass = $1;
                                $colid = $2;
                                if ($colclass) {
                                    $clsty =~ s/\([A-Za-z0-9_\- ]+?(#.*?)?\)//g;
                                } elsif ($colid) {
                                    $clsty =~ s/\(#.+?\)//g;
                                }
                            }
                        }
                        if ($clsty =~ m/(\(+)/) {
                            $colpadl = length($1);
                            $clsty =~ s/\(+//;
                        }
                        if ($clsty =~ m/(\)+)/) {
                            $colpadr = length($1);
                            $clsty =~ s/\)+//;
                        }
                        if ($clsty =~ m/\[(.+?)\]/) {
                            $collang = $1;
                            $clsty =~ s/\[.+?\]//;
                        }
                        redo if $clsty;
                    }
                    if ($colparams =~ m/^\\(\d+)/) {
                        $colspan = $1;
                        $colparams = substr($colparams, length($1)+1);
                        redo if $1;
                    }
                    if ($colparams =~ m/\/(\d+)/) {
                        $rowspans[$c] = $1 if $1;
                        $colparams = substr($colparams, length($1)+1);
                        redo if $1;
                    }
                    $params = 0;
                }
            }
            if (length($attrs)) {
                $header = 1 if $attrs =~ m/_/;
                $colalign = '' if $attrs =~ m/($alignre)/ && length($1);
                # determine column alignment
                if ($attrs =~ m/<>/) {
                    $colalign .= '<>';
                } elsif ($attrs =~ m/</) {
                    $colalign .= '<';
                } elsif ($attrs =~ m/=/) {
                    $colalign = '=';
                } elsif ($attrs =~ m/>/) {
                    $colalign = '>';
                }
                if ($attrs =~ m/\^/) {
                    $colalign .= '^';
                } elsif ($attrs =~ m/~/) {
                    $colalign .= '~';
                } elsif ($attrs =~ m/-/) {
                    $colalign .= '-';
                }
            }
            $header = 1 if $rowheader;
            $colalign[$c] = $colalign if $header;
            $col =~ s/^ +//; $col =~ s/ +$//;
            if (length($col)) {
                # create one cell tag
                my $rowspan = $rowspans[$c] || 0;
                my $col_out = '<' . ($header ? 'th' : 'td');
                if (defined $colalign) {
                    # horizontal, vertical alignment
                    my $halign = _halign($colalign);
                    $col_out .= qq{ align="$halign"} if $halign;
                    my $valign = _valign($colalign);
                    $col_out .= qq{ valign="$valign"} if $valign;
                }
                # apply css attributes, row, column spans
                $colstyle .= qq{;padding-left:${colpadl}em} if $colpadl;
                $colstyle .= qq{;padding-right:${colpadr}em} if $colpadr;
                $col_out .= qq{ class="$colclass"} if $colclass;
                $col_out .= qq{ id="$colid"} if $colid;
                $colstyle =~ s/^;// if $colstyle;
                $col_out .= qq{ style="$colstyle"} if $colstyle;
                $col_out .= qq{ lang="$collang"} if $collang;
                $col_out .= qq{ colspan="$colspan"} if $colspan > 1;
                $col_out .= qq{ rowspan="$rowspan"} if ($rowspan||0) > 1;
                $col_out .= '>';
                # if the content of this cell has newlines OR matches
                # our paragraph block signature, process it as a full-blown
                # textile document
                if (($col =~ m/\n\n/) ||
                    ($col =~ m/^(?:$halignre|$clstypadre*)*
                                [\*\#]
                                (?:$clstypadre*|$halignre)*\ /x)) {
                    $col_out .= $self->textile($col);
                } else {
                    $col_out .= $self->format_paragraph(text => $col);
                }
                $col_out .= '</' . ($header ? 'th' : 'td') . '>';
                $row_out = $col_out . $row_out;
                $colspan = 0 if $colspan;
            } else {
                $colspan = 1 if $colspan == 0;
                $colspan++;
            }
        }
        if ($colspan > 1) {
            # handle the spanned column if we came up short
            $colspan--;
            $row_out = q{<td}
                     . ($colspan>1 ? qq{ colspan="$colspan"} : '')
                     . qq{></td>$row_out};
        }

        # build one table row
        $out .= q{<tr};
        if ($rowalign) {
            my $valign = _valign($rowalign);
            $out .= qq{ valign="$valign"} if $valign;
        }
        $out .= qq{ class="$rowclass"} if $rowclass;
        $out .= qq{ id="$rowid"} if $rowid;
        $out .= qq{ style="$rowstyle"} if $rowstyle;
        $out .= qq{>$row_out</tr>};
    }

    # now, form the table tag itself
    my $table = '';
    $table .= q{<table};
    if ($talign) {
        if ($self->{css_mode}) {
            # horizontal alignment
            my $alignment = _halign($talign);
            if ($talign eq '=') {
                $tstyle .= ';margin-left:auto;margin-right:auto';
            } else {
                $tstyle .= ';float:'.$alignment if $alignment;
            }
            $tclass .= ' '.$alignment if $alignment;
        } else {
            my $alignment = _halign($talign);
            $table .= qq{ align="$alignment"} if $alignment;
        }
    }
    $tstyle .= qq{;padding-left:${tpadl}em} if $tpadl;
    $tstyle .= qq{;padding-right:${tpadr}em} if $tpadr;
    $tclass =~ s/^ // if $tclass;
    $table .= qq{ class="$tclass"} if $tclass;
    $table .= qq{ id="$tid"} if $tid;
    $tstyle =~ s/^;// if $tstyle;
    $table .= qq{ style="$tstyle"} if $tstyle;
    $table .= qq{ lang="$tlang"} if $tlang;
    $table .= q{ cellspacing="0"} if $tclass || $tid || $tstyle;
    $table .= qq{>$out</table>};

    if ($table =~ m{<tr></tr>}) {
        # exception -- something isn't right so return fail case
        return undef;
    }

    return $table;
}

sub apply_filters {
    my $self = shift;
    my (%args) = @_;
    my $text = $args{text};
    return '' unless defined $text;
    my $list = $args{filters};
    my $filters = $self->{filters};
    return $text unless (ref $filters) eq 'HASH';

    my $param = $self->filter_param;
    foreach my $filter (@{$list}) {
        next unless $filters->{$filter};
        if ((ref $filters->{$filter}) eq 'CODE') {
            $text = $filters->{$filter}->($text, $param);
        }
    }
    return $text;
}

# minor utility / formatting routines

{
    my $Have_Entities = eval 'use HTML::Entities; 1' ? 1 : 0;

    sub encode_html {
        my $self = shift;
        my($html, $can_double_encode) = @_;
        return '' unless defined $html;
        return $html if $self->{disable_encode_entities};
        if ($Have_Entities && $self->{char_encoding}) {
            $html = HTML::Entities::encode_entities($html);
        } else {
            $html = $self->encode_html_basic($html, $can_double_encode);
        }

        return $html;
    }

    sub decode_html {
        my $self = shift;
        my ($html) = @_;
        $html =~ s{&quot;}{"}g;
        $html =~ s{&amp;}{&}g;
        $html =~ s{&lt;}{<}g;
        $html =~ s{&gt;}{>}g;

        return $html;
    }

    sub encode_html_basic {
        my $self = shift;
        my($html, $can_double_encode) = @_;
        return '' unless defined $html;
        return $html unless $html =~ m/[^\w\s]/;
        if ($can_double_encode) {
            $html =~ s{&}{&amp;}g;
        } else {
            ## Encode any & not followed by something that looks like
            ## an entity, numeric or otherwise.
            $html =~ s/&(?!#?[xX]?(?:[0-9a-fA-F]+|\w{1,8});)/&amp;/g;
        }
        $html =~ s{"}{&quot;}g;
        $html =~ s{<}{&lt;}g;
        $html =~ s{>}{&gt;}g;

        return $html;
    }

}

{
    my $Have_ImageSize = eval 'use Image::Size; 1' ? 1 : 0;

    sub image_size {
        my $self = shift;
        my ($file) = @_;
        if ($Have_ImageSize) {
            if (-f $file) {
                return Image::Size::imgsize($file);
            } else {
                if (my $docroot = $self->docroot) {
                    require File::Spec;
                    my $fullpath = File::Spec->catfile($docroot, $file);
                    if (-f $fullpath) {
                        return Image::Size::imgsize($fullpath);
                    }
                }
            }
        }
        return undef;
    }
}

sub encode_url {
    my $self = shift;
    my($str) = @_;
    $str =~ s!([^A-Za-z0-9_\.\-\+\&=\%;])!
         ord($1) > 255 ? '%u' . (uc sprintf("%04x", ord($1)))
                       : '%'  . (uc sprintf("%02x", ord($1)))!egx;
    return $str;
}

sub mail_encode {
    my $self = shift;
    my ($addr) = @_;
    # granted, this is simple, but it gives off warm fuzzies
    $addr =~ s!([^\$])!
         ord($1) > 255 ? '%u' . (uc sprintf("%04x", ord($1)))
                       : '%'  . (uc sprintf("%02x", ord($1)))!egx;
    return $addr;
}

sub process_quotes {
    # stub routine for now. subclass and implement.
    my $self = shift;
    my ($str) = @_;
    return $str;
}

# a default set of macros for the {...} macro syntax
# just a handy way to write a lot of the international characters
# and some commonly used symbols

sub default_macros {
    my $self = shift;
    # <, >, " must be html entities in the macro text since
    # those values are escaped by the time they are processed
    # for macros.
    return {
        'c|'       => '&#162;', # CENT SIGN
        '|c'       => '&#162;', # CENT SIGN
        'L-'       => '&#163;', # POUND SIGN
        '-L'       => '&#163;', # POUND SIGN
        'Y='       => '&#165;', # YEN SIGN
        '=Y'       => '&#165;', # YEN SIGN
        '(c)'      => '&#169;', # COPYRIGHT SIGN
        '&lt;&lt;' => '&#171;', # LEFT-POINTING DOUBLE ANGLE QUOTATION
        '(r)'      => '&#174;', # REGISTERED SIGN
        '+_'       => '&#177;', # PLUS-MINUS SIGN
        '_+'       => '&#177;', # PLUS-MINUS SIGN
        '&gt;&gt;' => '&#187;', # RIGHT-POINTING DOUBLE ANGLE QUOTATION
        '1/4'      => '&#188;', # VULGAR FRACTION ONE QUARTER
        '1/2'      => '&#189;', # VULGAR FRACTION ONE HALF
        '3/4'      => '&#190;', # VULGAR FRACTION THREE QUARTERS
        'A`'       => '&#192;', # LATIN CAPITAL LETTER A WITH GRAVE
        '`A'       => '&#192;', # LATIN CAPITAL LETTER A WITH GRAVE
        'A\''      => '&#193;', # LATIN CAPITAL LETTER A WITH ACUTE
        '\'A'      => '&#193;', # LATIN CAPITAL LETTER A WITH ACUTE
        'A^'       => '&#194;', # LATIN CAPITAL LETTER A WITH CIRCUMFLEX
        '^A'       => '&#194;', # LATIN CAPITAL LETTER A WITH CIRCUMFLEX
        'A~'       => '&#195;', # LATIN CAPITAL LETTER A WITH TILDE
        '~A'       => '&#195;', # LATIN CAPITAL LETTER A WITH TILDE
        'A"'       => '&#196;', # LATIN CAPITAL LETTER A WITH DIAERESIS
        '"A'       => '&#196;', # LATIN CAPITAL LETTER A WITH DIAERESIS
        'Ao'       => '&#197;', # LATIN CAPITAL LETTER A WITH RING ABOVE
        'oA'       => '&#197;', # LATIN CAPITAL LETTER A WITH RING ABOVE
        'AE'       => '&#198;', # LATIN CAPITAL LETTER AE
        'C,'       => '&#199;', # LATIN CAPITAL LETTER C WITH CEDILLA
        ',C'       => '&#199;', # LATIN CAPITAL LETTER C WITH CEDILLA
        'E`'       => '&#200;', # LATIN CAPITAL LETTER E WITH GRAVE
        '`E'       => '&#200;', # LATIN CAPITAL LETTER E WITH GRAVE
        'E\''      => '&#201;', # LATIN CAPITAL LETTER E WITH ACUTE
        '\'E'      => '&#201;', # LATIN CAPITAL LETTER E WITH ACUTE
        'E^'       => '&#202;', # LATIN CAPITAL LETTER E WITH CIRCUMFLEX
        '^E'       => '&#202;', # LATIN CAPITAL LETTER E WITH CIRCUMFLEX
        'E"'       => '&#203;', # LATIN CAPITAL LETTER E WITH DIAERESIS
        '"E'       => '&#203;', # LATIN CAPITAL LETTER E WITH DIAERESIS
        'I`'       => '&#204;', # LATIN CAPITAL LETTER I WITH GRAVE
        '`I'       => '&#204;', # LATIN CAPITAL LETTER I WITH GRAVE
        'I\''      => '&#205;', # LATIN CAPITAL LETTER I WITH ACUTE
        '\'I'      => '&#205;', # LATIN CAPITAL LETTER I WITH ACUTE
        'I^'       => '&#206;', # LATIN CAPITAL LETTER I WITH CIRCUMFLEX
        '^I'       => '&#206;', # LATIN CAPITAL LETTER I WITH CIRCUMFLEX
        'I"'       => '&#207;', # LATIN CAPITAL LETTER I WITH DIAERESIS
        '"I'       => '&#207;', # LATIN CAPITAL LETTER I WITH DIAERESIS
        'D-'       => '&#208;', # LATIN CAPITAL LETTER ETH
        '-D'       => '&#208;', # LATIN CAPITAL LETTER ETH
        'N~'       => '&#209;', # LATIN CAPITAL LETTER N WITH TILDE
        '~N'       => '&#209;', # LATIN CAPITAL LETTER N WITH TILDE
        'O`'       => '&#210;', # LATIN CAPITAL LETTER O WITH GRAVE
        '`O'       => '&#210;', # LATIN CAPITAL LETTER O WITH GRAVE
        'O\''      => '&#211;', # LATIN CAPITAL LETTER O WITH ACUTE
        '\'O'      => '&#211;', # LATIN CAPITAL LETTER O WITH ACUTE
        'O^'       => '&#212;', # LATIN CAPITAL LETTER O WITH CIRCUMFLEX
        '^O'       => '&#212;', # LATIN CAPITAL LETTER O WITH CIRCUMFLEX
        'O~'       => '&#213;', # LATIN CAPITAL LETTER O WITH TILDE
        '~O'       => '&#213;', # LATIN CAPITAL LETTER O WITH TILDE
        'O"'       => '&#214;', # LATIN CAPITAL LETTER O WITH DIAERESIS
        '"O'       => '&#214;', # LATIN CAPITAL LETTER O WITH DIAERESIS
        'O/'       => '&#216;', # LATIN CAPITAL LETTER O WITH STROKE
        '/O'       => '&#216;', # LATIN CAPITAL LETTER O WITH STROKE
        'U`'       => '&#217;', # LATIN CAPITAL LETTER U WITH GRAVE
        '`U'       => '&#217;', # LATIN CAPITAL LETTER U WITH GRAVE
        'U\''      => '&#218;', # LATIN CAPITAL LETTER U WITH ACUTE
        '\'U'      => '&#218;', # LATIN CAPITAL LETTER U WITH ACUTE
        'U^'       => '&#219;', # LATIN CAPITAL LETTER U WITH CIRCUMFLEX
        '^U'       => '&#219;', # LATIN CAPITAL LETTER U WITH CIRCUMFLEX
        'U"'       => '&#220;', # LATIN CAPITAL LETTER U WITH DIAERESIS
        '"U'       => '&#220;', # LATIN CAPITAL LETTER U WITH DIAERESIS
        'Y\''      => '&#221;', # LATIN CAPITAL LETTER Y WITH ACUTE
        '\'Y'      => '&#221;', # LATIN CAPITAL LETTER Y WITH ACUTE
        'a`'       => '&#224;', # LATIN SMALL LETTER A WITH GRAVE
        '`a'       => '&#224;', # LATIN SMALL LETTER A WITH GRAVE
        'a\''      => '&#225;', # LATIN SMALL LETTER A WITH ACUTE
        '\'a'      => '&#225;', # LATIN SMALL LETTER A WITH ACUTE
        'a^'       => '&#226;', # LATIN SMALL LETTER A WITH CIRCUMFLEX
        '^a'       => '&#226;', # LATIN SMALL LETTER A WITH CIRCUMFLEX
        'a~'       => '&#227;', # LATIN SMALL LETTER A WITH TILDE
        '~a'       => '&#227;', # LATIN SMALL LETTER A WITH TILDE
        'a"'       => '&#228;', # LATIN SMALL LETTER A WITH DIAERESIS
        '"a'       => '&#228;', # LATIN SMALL LETTER A WITH DIAERESIS
        'ao'       => '&#229;', # LATIN SMALL LETTER A WITH RING ABOVE
        'oa'       => '&#229;', # LATIN SMALL LETTER A WITH RING ABOVE
        'ae'       => '&#230;', # LATIN SMALL LETTER AE
        'c,'       => '&#231;', # LATIN SMALL LETTER C WITH CEDILLA
        ',c'       => '&#231;', # LATIN SMALL LETTER C WITH CEDILLA
        'e`'       => '&#232;', # LATIN SMALL LETTER E WITH GRAVE
        '`e'       => '&#232;', # LATIN SMALL LETTER E WITH GRAVE
        'e\''      => '&#233;', # LATIN SMALL LETTER E WITH ACUTE
        '\'e'      => '&#233;', # LATIN SMALL LETTER E WITH ACUTE
        'e^'       => '&#234;', # LATIN SMALL LETTER E WITH CIRCUMFLEX
        '^e'       => '&#234;', # LATIN SMALL LETTER E WITH CIRCUMFLEX
        'e"'       => '&#235;', # LATIN SMALL LETTER E WITH DIAERESIS
        '"e'       => '&#235;', # LATIN SMALL LETTER E WITH DIAERESIS
        'i`'       => '&#236;', # LATIN SMALL LETTER I WITH GRAVE
        '`i'       => '&#236;', # LATIN SMALL LETTER I WITH GRAVE
        'i\''      => '&#237;', # LATIN SMALL LETTER I WITH ACUTE
        '\'i'      => '&#237;', # LATIN SMALL LETTER I WITH ACUTE
        'i^'       => '&#238;', # LATIN SMALL LETTER I WITH CIRCUMFLEX
        '^i'       => '&#238;', # LATIN SMALL LETTER I WITH CIRCUMFLEX
        'i"'       => '&#239;', # LATIN SMALL LETTER I WITH DIAERESIS
        '"i'       => '&#239;', # LATIN SMALL LETTER I WITH DIAERESIS
        'n~'       => '&#241;', # LATIN SMALL LETTER N WITH TILDE
        '~n'       => '&#241;', # LATIN SMALL LETTER N WITH TILDE
        'o`'       => '&#242;', # LATIN SMALL LETTER O WITH GRAVE
        '`o'       => '&#242;', # LATIN SMALL LETTER O WITH GRAVE
        'o\''      => '&#243;', # LATIN SMALL LETTER O WITH ACUTE
        '\'o'      => '&#243;', # LATIN SMALL LETTER O WITH ACUTE
        'o^'       => '&#244;', # LATIN SMALL LETTER O WITH CIRCUMFLEX
        '^o'       => '&#244;', # LATIN SMALL LETTER O WITH CIRCUMFLEX
        'o~'       => '&#245;', # LATIN SMALL LETTER O WITH TILDE
        '~o'       => '&#245;', # LATIN SMALL LETTER O WITH TILDE
        'o"'       => '&#246;', # LATIN SMALL LETTER O WITH DIAERESIS
        '"o'       => '&#246;', # LATIN SMALL LETTER O WITH DIAERESIS
        ':-'       => '&#247;', # DIVISION SIGN
        '-:'       => '&#247;', # DIVISION SIGN
        'o/'       => '&#248;', # LATIN SMALL LETTER O WITH STROKE
        '/o'       => '&#248;', # LATIN SMALL LETTER O WITH STROKE
        'u`'       => '&#249;', # LATIN SMALL LETTER U WITH GRAVE
        '`u'       => '&#249;', # LATIN SMALL LETTER U WITH GRAVE
        'u\''      => '&#250;', # LATIN SMALL LETTER U WITH ACUTE
        '\'u'      => '&#250;', # LATIN SMALL LETTER U WITH ACUTE
        'u^'       => '&#251;', # LATIN SMALL LETTER U WITH CIRCUMFLEX
        '^u'       => '&#251;', # LATIN SMALL LETTER U WITH CIRCUMFLEX
        'u"'       => '&#252;', # LATIN SMALL LETTER U WITH DIAERESIS
        '"u'       => '&#252;', # LATIN SMALL LETTER U WITH DIAERESIS
        'y\''      => '&#253;', # LATIN SMALL LETTER Y WITH ACUTE
        '\'y'      => '&#253;', # LATIN SMALL LETTER Y WITH ACUTE
        'y"'       => '&#255', # LATIN SMALL LETTER Y WITH DIAERESIS
        '"y'       => '&#255', # LATIN SMALL LETTER Y WITH DIAERESIS
        'OE'       => '&#338;', # LATIN CAPITAL LIGATURE OE
        'oe'       => '&#339;', # LATIN SMALL LIGATURE OE
        '*'        => '&#2022;', # BULLET
        'Fr'       => '&#8355;', # FRENCH FRANC SIGN
        'L='       => '&#8356;', # LIRA SIGN
        '=L'       => '&#8356;', # LIRA SIGN
        'Rs'       => '&#8360;', # RUPEE SIGN
        'C='       => '&#8364;', # EURO SIGN
        '=C'       => '&#8364;', # EURO SIGN
        'tm'       => '&#8482;', # TRADE MARK SIGN
        '&lt;-'    => '&#8592;', # LEFTWARDS ARROW
        '-&gt;'    => '&#8594;', # RIGHTWARDS ARROW
        '&lt;='    => '&#8656;', # LEFTWARDS DOUBLE ARROW
        '=&gt;'    => '&#8658;', # RIGHTWARDS DOUBLE ARROW
        '=/'       => '&#8800;', # NOT EQUAL TO
        '/='       => '&#8800;', # NOT EQUAL TO
        '&lt;_'    => '&#8804;', # LESS-THAN OR EQUAL TO
        '_&lt;'    => '&#8804;', # LESS-THAN OR EQUAL TO
        '&gt;_'    => '&#8805;', # GREATER-THAN OR EQUAL TO
        '_&gt;'    => '&#8805;', # GREATER-THAN OR EQUAL TO
        ':('       => '&#9785;', # WHITE FROWNING FACE
        ':)'       => '&#9786;', # WHITE SMILING FACE
        'spade'    => '&#9824;', # BLACK SPADE SUIT
        'club'     => '&#9827;', # BLACK CLUB SUIT
        'heart'    => '&#9829;', # BLACK HEART SUIT
        'diamond'  => '&#9830;', # BLACK DIAMOND SUIT
    };
}

# "private", internal routines

sub _css_defaults {
    my $self = shift;
    my %css_defaults = (
       class_align_right => 'right',
       class_align_left => 'left',
       class_align_center => 'center',
       class_align_top => 'top',
       class_align_bottom => 'bottom',
       class_align_middle => 'middle',
       class_align_justify => 'justify',
       class_caps => 'caps',
       class_footnote => 'footnote',
       id_footnote_prefix => 'fn',
    );
    return $self->css(\%css_defaults);
}

sub _halign {
    my ($align) = @_;

    if ($align =~ m/<>/) {
        return 'justify';
    } elsif ($align =~ m/</) {
        return 'left';
    } elsif ($align =~ m/>/) {
        return 'right';
    } elsif ($align =~ m/=/) {
        return 'center';
    }
    return '';
}

sub _valign {
    my ($align) = @_;

    if ($align =~ m/\^/) {
        return 'top';
    } elsif ($align =~ m/~/) {
        return 'bottom';
    } elsif ($align =~ m/-/) {
        return 'middle';
    }
    return '';
}

sub _imgalign {
    my ($align) = @_;

    $align =~ s/(<>|=)//g;
    return _valign($align) || _halign($align);
}

sub _strip_borders {
    my ($pre, $post) = @_;
    if (${$post} && ${$pre} && ((my $open = substr(${$pre}, 0, 1)) =~ m/[{[]/)) {
        my $close = substr(${$post}, 0, 1);
        if ((($open eq '{') && ($close eq '}')) ||
            (($open eq '[') && ($close eq ']'))) {
            ${$pre} = substr(${$pre}, 1);
            ${$post} = substr(${$post}, 1);
        } else {
            $close = substr(${$post}, -1, 1) if $close !~ m/[}\]]/;
            if ((($open eq '{') && ($close eq '}')) ||
                (($open eq '[') && ($close eq ']'))) {
                ${$pre} = substr(${$pre}, 1);
                ${$post} = substr(${$post}, 0, length(${$post}) - 1);
            }
        }
    }
    return;
}

sub _repl {
    push @{$_[0]}, $_[1];

    return '<textile#'.(scalar(@{$_[0]})).'>';
}

sub _tokenize {
    my $str = shift;
    my $pos = 0;
    my $len = length $str;
    my @tokens;

    my $depth = 6;
    my $nested_tags = join('|', ('(?:</?[A-Za-z0-9:]+ \s? (?:[^<>]') x $depth)
        . (')*>)' x $depth);
    my $match = qr/(?s: <! ( -- .*? -- \s* )+ > )|  # comment
                   (?s: <\? .*? \?> )|              # processing instruction
                   (?s: <\% .*? \%> )|              # ASP-like
                   (?:$nested_tags)|
                   (?:$codere)/x;                   # nested tags

    while ($str =~ m/($match)/g) {
        my $whole_tag = $1;
        my $sec_start = pos $str;
        my $tag_start = $sec_start - length $whole_tag;
        if ($pos < $tag_start) {
            push @tokens, ['text', substr($str, $pos, $tag_start - $pos)];
        }
        if ($whole_tag =~ m/^[[{]?\@/) {
            push @tokens, ['text', $whole_tag];
        } else {
            # this clever hack allows us to preserve \n within tags.
            # this is restored at the end of the format_paragraph method
            #$whole_tag =~ s/\n/\r/g;
            $whole_tag =~ s/\n/\001/g;
            push @tokens, ['tag', $whole_tag];
        }
        $pos = pos $str;
    }
    push @tokens, ['text', substr($str, $pos, $len - $pos)] if $pos < $len;

    return \@tokens;
}

1;
__END__

=head1 NAME

Text::Textile - A humane web text generator.

=head1 SYNOPSIS

    use Text::Textile qw(textile);
    my $text = <<EOT;
    h1. Heading

    A _simple_ demonstration of Textile markup.

    * One
    * Two
    * Three

    "More information":http://www.textism.com/tools/textile is available.
    EOT

    # procedural usage
    my $html = textile($text);
    print $html;

    # OOP usage
    my $textile = new Text::Textile;
    $html = $textile->process($text);
    print $html;

=head1 ABSTRACT

Text::Textile is a Perl-based implementation of Dean Allen's Textile
syntax. Textile is shorthand for doing common formatting tasks.

=head1 METHODS

=head2 new( [%options] )

Instantiates a new Text::Textile object. Optional options
can be passed to initialize the object. Attributes for the
options key are the same as the get/set method names
documented here.

=head2 set( $attribute, $value )

Used to set Textile attributes. Attribute names are the same
as the get/set method names documented here.

=head2 get( $attribute )

Used to get Textile attributes. Attribute names are the same
as the get/set method names documented here.

=head2 disable_html( [$disable] )

Gets or sets the "disable html" control, which allows you to
prevent HTML tags from being used within the text processed.
Any HTML tags encountered will be removed if disable html is
enabled. Default behavior is to allow HTML.

=head2 flavor( [$flavor] )

Assigns the HTML flavor of output from Text::Textile. Currently
these are the valid choices: html, xhtml (behaves like "xhtml1"),
xhtml1, xhtml2. Default flavor is "xhtml1".

Note that the xhtml2 flavor support is experimental and incomplete
(and will remain that way until the XHTML 2.0 draft becomes a
proper recommendation).

=head2 css( [$css] )

Gets or sets the CSS support for Textile. If CSS is enabled,
Textile will emit CSS rules. You may pass a 1 or 0 to enable
or disable CSS behavior altogether. If you pass a hashref,
you may assign the CSS class names that are used by
Text::Textile. The following key names for such a hash are
recognized:

=over

=item class_align_right

defaults to "right"

=item class_align_left

defaults to "left"

=item class_align_center

defaults to "center"

=item class_align_top

defaults to "top"

=item class_align_bottom

defaults to "bottom"

=item class_align_middle

defaults to "middle"

=item class_align_justify

defaults to "justify"

=item class_caps

defaults to "caps"

=item class_footnote

defaults to "footnote"

=item id_footnote_prefix

defaults to "fn"

=back

=head2 charset( [$charset] )

Gets or sets the character set targetted for publication.
At this time, Text::Textile only changes its behavior
if the "utf-8" character set is assigned.

Specifically, if utf-8 is requested, any special characters
created by Textile will be output as native utf-8 characters
rather than HTML entities.

=head2 docroot( [$path] )

Gets or sets the physical file path to root of document files.
This path is utilized when images are referenced and size
calculations are needed (the Image::Size module is used to read
the image dimensions).

=head2 trim_spaces( [$trim] )

Gets or sets the "trim spaces" control flag. If enabled, this
will clear any lines that have only spaces on them (the newline
itself will remain).

=head2 preserve_spaces( [$preserve] )

Gets or sets the "preserve spaces" control flag. If enabled, this
will replace any double spaces within the paragraph data with the
&#8195; HTML entity (wide space). The default is 0. Spaces will
pass through to the browser unchanged and render as a single space.
Note that this setting has no effect on spaces within C<< <pre> >>,
C<< <code> >> or C<< <script> >>.

=head2 filter_param( [$data] )

Gets or sets a parameter that is passed to filters.

=head2 filters( [\%filters] )

Gets or sets a list of filters to make available for
Text::Textile to use. Returns a hash reference of the currently
assigned filters.

=head2 char_encoding( [$encode] )

Gets or sets the character encoding logical flag. If character
encoding is enabled, the HTML::Entities package is used to
encode special characters. If character encoding is disabled,
only C<< < >>, C<< > >>, C<"> and C<&> are encoded to HTML entities.

=head2 disable_encode_entities( $boolean )

Gets or sets the disable encode entities logical flag. If this
value is set to true no entities are encoded at all. This
also supersedes the "char_encoding" flag.

=head2 handle_quotes( [$handle] )

Gets or sets the "smart quoting" control flag. Returns the
current setting.

=head2 process( $str )

Alternative method for invoking the textile method.

=head2 textile( $str )

Can be called either procedurally or as a method. Transforms
I<$str> using Textile markup rules.

=head2 format_paragraph( [$args] )

Processes a single paragraph. The following attributes are
allowed:

=over

=item text

The text to be processed.

=back

=head2 format_inline( [%args] )

Processes an inline string (plaintext) for Textile syntax.
The following attributes are allowed:

=over

=item text

The text to be processed.

=back

=head2 format_macro( %args )

Responsible for processing a particular macro. Arguments passed
include:

=over

=item pre

open brace character

=item post

close brace character

=item macro

the macro to be executed

=back

The return value from this method would be the replacement
text for the macro given. If the macro is not defined, it will
return pre + macro + post, thereby preserving the original
macro string.

=head2 format_cite( %args )

Processes text for a citation tag. The following attributes
are allowed:

=over

=item pre

Any text that comes before the citation.

=item text

The text that is being cited.

=item cite

The URL of the citation.

=item post

Any text that follows the citation.

=back

=head2 format_code( %args )

Processes '@...@' type blocks (code snippets). The following
attributes are allowed:

=over

=item text

The text of the code itself.

=item lang

The language (programming language) for the code.

=back

=head2 format_classstyle( $clsty, $class, $style )

Returns a string of tag attributes to accomodate the class,
style and symbols present in $clsty.

I<$clsty> is checked for:

=over

=item C<{...}>

style rules. If present, they are appended to $style.

=item C<(...#...)>

class and/or ID name declaration

=item C<(> (one or more)

pad left characters

=item C<)> (one or more)

pad right characters

=item C<[ll]>

language declaration

=back

The attribute string returned will contain any combination
of class, id, style and/or lang attributes.

=head2 format_tag( %args )

Constructs an HTML tag. Accepted arguments:

=over

=item tag

the tag to produce

=item text

the text to output inside the tag

=item pre

text to produce before the tag

=item post

text to produce following the tag

=item clsty

class and/or style attributes that should be assigned to the tag.

=back

=head2 format_list( %args )

Takes a Textile formatted list (numeric or bulleted) and
returns the markup for it. Text that is passed in requires
substantial parsing, so the format_list method is a little
involved. But it should always produce a proper ordered
or unordered list. If it cannot (due to misbalanced input),
it will return the original text. Arguments accepted:

=over

=item text

The text to be processed.

=back

=head2 format_block( %args )

Processes "==xxxxx==" type blocks for filters. A filter
would follow the open "==" sequence and is specified within
pipe characters, like so:

    ==|filter|text to be filtered==

You may specify multiple filters in the filter portion of
the string. Simply comma delimit the filters you desire
to execute. Filters are defined using the filters method.

=head2 format_link( %args )

Takes the Textile link attributes and transforms them into
a hyperlink.

=head2 format_url( %args )

Takes the given $url and transforms it appropriately.

=head2 format_span( %args )

=head2 format_image( %args )

Returns markup for the given image. $src is the location of
the image, $extra contains the optional height/width and/or
alt text. $url is an optional hyperlink for the image. $class
holds the optional CSS class attribute.

Arguments you may pass:

=over

=item src

The "src" (URL) for the image. This may be a local path,
ideally starting with a "/". Images can be located within
the file system if the docroot method is used to specify
where the docroot resides. If the image can be found, the
image_size method is used to determine the dimensions of
the image.

=item extra

Additional parameters for the image. This would include
alt text, height/width specification or scaling instructions.

=item align

Alignment attribute.

=item pre

Text to produce prior to the tag.

=item post

Text to produce following the tag.

=item link

Optional URL to connect with the image tag.

=item clsty

Class and/or style attributes.

=back

=head2 format_table( %args )

Takes a Wiki-ish string of data and transforms it into a full
table.

=head2 apply_filters( %args )

The following attributes are allowed:

=over

=item text

The text to be processed.

=item filters

An array reference of filter names to run for the given text.

=back

=head2 encode_html( $html, $can_double_encode )

Encodes input $html string, escaping characters as needed
to HTML entities. This relies on the HTML::Entities package
for full effect. If unavailable, encode_html_basic is used
as a fallback technique. If the "char_encoding" flag is
set to false, encode_html_basic is used exclusively.

=head2 decode_html( $html )

Decodes HTML entities in $html to their natural character
equivelants.

=head2 encode_html_basic( $html, $can_double_encode )

Encodes the input $html string for the following characters:
E<lt>, E<gt>, & and ". If $can_double_encode is true, all
ampersand characters are escaped even if they already were.
If $can_double_encode is false, ampersands are only escaped
when they aren't part of a HTML entity already.

=head2 image_size( $file )

Returns the size for the image identified in $file. This
method relies upon the Image::Size Perl package. If unavailable,
image_size will return undef. Otherwise, the expected return
value is a list of the width and height (in that order), in
pixels.

=head2 encode_url( $str )

Encodes the query portion of a URL, escaping characters
as necessary.

=head2 mail_encode( $email )

Encodes the email address in I<$email> for "mailto:" links.

=head2 process_quotes( $str )

Processes string, formatting plain quotes into curly quotes.

=head2 default_macros

Returns a hashref of macros that are assigned to be processed by
default within the format_inline method.

=head2 _halign( $alignment )

Returns the alignment keyword depending on the symbol passed.

=over

=item C<E<lt>E<gt>>

becomes "justify"

=item C<E<lt>>

becomes "left"

=item C<E<gt>>

becomes "right"

=item C<=>

becomes "center"

=back

=head2 _valign( $alignment )

Returns the alignment keyword depending on the symbol passed.

=over

=item C<^>

becomes "top"

=item C<~>

becomes "bottom"

=item C<->

becomes "middle"

=back

=head2 _imgalign( $alignment )

Returns the alignment keyword depending on the symbol passed.
The following alignment symbols are recognized, and given
preference in the order listed:

=over

=item C<^>

becomes "top"

=item C<~>

becomes "bottom"

=item C<->

becomes "middle"

=item C<E<lt>>

becomes "left"

=item C<E<gt>>

becomes "right"

=back

=head2 _repl( \@arr, $str )

An internal routine that takes a string and appends it to an array.
It returns a marker that is used later to restore the preserved
string.

=head2 _tokenize( $str )

An internal routine responsible for breaking up a string into
individual tag and plaintext elements.

=head2 _css_defaults

Sets the default CSS names for CSS controlled markup. This
is an internal function that should not be called directly.

=head2 _strip_borders( $pre, $post )

This utility routine will take "border" characters off of
the given $pre and $post strings if they match one of these
conditions:

    $pre starts with "[", $post ends with "]"
    $pre starts with "{", $post ends with "}"

If neither condition is met, then the $pre and $post
values are left untouched.

=head1 SYNTAX

Text::Textile processes text in units of blocks and lines.
A block might also be considered a paragraph, since blocks
are separated from one another by a blank line. Blocks
can begin with a signature that helps identify the rest
of the block content. Block signatures include:

=over

=item p

A paragraph block. This is the default signature if no
signature is explicitly given. Paragraphs are formatted
with all the inline rules (see inline formatting) and
each line receives the appropriate markup rules for
the flavor of HTML in use. For example, newlines for XHTML
content receive a C<< <br /> >> tag at the end of the line
(with the exception of the last line in the paragraph).
Paragraph blocks are enclosed in a C<< <p> >> tag.

=item pre

A pre-formatted block of text. Textile will not add any
HTML tags for individual lines. Whitespace is also preserved.

Note that within a "pre" block, E<lt> and E<gt> are
translated into HTML entities automatically.

=item bc

A "bc" signature is short for "block code", which implies
a preformatted section like the "pre" block, but it also
gets a C<< <code> >> tag (or for XHTML 2, a C<< <blockcode> >>
tag is used instead).

Note that within a "bc" block, E<lt> and E<gt> are
translated into HTML entities automatically.

=item table

For composing HTML tables. See the "TABLES" section for more
information.

=item bq

A "bq" signature is short for "block quote". Paragraph text
formatting is applied to these blocks and they are enclosed
in a E<lt>blockquoteE<gt> tag as well as E<lt>pE<gt> tags
within.

=item h1, h2, h3, h4, h5, h6

Headline signatures that produce C<< <h1> >>, etc. tags.
You can adjust the relative output of these using the
head_offset attribute.

=item clear

A "clear" signature is simply used to indicate that the next
block should emit a CSS style attribute that clears any
floating elements. The default behavior is to clear "both",
but you can use the left (E<lt>) or right (E<gt>) alignment
characters to indicate which side to clear.

=item dl

A "dl" signature is short for "definition list". See the
"LISTS" section for more information.

=item fn

A "fn" signature is short for "footnote". You add a number
following the "fn" keyword to number the footnote. Footnotes
are output as paragraph tags but are given a special CSS
class name which can be used to style them as you see fit.

=back

All signatures should end with a period and be followed
with a space. Inbetween the signature and the period, you
may use several parameters to further customize the block.
These include:

=over

=item C<{style rule}>

A CSS style rule. Style rules can span multiple lines.

=item C<[ll]>

A language identifier (for a "lang" attribute).

=item C<(class)> or C<(#id)> or C<(class#id)>

For CSS class and id attributes.

=item C<E<gt>>, C<E<lt>>, C<=>, C<E<lt>E<gt>>

Modifier characters for alignment. Right-justification, left-justification,
centered, and full-justification.

=item C<(> (one or more)

Adds padding on the left. 1em per "(" character is applied.
When combined with the align-left or align-right modifier,
it makes the block float.

=item C<)> (one or more)

Adds padding on the right. 1em per ")" character is applied.
When combined with the align-left or align-right modifier,
it makes the block float.

=item C<|filter|> or C<|filter|filter|filter|>

A filter may be invoked to further format the text for this
signature. If one or more filters are identified, the text
will be processed first using the filters and then by
Textile's own block formatting rules.

=back

=head2 Extended Blocks

Normally, a block ends with the first blank line encountered.
However, there are situations where you may want a block to continue
for multiple paragraphs of text. To cause a given block signature
to stay active, use two periods in your signature instead of one.
This will tell Textile to keep processing using that signature
until it hits the next signature is found.

For example:

    bq.. This is paragraph one of a block quote.

    This is paragraph two of a block quote.

    p. Now we're back to a regular paragraph.

You can apply this technique to any signature (although for
some it doesn't make sense, like "h1" for example). This is
especially useful for "bc" blocks where your code may
have many blank lines scattered through it.

=head2 Escaping

Sometimes you want Textile to just get out of the way and
let you put some regular HTML markup in your document. You
can disable Textile formatting for a given block using the "=="
escape mechanism:

    p. Regular paragraph

    ==
    Escaped portion -- will not be formatted
    by Textile at all
    ==

    p. Back to normal.

You can also use this technique within a Textile block,
temporarily disabling the inline formatting functions:

    p. This is ==*a test*== of escaping.

=head2 Inline Formatting

Formatting within a block of text is covered by the "inline"
formatting rules. These operators must be placed up against
text/punctuation to be recognized. These include:

=over

=item E<42>C<strong>E<42>

Translates into E<lt>strongE<gt>strongE<lt>/strongE<gt>.

=item C<_emphasis_>

Translates into E<lt>emE<gt>emphasisE<lt>/emE<gt>.

=item E<42>E<42>C<bold>E<42>E<42>

Translates into E<lt>bE<gt>boldE<lt>/bE<gt>.

=item C<__italics__>

Translates into E<lt>iE<gt>italicsE<lt>/iE<gt>.

=item C<++bigger++>

Translates into E<lt>bigE<gt>biggerE<lt>/bigE<gt>.

=item C<--smaller-->

Translates into: E<lt>smallE<gt>smallerE<lt>/smallE<gt>.

=item C<-deleted text->

Translates into E<lt>delE<gt>deleted textE<lt>/delE<gt>.

=item C<+inserted text+>

Translates into E<lt>insE<gt>inserted textE<lt>/insE<gt>.

=item C<^superscript^>

Translates into E<lt>supE<gt>superscriptE<lt>/supE<gt>.

=item C<~subscript~>

Translates into E<lt>subE<gt>subscriptE<lt>/subE<gt>.

=item C<%span%>

Translates into E<lt>spanE<gt>spanE<lt>/spanE<gt>.

=item C<@code@>

Translates into E<lt>codeE<gt>codeE<lt>/codeE<gt>. Note
that within a "@...@" section, E<lt> and E<gt> are
translated into HTML entities automatically.

=back

Inline formatting operators accept the following modifiers:

=over

=item C<{style rule}>

A CSS style rule.

=item C<[ll]>

A language identifier (for a "lang" attribute).

=item C<(class)> or C<(#id)> or C<(class#id)>

For CSS class and id attributes.

=back

=head3 Examples

    Textile is *way* cool.

    Textile is *_way_* cool.

Now this won't work, because the formatting
characters need whitespace before and after
to be properly recognized.

    Textile is way c*oo*l.

However, you can supply braces or brackets to
further clarify that you want to format, so
this would work:

    Textile is way c[*oo*]l.

=head2 Footnotes

You can create footnotes like this:

    And then he went on a long trip[1].

By specifying the brackets with a number inside, Textile will
recognize that as a footnote marker. It will replace that with
a construct like this:

    And then he went on a long
    trip<sup class="footnote"><a href="#fn1">1</a></sup>

To supply the content of the footnote, place it at the end of your
document using a "fn" block signature:

    fn1. And there was much rejoicing.

Which creates a paragraph that looks like this:

    <p class="footnote" id="fn1"><sup>1</sup> And there was
    much rejoicing.</p>

=head2 Links

Textile defines a shorthand for formatting hyperlinks.
The format looks like this:

    "Text to display":http://example.com

In addition to this, you can add "title" text to your link:

    "Text to display (Title text)":http://example.com

The URL portion of the link supports relative paths as well
as other protocols like ftp, mailto, news, telnet, etc.

    "E-mail me please":mailto:someone@example.com

You can also use single quotes instead of double-quotes if
you prefer. As with the inline formatting rules, a hyperlink
must be surrounded by whitespace to be recognized (an
exception to this is common punctuation which can reside
at the end of the URL). If you have to place a URL next to
some other text, use the bracket or brace trick to do that:

    You["gotta":http://example.com]seethis!

Textile supports an alternate way to compose links. You can
optionally create a lookup list of links and refer to them
separately. To do this, place one or more links in a block
of it's own (it can be anywhere within your document):

    [excom]http://example.com
    [exorg]http://example.org

For a list like this, the text in the square brackets is
used to uniquely identify the link given. To refer to that
link, you would specify it like this:

    "Text to display":excom

Once you've defined your link lookup table, you can use
the identifiers any number of times.

=head2 Images

Images are identified by the following pattern:

    !/path/to/image!

Image attributes may also be specified:

    !/path/to/image 10x20!

Which will render an image 10 pixels wide and 20 pixels high.
Another way to indicate width and height:

    !/path/to/image 10w 20h!

You may also redimension the image using a percentage.

    !/path/to/image 20%x40%!

Which will render the image at 20% of it's regular width
and 40% of it's regular height.

Or specify one percentage to resize proprotionately:

    !/path/to/image 20%!

Alt text can be given as well:

    !/path/to/image (Alt text)!

The path of the image may refer to a locally hosted image or
can be a full URL.

You can also use the following modifiers after the opening "!"
character:

=over

=item C<E<lt>>

Align the image to the left (causes the image to float if
CSS options are enabled).

=item C<E<gt>>

Align the image to the right (causes the image to float if
CSS options are enabled).

=item C<-> (dash)

Aligns the image to the middle.

=item C<^>

Aligns the image to the top.

=item C<~> (tilde)

Aligns the image to the bottom.

=item C<{style rule}>

Applies a CSS style rule to the image.

=item C<(class)> or C<(#id)> or C<(class#id)>

Applies a CSS class and/or id to the image.

=item C<(> (one or more)

Pads 1em on the left for each "(" character.

=item C<)> (one or more)

Pads 1em on the right for each ")" character.

=back

=head2 Character Replacements

A few simple, common symbols are automatically replaced:

    (c)
    (r)
    (tm)

In addition to these, there are a whole set of character
macros that are defined by default. All macros are enclosed
in curly braces. These include:

    {c|} or {|c} cent sign
    {L-} or {-L} pound sign
    {Y=} or {=Y} yen sign

Many of these macros can be guessed. For example:

    {A'} or {'A}
    {a"} or {"a}
    {1/4}
    {*}
    {:)}
    {:(}

=head2 Lists

Textile also supports ordered and unordered lists.
You simply place an asterisk or pound sign, followed
with a space at the start of your lines.

Simple lists:

    * one
    * two
    * three

Multi-level lists:

    * one
    ** one A
    ** one B
    *** one B1
    * two
    ** two A
    ** two B
    * three

Ordered lists:

    # one
    # two
    # three

Styling lists:

    (class#id)* one
    * two
    * three

The above sets the class and id attributes for the E<lt>ulE<gt>
tag.

    *(class#id) one
    * two
    * three

The above sets the class and id attributes for the first E<lt>liE<gt>
tag.

Definition lists:

    dl. textile:a cloth, especially one manufactured by weaving
    or knitting; a fabric
    format:the arrangement of data for storage or display.

Note that there is no space between the term and definition. The
term must be at the start of the line (or following the "dl"
signature as shown above).

=head2 Tables

Textile supports tables. Tables must be in their own block and
must have pipe characters delimiting the columns. An optional
block signature of "table" may be used, usually for applying
style, class, id or other options to the table element itself.

From the simple:

    |a|b|c|
    |1|2|3|

To the complex:

    table(fig). {color:red}_|Top|Row|
    {color:blue}|/2. Second|Row|
    |_{color:green}. Last|

Modifiers can be specified for the table signature itself,
for a table row (prior to the first "E<verbar>" character) and
for any cell (following the "E<verbar>" for that cell). Note that for
cells, a period followed with a space must be placed after
any modifiers to distinguish the modifier from the cell content.

Modifiers allowed are:

=over

=item C<{style rule}>

A CSS style rule.

=item C<(class)> or C<(#id)> or C<(class#id)>

A CSS class and/or id attribute.

=item C<(> (one or more)

Adds 1em of padding to the left for each "(" character.

=item C<)> (one or more)

Adds 1em of padding to the right for each ")" character.

=item C<E<lt>>

Aligns to the left (floats to left for tables if combined with the
")" modifier).

=item C<E<gt>>

Aligns to the right (floats to right for tables if combined with
the "(" modifier).

=item C<=>

Aligns to center (sets left, right margins to "auto" for tables).

=item C<E<lt>E<gt>>

For cells only. Justifies text.

=item C<^>

For rows and cells only. Aligns to the top.

=item C<~> (tilde)

For rows and cells only. Aligns to the bottom.

=item C<_> (underscore)

Can be applied to a table row or cell to indicate a header
row or cell.

=item C<\2> or C<\3> or C<\4>, etc.

Used within cells to indicate a colspan of 2, 3, 4, etc. columns.
When you see "\", think "push forward".

=item C</2> or C</3> or C</4>, etc.

Used within cells to indicate a rowspan or 2, 3, 4, etc. rows.
When you see "/", think "push downward".

=back

When a cell is identified as a header cell and an alignment
is specified, that becomes the default alignment for
cells below it. You can always override this behavior by
specifying an alignment for one of the lower cells.

=head2 CSS Notes

When CSS is enabled (and it is by default), CSS class names
are automatically applied in certain situations.

=over

=item Aligning a block or span or other element to
left, right, etc.

"left" for left justified, "right" for right justified,
"center" for centered text, "justify" for full-justified
text.

=item Aligning an image to the top or bottom

"top" for top alignment, "bottom" for bottom alignment,
"middle" for middle alignment.

=item Footnotes

"footnote" is applied to the paragraph tag for the
footnote text itself. An id of "fn" plus the footnote
number is placed on the paragraph for the footnote as
well. For the footnote superscript tag, a class of
"footnote" is used.

=item Capped text

For a series of characters that are uppercased, a
span is placed around them with a class of "caps".

=back

=head2 Miscellaneous

Textile tries to do it's very best to ensure proper XHTML
syntax. It will even attempt to fix errors you may introduce
writing in HTML yourself. Unescaped "&" characters within
URLs will be properly escaped. Singlet tags such as br, img
and hr are checked for the "/" terminator (and it's added
if necessary). The best way to make sure you produce valid
XHTML with Textile is to not use any HTML markup at all--
use the Textile syntax and let it produce the markup for you.

=head1 BUGS & SOURCE

Text::Textile is hosted at github.

Source: L<http://github.com/bradchoate/text-textile/tree/master>

Bugs: L<http://github.com/bradchoate/text-textile/issues>

=head1 COPYRIGHT & LICENSE

Copyright 2005-2009 Brad Choate, brad@bradchoate.com.

This program is free software; you can redistribute it and/or modify
it under the terms of either:

=over 4

=item * the GNU General Public License as published by the Free
Software Foundation; either version 1, or (at your option) any later
version, or

=item * the Artistic License version 2.0.

=back

Text::Textile is an adaptation of Textile, developed by Dean Allen
of Textism.com.

=cut

1;
