#!/usr/bin/perl -w

#
# SmartyPants  -  A Plug-In for Movable Type, Blosxom, and BBEdit
# by John Gruber
# http://daringfireball.net
#
# See the readme or POD for details, installation instructions, and
# license information.
#
# Copyright (c) 2003-2004 John Gruber
#
# This version is modified to German standards
#

package SmartyPants;
use strict;
use vars qw($VERSION);
$VERSION = "1.5.1";
# Fri 12 Mar 2004


# Configurable variables:
my $smartypants_attr = "2";  # Blosxom and BBEdit users: change this to configure.
                             #  1 =>  "--" for em-dashes; no en-dash support
                             #  2 =>  "---" for em-dashes; "--" for en-dashes
                             #  3 =>  "--" for em-dashes; "---" for en-dashes
                             #  See docs for more configuration options.


# Globals:
my $tags_to_skip = qr!<(/?)(?:pre|code|kbd|script|math|style)[\s>]!;


# Blosxom plug-in interface:
sub start { 1; }
sub story {
    my($pkg, $path, $filename, $story_ref, $title_ref, $body_ref) = @_;

    $$title_ref = SmartyPants($$title_ref, $smartypants_attr, undef);
    $$body_ref  = SmartyPants($$body_ref,  $smartypants_attr, undef);
    1;
}


# Movable Type plug-in interface:
eval {require MT::Template::Context};  # Test to see if we're running in MT.
unless ($@) {
    require MT::Template::Context;
    import MT::Template::Context;
    MT::Template::Context->add_global_filter( smarty_pants   =>  \&SmartyPants);
    MT::Template::Context->add_global_filter( smart_quotes   =>  \&SmartQuotes);
    MT::Template::Context->add_global_filter( smart_dashes   =>  \&SmartDashes);
    MT::Template::Context->add_global_filter( smart_ellipses =>  \&SmartEllipses);
    MT::Template::Context->add_tag( SmartyPantsVersion       =>  \&SmartyPantsVersion);

    # If Markdown is loaded, add a combo Markdown/SmartyPants text filter:
    my $filters = MT->all_text_filters();
    if (exists( $filters->{'markdown'} )) {
		my $markdown_ref = $filters->{'markdown'}{on_format};
		if ($markdown_ref) {
			MT->add_text_filter('markdown_with_smartypants' => {
				label => 'Markdown With SmartyPants',
				on_format => sub {
					my $text = shift;
					$text = &$markdown_ref($text);
					$text = SmartyPants($text, $smartypants_attr);
				},
				docs => 'http://daringfireball.net/projects/markdown/'
			});
		}
	}
}
else {
    # BBEdit text filter interface; needs to be hidden from MT
    # (and Blosxom when running in static mode).

    # Set up a do-nothing variable to keep Perl from warning us that
    # we're only using $blosxom::version once. The right way to do this
    # is to use "no warnings", but that doesn't work in Perl 5.005.
    my $in_blosxom = defined($blosxom::version);

    unless ( defined($blosxom::version) ) {
		#### Check for command-line switches: ###########################
		my %cli_opts;
		use Getopt::Long;
		Getopt::Long::Configure('pass_through');
		GetOptions(\%cli_opts,
			'version',
			'shortversion',
			'1',
			'2',
			'3',
		);
		if ($cli_opts{'version'}) {		# Version info
			print "\nThis is Markdown, version $VERSION.\n";
			print "Copyright 2004 John Gruber\n";
			print "http://daringfireball.net/projects/markdown/\n";
			exit 0;
		}
		if ($cli_opts{'shortversion'}) {		# Just the version number string.
			print $VERSION;
			exit 0;
		}
		if ($cli_opts{'1'}) { $smartypants_attr = 1 };
		if ($cli_opts{'2'}) { $smartypants_attr = 2 };
		if ($cli_opts{'3'}) { $smartypants_attr = 3 };


		#### Process incoming text: #####################################
        my $old = $/;
        undef $/;               # slurp the whole file
        my $text = <>;
        $/ = $old;
        print SmartyPants($text, $smartypants_attr, undef);
    }
}


sub SmartyPants {
    # Paramaters:
    my $text = shift;   # text to be parsed
    my $attr = shift;   # value of the smart_quotes="" attribute
    my $ctx  = shift;   # MT context object (unused)

    # Options to specify which transformations to make:
    my ($do_quotes, $do_backticks, $do_dashes, $do_ellipses, $do_stupefy);
    my $convert_quot = 0;  # should we translate &quot; entities into normal quotes?

    # Parse attributes:
    # 0 : do nothing
    # 1 : set all
    # 2 : set all, using old school en- and em- dash shortcuts
    # 3 : set all, using inverted old school en and em- dash shortcuts
    # 
    # q : quotes
    # b : backtick quotes (``double'' only)
    # B : backtick quotes (``double'' and `single')
    # d : dashes
    # D : old school dashes
    # i : inverted old school dashes
    # e : ellipses
    # w : convert &quot; entities to " for Dreamweaver users

    if ($attr eq "0") {
        # Do nothing.
        return $text;
    }
    elsif ($attr eq "1") {
        # Do everything, turn all options on.
        $do_quotes    = 1;
        $do_backticks = 1;
        $do_dashes    = 1;
        $do_ellipses  = 1;
    }
    elsif ($attr eq "2") {
        # Do everything, turn all options on, use old school dash shorthand.
        $do_quotes    = 1;
        $do_backticks = 1;
        $do_dashes    = 2;
        $do_ellipses  = 1;
    }
    elsif ($attr eq "3") {
        # Do everything, turn all options on, use inverted old school dash shorthand.
        $do_quotes    = 1;
        $do_backticks = 1;
        $do_dashes    = 3;
        $do_ellipses  = 1;
    }
    elsif ($attr eq "-1") {
        # Special "stupefy" mode.
        $do_stupefy   = 1;
    }
    else {
        my @chars = split(//, $attr);
        foreach my $c (@chars) {
            if    ($c eq "q") { $do_quotes    = 1; }
            elsif ($c eq "b") { $do_backticks = 1; }
            elsif ($c eq "B") { $do_backticks = 2; }
            elsif ($c eq "d") { $do_dashes    = 1; }
            elsif ($c eq "D") { $do_dashes    = 2; }
            elsif ($c eq "i") { $do_dashes    = 3; }
            elsif ($c eq "e") { $do_ellipses  = 1; }
            elsif ($c eq "w") { $convert_quot = 1; }
            else {
                # Unknown attribute option, ignore.
            }
        }
    }

    my $tokens ||= _tokenize($text);
    my $result = '';
    my $in_pre = 0;  # Keep track of when we're inside <pre> or <code> tags.

    my $prev_token_last_char = "";  # This is a cheat, used to get some context
                                    # for one-character tokens that consist of 
                                    # just a quote char. What we do is remember
                                    # the last character of the previous text
                                    # token, to use as context to curl single-
                                    # character quote tokens correctly.

    foreach my $cur_token (@$tokens) {
        if ($cur_token->[0] eq "tag") {
            # Don't mess with quotes inside tags.
            $result .= $cur_token->[1];
            if ($cur_token->[1] =~ m/$tags_to_skip/) {
                $in_pre = defined $1 && $1 eq '/' ? 0 : 1;
            }
        } else {
            my $t = $cur_token->[1];
            my $last_char = substr($t, -1); # Remember last char of this token before processing.
            if (! $in_pre) {
                $t = ProcessEscapes($t);

                if ($convert_quot) {
                    $t =~ s/&quot;/"/g;
                }

                if ($do_dashes) {
                    $t = EducateDashes($t)                  if ($do_dashes == 1);
                    $t = EducateDashesOldSchool($t)         if ($do_dashes == 2);
                    $t = EducateDashesOldSchoolInverted($t) if ($do_dashes == 3);
                }

                $t = EducateEllipses($t) if $do_ellipses;

                # Note: backticks need to be processed before quotes.
                if ($do_backticks) {
                    $t = EducateBackticks($t);
                    $t = EducateSingleBackticks($t) if ($do_backticks == 2);
                }

                if ($do_quotes) {
                    if ($t eq q/'/) {
                        # Special case: single-character ' token
                        if ($prev_token_last_char =~ m/\S/) {
                            $t = "&#8216;";
                        }
                        else {
                            $t = "&#8218;";
                        }
                    }
                    elsif ($t eq q/"/) {
                        # Special case: single-character " token
                        if ($prev_token_last_char =~ m/\S/) {
                            $t = "&#171;";
                        }
                        else {
                            $t = "&#187;";
                        }
                    }
                    else {
                        # Normal case:                  
                        $t = EducateQuotes($t);
                    }
                }

                $t = StupefyEntities($t) if $do_stupefy;
            }
            $prev_token_last_char = $last_char;
            $result .= $t;
        }
    }

    return $result;
}


sub SmartQuotes {
    # Paramaters:
    my $text = shift;   # text to be parsed
    my $attr = shift;   # value of the smart_quotes="" attribute
    my $ctx  = shift;   # MT context object (unused)

    my $do_backticks;   # should we educate ``backticks'' -style quotes?

    if ($attr == 0) {
        # do nothing;
        return $text;
    }
    elsif ($attr == 2) {
        # smarten ``backticks'' -style quotes
        $do_backticks = 1;
    }
    else {
        $do_backticks = 0;
    }

    # Special case to handle quotes at the very end of $text when preceded by
    # an HTML tag. Add a space to give the quote education algorithm a bit of
    # context, so that it can guess correctly that it's a closing quote:
    my $add_extra_space = 0;
    if ($text =~ m/>['"]\z/) {
        $add_extra_space = 1; # Remember, so we can trim the extra space later.
        $text .= " ";
    }

    my $tokens ||= _tokenize($text);
    my $result = '';
    my $in_pre = 0;  # Keep track of when we're inside <pre> or <code> tags

    my $prev_token_last_char = "";  # This is a cheat, used to get some context
                                    # for one-character tokens that consist of 
                                    # just a quote char. What we do is remember
                                    # the last character of the previous text
                                    # token, to use as context to curl single-
                                    # character quote tokens correctly.

    foreach my $cur_token (@$tokens) {
        if ($cur_token->[0] eq "tag") {
            # Don't mess with quotes inside tags
            $result .= $cur_token->[1];
            if ($cur_token->[1] =~ m/$tags_to_skip/) {
                $in_pre = defined $1 && $1 eq '/' ? 0 : 1;
            }
        } else {
            my $t = $cur_token->[1];
            my $last_char = substr($t, -1); # Remember last char of this token before processing.
            if (! $in_pre) {
                $t = ProcessEscapes($t);
                if ($do_backticks) {
                    $t = EducateBackticks($t);
                }

                if ($t eq q/'/) {
                    # Special case: single-character ' token
                    if ($prev_token_last_char =~ m/\S/) {
                        $t = "&#8216;";
                    }
                    else {
                        $t = "&#8218;";
                    }
                }
                elsif ($t eq q/"/) {
                    # Special case: single-character " token
                    if ($prev_token_last_char =~ m/\S/) {
                        $t = "&#171;";
                    }
                    else {
                        $t = "&#187;";
                    }
                }
                else {
                    # Normal case:                  
                    $t = EducateQuotes($t);
                }

            }
            $prev_token_last_char = $last_char;
            $result .= $t;
        }
    }

    if ($add_extra_space) {
        $result =~ s/ \z//;  # Trim trailing space if we added one earlier.
    }
    return $result;
}


sub SmartDashes {
    # Paramaters:
    my $text = shift;   # text to be parsed
    my $attr = shift;   # value of the smart_dashes="" attribute
    my $ctx  = shift;   # MT context object (unused)

    # reference to the subroutine to use for dash education, default to EducateDashes:
    my $dash_sub_ref = \&EducateDashes;

    if ($attr == 0) {
        # do nothing;
        return $text;
    }
    elsif ($attr == 2) {
        # use old smart dash shortcuts, "--" for en, "---" for em
        $dash_sub_ref = \&EducateDashesOldSchool; 
    }
    elsif ($attr == 3) {
        # inverse of 2, "--" for em, "---" for en
        $dash_sub_ref = \&EducateDashesOldSchoolInverted; 
    }

    my $tokens;
    $tokens ||= _tokenize($text);

    my $result = '';
    my $in_pre = 0;  # Keep track of when we're inside <pre> or <code> tags
    foreach my $cur_token (@$tokens) {
        if ($cur_token->[0] eq "tag") {
            # Don't mess with quotes inside tags
            $result .= $cur_token->[1];
            if ($cur_token->[1] =~ m/$tags_to_skip/) {
                $in_pre = defined $1 && $1 eq '/' ? 0 : 1;
            }
        } else {
            my $t = $cur_token->[1];
            if (! $in_pre) {
                $t = ProcessEscapes($t);
                $t = $dash_sub_ref->($t);
            }
            $result .= $t;
        }
    }
    return $result;
}


sub SmartEllipses {
    # Paramaters:
    my $text = shift;   # text to be parsed
    my $attr = shift;   # value of the smart_ellipses="" attribute
    my $ctx  = shift;   # MT context object (unused)

    if ($attr == 0) {
        # do nothing;
        return $text;
    }

    my $tokens;
    $tokens ||= _tokenize($text);

    my $result = '';
    my $in_pre = 0;  # Keep track of when we're inside <pre> or <code> tags
    foreach my $cur_token (@$tokens) {
        if ($cur_token->[0] eq "tag") {
            # Don't mess with quotes inside tags
            $result .= $cur_token->[1];
            if ($cur_token->[1] =~ m/$tags_to_skip/) {
                $in_pre = defined $1 && $1 eq '/' ? 0 : 1;
            }
        } else {
            my $t = $cur_token->[1];
            if (! $in_pre) {
                $t = ProcessEscapes($t);
                $t = EducateEllipses($t);
            }
            $result .= $t;
        }
    }
    return $result;
}


sub EducateQuotes {
#
#   Parameter:  String.
#
#   Returns:    The string, with "educated" curly quote HTML entities.
#
#   Example input:  "Isn't this fun?"
#   Example output: &#187;Isn&#8216;t this fun?&#171;
#

    local $_ = shift;

    # Tell perl not to gripe when we use $1 in substitutions,
    # even when it's undefined. Use $^W instead of "no warnings"
    # for compatibility with Perl 5.005:
    local $^W = 0;


    # Make our own "punctuation" character class, because the POSIX-style
    # [:PUNCT:] is only available in Perl 5.6 or later:
    my $punct_class = qr/[!"#\$\%'()*+,-.\/:;<=>?\@\[\\\]\^_`{|}~]/;

    # Special case if the very first character is a quote
    # followed by punctuation at a non-word-break. Close the quotes by brute force:
    s/^'(?=$punct_class\B)/&#8216;/;
    s/^"(?=$punct_class\B)/&#171;/;


    # Special case for double sets of quotes, e.g.:
    #   <p>He said, "'Quoted' words in a larger quote."</p>
    s/"'(?=\w)/&#187;&#8218;/g;
    s/'"(?=\w)/&#8218;&#187;/g;

    # Special case for decade abbreviations (the '80s):
    s/'(?=\d{2}s)/&#8217;/g;

    my $close_class = qr![^\ \t\r\n\[\{\(\-]!;
    my $dec_dashes = qr/&#8211;|&#8212;/;

    # Get most opening single quotes:
    s {
        (
            \s          |   # a whitespace char, or
            &nbsp;      |   # a non-breaking space entity, or
            --          |   # dashes, or
            &[mn]dash;  |   # named dash entities
            $dec_dashes |   # or decimal entities
            &\#x201[34];    # or hex
        )
        '                   # the quote
        (?=\w)              # followed by a word character
    } {$1&#8218;}xg;
    # Single closing quotes:
    s {
        ($close_class)?
        '
        (?(1)|          # If $1 captured, then do nothing;
          (?=\s | s\b)  # otherwise, positive lookahead for a whitespace
        )               # char or an 's' at a word ending position. This
                        # is a special case to handle something like:
                        # "<i>Custer</i>'s Last Stand."
    } {$1&#8217;}xgi;

    # Any remaining single quotes should be opening ones:
    s/'/&#8218;/g;


    # Get most opening double quotes:
    s {
        (
            \s          |   # a whitespace char, or
            &nbsp;      |   # a non-breaking space entity, or
            --          |   # dashes, or
            &[mn]dash;  |   # named dash entities
            $dec_dashes |   # or decimal entities
            &\#x201[34];    # or hex
        )
        "                   # the quote
        (?=\w)              # followed by a word character
    } {$1&#187;}xg;

    # Double closing quotes:
    s {
        ($close_class)?
        "
        (?(1)|(?=\s))   # If $1 captured, then do nothing;
                           # if not, then make sure the next char is whitespace.
    } {$1&#171;}xg;

    # Any remaining quotes should be opening ones.
    s/"/&#187;/g;

    return $_;
}


sub EducateBackticks {
#
#   Parameter:  String.
#   Returns:    The string, with ``backticks'' -style double quotes
#               translated into HTML curly quote entities.
#
#   Example input:  ``Isn't this fun?''
#   Example output: &#187;Isn't this fun?&#171;
#

    local $_ = shift;
    s/``/&#187;/g;
    s/''/&#171;/g;
    return $_;
}


sub EducateSingleBackticks {
#
#   Parameter:  String.
#   Returns:    The string, with `backticks' -style single quotes
#               translated into HTML curly quote entities.
#
#   Example input:  `Isn't this fun?'
#   Example output: &#8218;Isn&#8216;t this fun?&#8216;
#

    local $_ = shift;
    s/`/&#8218;/g;
    s/'/&#8216;/g;
    return $_;
}


sub EducateDashes {
#
#   Parameter:  String.
#
#   Returns:    The string, with each instance of "--" translated to
#               an em-dash HTML entity.
#

    local $_ = shift;
    s/--/&#8212;/g;
    return $_;
}


sub EducateDashesOldSchool {
#
#   Parameter:  String.
#
#   Returns:    The string, with each instance of "--" translated to
#               an en-dash HTML entity, and each "---" translated to
#               an em-dash HTML entity.
#

    local $_ = shift;
    s/---/&#8212;/g;    # em
    s/--/&#8211;/g;     # en
    return $_;
}


sub EducateDashesOldSchoolInverted {
#
#   Parameter:  String.
#
#   Returns:    The string, with each instance of "--" translated to
#               an em-dash HTML entity, and each "---" translated to
#               an en-dash HTML entity. Two reasons why: First, unlike the
#               en- and em-dash syntax supported by
#               EducateDashesOldSchool(), it's compatible with existing
#               entries written before SmartyPants 1.1, back when "--" was
#               only used for em-dashes.  Second, em-dashes are more
#               common than en-dashes, and so it sort of makes sense that
#               the shortcut should be shorter to type. (Thanks to Aaron
#               Swartz for the idea.)
#

    local $_ = shift;
    s/---/&#8211;/g;    # en
    s/--/&#8212;/g;     # em
    return $_;
}


sub EducateEllipses {
#
#   Parameter:  String.
#   Returns:    The string, with each instance of "..." translated to
#               an ellipsis HTML entity. Also converts the case where
#               there are spaces between the dots.
#
#   Example input:  Huh...?
#   Example output: Huh&#8230;?
#

    local $_ = shift;
    s/\.\.\./&#8230;/g;
    s/\. \. \./&#8230;/g;
    return $_;
}


sub StupefyEntities {
#
#   Parameter:  String.
#   Returns:    The string, with each SmartyPants HTML entity translated to
#               its ASCII counterpart.
#
#   Example input:  &#187;Hello &#8212; world.&#171;
#   Example output: "Hello -- world."
#

    local $_ = shift;

    s/&#8211;/-/g;      # en-dash
    s/&#8212;/--/g;     # em-dash

    s/&#8218;/'/g;      # open single quote
    s/&#8216;/'/g;      # close single quote

    s/&#187;/"/g;      # open double quote
    s/&#171;/"/g;      # close double quote

    s/&#8230;/.../g;    # ellipsis

    return $_;
}


sub SmartyPantsVersion {
    return $VERSION;
}


sub ProcessEscapes {
#
#   Parameter:  String.
#   Returns:    The string, with after processing the following backslash
#               escape sequences. This is useful if you want to force a "dumb"
#               quote or other character to appear.
#
#               Escape  Value
#               ------  -----
#               \\      &#92;
#               \"      &#34;
#               \'      &#39;
#               \.      &#46;
#               \-      &#45;
#               \`      &#96;
#
    local $_ = shift;

    s! \\\\ !&#92;!gx;
    s! \\"  !&#34;!gx;
    s! \\'  !&#39;!gx;
    s! \\\. !&#46;!gx;
    s! \\-  !&#45;!gx;
    s! \\`  !&#96;!gx;

    return $_;
}


sub _tokenize {
#
#   Parameter:  String containing HTML markup.
#   Returns:    Reference to an array of the tokens comprising the input
#               string. Each token is either a tag (possibly with nested,
#               tags contained therein, such as <a href="<MTFoo>">, or a
#               run of text between tags. Each element of the array is a
#               two-element array; the first is either 'tag' or 'text';
#               the second is the actual value.
#
#
#   Based on the _tokenize() subroutine from Brad Choate's MTRegex plugin.
#       <http://www.bradchoate.com/past/mtregex.php>
#

    my $str = shift;
    my $pos = 0;
    my $len = length $str;
    my @tokens;

    my $depth = 6;
    my $nested_tags = join('|', ('(?:<(?:[^<>]') x $depth) . (')*>)' x  $depth);
    my $match = qr/(?s: <! ( -- .*? -- \s* )+ > ) |  # comment
                   (?s: <\? .*? \?> ) |              # processing instruction
                   $nested_tags/x;                   # nested tags

    while ($str =~ m/($match)/g) {
        my $whole_tag = $1;
        my $sec_start = pos $str;
        my $tag_start = $sec_start - length $whole_tag;
        if ($pos < $tag_start) {
            push @tokens, ['text', substr($str, $pos, $tag_start - $pos)];
        }
        push @tokens, ['tag', $whole_tag];
        $pos = pos $str;
    }
    push @tokens, ['text', substr($str, $pos, $len - $pos)] if $pos < $len;
    \@tokens;
}


1;
__END__


=pod

=head1 NAME

B<SmartyPants>


=head1 SYNOPSIS

B<SmartyPants.pl> [ B<-1> ] [ B<-2> ] [ B<-3> ] [ B<--version> ] [ B<--shortversion> ]
    [ I<file> ... ]


=head1 DESCRIPTION

SmartyPants is a web publishing utility that translates plain ASCII
punctuation characters into "smart" typographic punctuation HTML
entities. SmartyPants can perform the following transformations:

=over 4

=item *

Straight quotes ( " and ' ) into "curly" quote HTML entities

=item *

Backticks-style quotes (``like this'') into "curly" quote HTML entities

=item *

Dashes (C<--> and C<--->) into en- and em-dash entities

=item *

Three consecutive dots (C<...>) into an ellipsis entity

=back

SmartyPants is a combination plug-in -- the same file works with Movable
Type, Blosxom, BBEdit, and as a standalone Perl script. Version
requirements and installation instructions for each of these tools can
be found in the readme file that accompanies this script.

SmartyPants does not modify characters within C<< <pre> >>, C<< <code> >>,
C<< <kbd> >>, C<< <script> >>, or C<< <math> >> tag blocks.
Typically, these tags are used to display text where smart quotes and
other "smart punctuation" would not be appropriate, such as source code
or example markup.


=head2 Backslash Escapes

If you need to use literal straight quotes (or plain hyphens and
periods), SmartyPants accepts the following backslash escape sequences
to force non-smart punctuation. It does so by transforming the escape
sequence into a decimal-encoded HTML entity:

              Escape  Value  Character
              ------  -----  ---------
                \\    &#92;    \
                \"    &#34;    "
                \'    &#39;    '
                \.    &#46;    .
                \-    &#45;    -
                \`    &#96;    `

This is useful, for example, when you want to use straight quotes as
foot and inch marks: 6'2" tall; a 17" iMac.


=head1 OPTIONS

Use "--" to end switch parsing. For example, to open a file named "-z", use:

	SmartyPants.pl -- -z

=over 4


=item B<-1>

Performs default SmartyPants transformations: quotes (including
backticks-style), em-dashes, and ellipses. '--' (dash dash) is used to
signify an em-dash; there is no support for en-dashes.


=item B<-2>

Same as B<-1>, except that it uses the old-school typewriter shorthand
for dashes: '--' (dash dash) for en-dashes, '---' (dash dash dash) for
em-dashes.


=item B<-3>

Same as B<-2>, but inverts the shorthand for dashes: '--'
(dash dash) for em-dashes, and '---' (dash dash dash) for en-dashes.


=item B<-v>, B<--version>

Display SmartyPants's version number and copyright information.


=item B<-s>, B<--shortversion>

Display the short-form version number.


=back



=head1 BUGS

To file bug reports or feature requests (other than topics listed in the
Caveats section above) please send email to:

    smartypants@daringfireball.net

If the bug involves quotes being curled the wrong way, please send example
text to illustrate.


=head2 Algorithmic Shortcomings

One situation in which quotes will get curled the wrong way is when
apostrophes are used at the start of leading contractions. For example:

    'Twas the night before Christmas.

In the case above, SmartyPants will turn the apostrophe into an opening
single-quote, when in fact it should be a closing one. I don't think
this problem can be solved in the general case -- every word processor
I've tried gets this wrong as well. In such cases, it's best to use the
proper HTML entity for closing single-quotes (C<&#8216;>) by hand.



=head1 VERSION HISTORY

    1.5.1: Fri 12 Mar 2004
    
    +   Fixed a goof where if you had SmartyPants 1.5.0 installed,
    	but didn't have Markdown installed, when SmartyPants checked
    	for Markdown's presence, it created a blank entry in MT's
    	global hash of installed text filters. This showed up in MT's
    	Text Formatting pop-up menu as a blank entry.


    1.5: Tue 9 Mar 2004
    
    +   Integration with Markdown. If Markdown is already loaded
        when SmartyPants loads, SmartyPants will add a new global
        text filter, "Markdown With Smartypants".
    
    +   Preliminary command-line options parsing. -1 -2 -3
        -v -V
    
    +   dot-space-dot-space-dot now counts as an ellipsis.
        This is the style used by Project Gutenberg:
        http://www.gutenberg.net/faq/index.shtml#V.110
        (Thanks to Fred Condo for the patch.)
    
    +	Added `<math>` to the list of tags to skip (pre, code, etc.).


    1.4.1: Sat 8 Nov 2003

    +   The bug fix from 1.4 for dashes followed by quotes with no
        intervening spaces now actually works.

    +   "&nbsp;" now counts as whitespace where necessary. (Thanks to
        Greg Knauss for the patch.)


    1.4: Mon 30 Jun 2003

    +   Improved the HTML tokenizer so that it will parse nested <> pairs
        up to five levels deep. Previously, it only parsed up to two
        levels. What we *should* do is allow for any arbitrary level of
        nesting, but to do so, we would need to use Perl's ?? construct
        (see Fried's "Mastering Regular Expressions", 2nd Ed., pp.
        328-331), and sadly, this would only work in Perl 5.6 or later.
        SmartyPants still supports Perl 5.00503. I suppose we could test
        for the version and build a regex accordingly, but I don't think
        I want to maintain two separate patterns.

    +   Thanks to Stepan Riha, the tokenizer now handles HTML comments:
            <!-- comment -->

        and PHP-style processor instructions:
            <?php code ?>

    +   The quote educator now handles situations where dashes are used
        without whitespace, e.g.:

            "dashes"--without spaces--"are tricky"  

    +   Special case for decade abbreviations like this: the '80s.
        This only works for the sequence appostrophe-digit-digit-s.


    1.3: Tue 13 May 2003

    +   Plugged the biggest hole in SmartyPants's smart quotes algorithm.
        Previous versions were hopelessly confused by single-character
        quote tokens, such as:

            <p>"<i>Tricky!</i>"</p>

        The problem was that the EducateQuotes() function works on each
        token separately, with no means of getting surrounding context
        from the previous or next tokens. The solution is to curl these
        single-character quote tokens as a special case, *before* calling
        EducateQuotes().

    +   New single-quotes backtick mode for smarty_pants attribute.
        The only way to turn it on is to include "B" in the configuration
        string, e.g. to translate backtick quotes, dashes, and ellipses:

            smarty_pants="Bde"

    +   Fixed a bug where an opening quote would get curled the wrong way
        if the quote started with three dots, e.g.:

            <p>"...meanwhile"</p>

    +   Fixed a bug where opening quotes would get curled the wrong way
        if there were double sets of quotes within each other, e.g.:

            <p>"'Some' people."</p>

    +   Due to popular demand, four consecutive dots (....) will now be
        turned into an ellipsis followed by a period. Previous versions
        would turn this into a period followed by an ellipsis. If you
        really want a period-then-ellipsis sequence, escape the first
        period with a backslash: \....

    +   Removed "&" from our home-grown punctuation class, since it
        denotes an entity, not a literal ampersand punctuation
        character. This fixes a bug where SmartyPants would mis-curl
        the opening quote in something like this:

            "&#8230;whatever"

    +   SmartyPants has always had a special case where it looks for
        "'s" in situations like this:

            <i>Custer</i>'s Last Stand

        This special case is now case-insensitive.


    1.2.2: Thu Mar 13, 2003

    +   1.2.1 contained a boneheaded addition which prevented SmartyPants
        from compiling under Perl 5.005. This has been remedied, and is
        the only change from 1.2.1.


    1.2.1: Mon Mar 10, 2003

    +   New "stupefy mode" for smarty_pants attribute. If you set

            smarty_pants="-1"

        SmartyPants will perform reverse transformations, turning HTML
        entities into plain ASCII equivalents. E.g. "&#187;" is turned
        into a simple double-quote ("), "&#8212;" is turned into two
        dashes, etc. This is useful if you are using SmartyPants from Brad
        Choate's MT-Textile text filter, but wish to suppress smart
        punctuation in specific MT templates, such as RSS feeds. Text
        filters do their work before templates are processed; but you can
        use smarty_pants="-1" to reverse the transformations in specific
        templates.

    +   Replaced the POSIX-style regex character class [:punct:] with an
        ugly hard-coded normal character class of all punctuation; POSIX
        classes require Perl 5.6 or later, but SmartyPants still supports
        back to 5.005.

    +   Several small changes to allow SmartyPants to work when Blosxom
        is running in static mode.


    1.2: Thu Feb 27, 2003

    +   SmartyPants is now a combination plug-in, supporting both
        Movable Type (2.5 or later) and Blosxom (2.0 or later).
        It also works as a BBEdit text filter and standalone
        command-line Perl program. Thanks to Rael Dornfest for the
        initial Blosxom port (and for the excellent Blosxom plug-in
        API).

    +   SmartyPants now accepts the following backslash escapes,
        to force non-smart punctuation. It does so by transforming
        the escape sequence into a decimal-encoded HTML entity: 

              Escape  Value  Character
              ------  -----  ---------
                \\    &#92;    \
                \"    &#34;    "
                \'    &#39;    '
                \.    &#46;    .
                \-    &#45;    -
                \`    &#96;    `

        Note that this could produce different results than previous
        versions of SmartyPants, if for some reason you have an article
        containing one or more of these sequences. (Thanks to Charles
        Wiltgen for the suggestion.)

    +   Added a new option to support inverted en- and em-dash notation:
        "--" for em-dashes, "---" for en-dashes. This is compatible with
        SmartyPants' original "--" syntax for em-dashes, but also allows
        you to specify en-dashes. It can be invoked by using
        smart_dashes="3", smarty_pants="3", or smarty_pants="i". 
        (Suggested by Aaron Swartz.)

    +   Added a new option to automatically convert &quot; entities into
        regular double-quotes before sending text to EducateQuotes() for
        processing. This is mainly for the benefit of people who write
        posts using Dreamweaver, which substitutes this entity for any
        literal quote char. The one and only way to invoke this option
        is to use the letter shortcuts for the smarty_pants attribute;
        the shortcut for this option is "w" (for Dream_w_eaver).
        (Suggested by Jonathon Delacour.)

    +   Added <script> to the list of tags in which SmartyPants doesn't
        touch the contents.

    +   Fixed a very subtle bug that would occur if a quote was the very
        last character in a body of text, preceded immediately by a tag.
        Lacking any context, previous versions of SmartyPants would turn
        this into an opening quote mark. It's now correctly turned into
        a closing one.

    +   Opening quotes were being curled the wrong way when the
        subsequent character was punctuation. E.g.: "a '.foo' file".
        Fixed.

    +   New MT global template tag: <$MTSmartyPantsVersion$>
        Prints the version number of SmartyPants, e.g. "1.2".


    1.1: Wed Feb 5, 2003

    +   The smart_dashes template attribute now offers an option to
        use "--" for *en* dashes, and "---" for *em* dashes.

    +   The default smart_dashes behavior now simply translates "--"
        (dash dash) into an em-dash. Previously, it would look for
        " -- " (space dash dash space), which was dumb, since many
        people do not use spaces around their em dashes.

    +   Using the smarty_pants attribute with a value of "2" will
        do the same thing as smarty_pants="1", with one difference:
        it will use the new shortcuts for en- and em-dashes.

    +   Closing quotes (single and double) were incorrectly curled in
        situations like this:
            "<a>foo</a>",
        where the comma could be just about any punctuation character.
        Fixed.

    +   Added <kbd> to the list of tags in which text shouldn't be
        educated.


    1.0: Wed Nov 13, 2002

        Initial release.


=head1 AUTHOR

    John Gruber
    http://daringfireball.net


=head1 ADDITIONAL CREDITS

Portions of this plug-in are based on Brad Choate's nifty MTRegex plug-in.
Brad Choate also contributed a few bits of source code to this plug-in.
Brad Choate is a fine hacker indeed. (http://bradchoate.com/)

Jeremy Hedley (http://antipixel.com/) and Charles Wiltgen
(http://playbacktime.com/) deserve mention for exemplary beta testing.

Rael Dornfest (http://raelity.org/) ported SmartyPants to Blosxom.


=head1 COPYRIGHT AND LICENSE

    Copyright (c) 2003 John Gruber
    (http://daringfireball.net/)
    All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

*   Redistributions of source code must retain the above copyright
    notice, this list of conditions and the following disclaimer.

*   Redistributions in binary form must reproduce the above copyright
    notice, this list of conditions and the following disclaimer in the
    documentation and/or other materials provided with the distribution.

*   Neither the name "SmartyPants" nor the names of its contributors may
    be used to endorse or promote products derived from this software
    without specific prior written permission.

This software is provided by the copyright holders and contributors "as is"
and any express or implied warranties, including, but not limited to, the 
implied warranties of merchantability and fitness for a particular purpose 
are disclaimed. In no event shall the copyright owner or contributors be 
liable for any direct, indirect, incidental, special, exemplary, or 
consequential damages (including, but not limited to, procurement of 
substitute goods or services; loss of use, data, or profits; or business 
interruption) however caused and on any theory of liability, whether in 
contract, strict liability, or tort (including negligence or otherwise) 
arising in any way out of the use of this software, even if advised of the
possibility of such damage.

=cut
