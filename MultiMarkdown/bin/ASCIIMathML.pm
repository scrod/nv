package Text::ASCIIMathML;

=pod
=head1 NAME

Text::ASCIIMathML - Perl extension for parsing ASCIIMathML text into MathML

=head1 SYNOPSIS

 use Text::ASCIIMathML;

 $parser=new Text::ASCIIMathML();

 $parser->SetAttributes(ForMoz => 1);

 $ASCIIMathML = "int_0^1 e^x dx";
 $mathML = $parser->TextToMathML($ASCIIMathML);
 $mathML = $parser->TextToMathML($ASCIIMathML, [title=>$ASCIIMathML]);
 $mathML = $parser->TextToMathML($ASCIIMathML, undef, [displaystyle=>1]);

 $mathMLTree = $parser->TextToMathMLTree($ASCIIMathML);
 $mathMLTree = $parser->TextToMathMLTree($ASCIIMathML, [title=>$ASCIIMathML]);
 $mathMLTree = $parser->TextToMathMLTree($ASCIIMathML,undef,[displaystyle=>1]);

 $mathML = $mathMLTree->text();
 $latex  = $mathMLTree->latex();

=head1 DESCRIPTION

Text::ASCIIMathML is a parser for ASCIIMathML text which produces
MathML XML markup strings that are suitable for rendering by any
MathML-compliant browser.

The parser uses the following attributes which are settable through
the SetAttributes method:

=over 4

=item C<ForMoz>

Specifies that the fonts should be optimized for Netscape/Mozilla/Firefox.

=back

The output of the TextToMathML method always follows the schema
  <math><mstyle>...</mstyle></math>
The first argument of TextToMathML is the ASCIIMathML text to be
parsed into MathML.  The second argument is a reference to an array of
attribute/value pairs to be attached to the <math> node and the third
argument is a reference to an array of attribute/value pairs for the
<mstyle> node.  Common attributes for the <math> node are "title" and
"xmlns"=>"&mathml;".  Common attributes for the <mstyle> node are
"mathcolor" (for text color), "displaystyle"=>"true" for using display
style instead of inline style, and "fontfamily".

=head2 ASCIIMathML markup

The syntax is very permissive and does not generate syntax
errors. This allows mathematically incorrect expressions to be
displayed, which is important for teaching purposes. It also causes
less frustration when previewing formulas.

If you encode 'x^2' or 'a_(mn)' or 'a_{mn}' or '(x+1)/y' or 'sqrtx',
you pretty much get what you expect.  The choice of grouping
parenthesis is up to you (they don't have to match either). If the
displayed expression can be parsed uniquely without them, they are
omitted.  Most LaTeX commands are also supported, so the last two
formulas above can also be written as '\frac{x+1}{y}' and '\sqrt{x}'.

The parser uses no operator precedence and only respects the grouping
brackets, subscripts, superscript, fractions and (square) roots. This
is done for reasons of efficiency and generality. The resulting MathML
code can quite easily be processed further to ensure additional
syntactic requirements of any particular application.

=head3 The grammar

Here is a definition of the grammar used to parse
ASCIIMathML expressions. In the Backus-Naur form given below, the
letter on the left of the C<::=> represents a category of symbols that
could be one of the possible sequences of symbols listed on the right.
The vertical bar C<|> separates the alternatives.

=over 4

 c ::= [A-z] | numbers | greek letters | other constant symbols 
				    (see below)
 u ::= 'sqrt' | 'text' | 'bb' | other unary symbols for font commands
 b ::= 'frac' | 'root' | 'stackrel' | 'newcommand' | 'newsymbol'
                                    binary symbols
 l ::= ( | [ | { | (: | {:          left brackets
 r ::= ) | ] | } | :) | :}          right brackets
 S ::= c | lEr | uS | bSS | "any"   simple expression
 E ::= SE | S/S |S_S | S^S | S_S^S  expression (fraction, sub-,
				    super-, subsuperscript)

=back

=head3 The translation rules

Each terminal symbol is translated into a corresponding MathML
node. The constants are mostly converted to their respective Unicode
symbols. The other expressions are converted as follows:

=over 4

 lSr	  ->	<mrow>lSr</mrow> 
		(note that any pair of brackets can be used to
		delimit subexpressions, they don't have to match)
 sqrt S	  ->	<msqrt>S'</msqrt>
 text S	  ->	<mtext>S'</mtext>
 "any"	  ->	<mtext>any</mtext>
 frac S1 S2	->	<mfrac>S1' S2'</mfrac>
 root S1 S2	->	<mroot>S2' S1'</mroot>
 stackrel S1 S2	->	<mover>S2' S1'</mover>
 S1/S2	  ->	<mfrac>S1' S2'</mfrac>
 S1_S2	  ->	<msub>S1 S2'</msub>
 S1^S2	  ->	<msup>S1 S2'</msup>
 S1_S2^S3 ->	<msubsup>S1 S2' S3'</msubsup> or
		 <munderover>S1 S2' S3'</munderover> (in some cases)
 S1^S2_S3 ->	<msubsup>S1 S3' S2'</msubsup> or
		 <munderover>S1 S3' S2'</munderover> (in some cases)

=back

In the rules above, the expression C<S'> is the same as C<S>, except that if
C<S> has an outer level of brackets, then C<S'> is the expression inside 
these brackets.

=head3 Matrices

A simple syntax for matrices is also recognized:

 l(S11,...,S1n),(...),(Sm1,...,Smn)r
     or    
 l[S11,...,S1n],[...],[Sm1,...,Smn]r.

Here C<l> and C<r> stand for any of the left and right
brackets (just like in the grammar they do not have to match). Both of
these expressions are translated to

 <mrow>l<mtable><mtr><mtd>S11</mtd>...
 <mtd>S1n</mtd></mtr>...
 <mtr><mtd>Sm1</mtd>... 
 <mtd>Smn</mtd></mtr></mtable>r</mrow>.

Note that each row must have the same number of expressions, and there
should be at least two rows.

LaTeX matrix commands are not recognized.

=head3 Tokenization

The input formula is broken into tokens using a "longest matching
initial substring search". Suppose the input formula has been
processed from left to right up to a fixed position. The longest
string from the list of constants (given below) that matches the
initial part of the remainder of the formula is the next token. If
there is no matching string, then the first character of the remainder
is the next token.  The symbol table at the top of the ASCIIMathML.js
script specifies whether a symbol is a math operator (surrounded by a
C<< <mo> >> tag) or a math identifier (surrounded by a C<< <mi> >>
tag). For single character tokens, letters are treated as math
identifiers, and non-alphanumeric characters are treated as math
operators. For digits, see "Numbers" below.

Spaces are significant when they separate characters and thus prevent
a certain string of characters from matching one of the
constants. Multiple spaces and end-of-line characters are equivalent
to a single space.

=head3 Numbers

A string of digits, optionally followed by a decimal point (a period)
and another string of digits, is parsed as a single token and
converted to a MathML number, i.e., enclosed with the C<< <mn> >>
tag.

=head3 Greek letters

=over 4

=item Lowercase letters 

C<alpha> C<beta> C<chi> C<delta> C<epsilon> C<eta> C<gamma> C<iota>
C<kappa> C<lambda> C<mu> C<nu> C<omega> C<phi> C<pi> C<psi> C<rho>
C<sigma> C<tau> C<theta> C<upsilon> C<xi> C<zeta>

=item Uppercase letters

C<Delta> C<Gamma> C<Lambda> C<Omega> C<Phi> C<Pi> C<Psi> C<Sigma>
C<Theta> C<Xi>

=item Variants

C<varepsilon> C<varphi> C<vartheta>

=back

=head3 Standard functions

sin cos tan csc sec cot sinh cosh tanh log ln det dim lim mod gcd lcm
min max

=head3 Operation symbols

 Type	  Description					Entity
 +	  +						+
 -	  -						-
 *	  Mid dot					&sdot;
 **	  Star						&Star;
 //	  /						/
 \\	  \						\
 xx	  Cross product					&times;
 -:	  Divided by					&divide;
 @	  Compose functions				&SmallCircle;
 o+	  Circle with plus 				&oplus;
 ox	  Circle with x					&otimes;
 o.	  Circle with dot				&CircleDot;
 sum	  Sum for sub- and superscript			&sum;
 prod	  Product for sub- and superscript		&prod;
 ^^	  Logic "and"					&and;
 ^^^	  Logic "and" for sub- and superscript 		&Wedge;
 vv	  Logic "or"					&or;
 vvv	  Logic "or" for sub- and superscript		&Vee;
 nn	  Logic "intersect"				&cap;
 nnn	  Logic "intersect" for sub- and superscript	&Intersection;
 uu	  Logic "union"					&cup;
 uuu	  Logic "union" for sub- and superscript	&Union;

=head3 Relation symbols

 Type	  Description 					Entity
 =	  =						=
 !=	  Not equals					&ne;
 <	  <						&lt;
 >	  >						&gt;
 <=	  Less than or equal				&le;
 >=	  Greater than or equal				&ge;
 -lt	  Precedes					&Precedes;
 >-	  Succeeds					&Succeeds;
 in	  Element of					&isin;
 !in	  Not an element of				&notin;
 sub	  Subset					&sub;
 sup	  Superset					&sup;
 sube	  Subset or equal				&sube;
 supe	  Superset or equal				&supe;
 -=	  Equivalent					&equiv;
 ~=	  Congruent to					&cong;
 ~~	  Asymptotically equal to			&asymp;
 prop	  Proportional to				&prop;

=head3 Logical symbols

 Type	  Description 					Entity
 and	  And						" and "
 or	  Or						" or "
 not	  Not						&not;
 =>	  Implies					&rArr;
 if	  If						" if "
 iff	  If and only if				&hArr;
 AA	  For all					&forall;
 EE	  There exists					&exist;
 _|_	  Perpendicular, bottom				&perp;
 TT	  Top						&DownTee;
 |--	  Right tee					&RightTee;
 |==	  Double right tee				&DoubleRightTee;

=head3 Grouping brackets

 Type	  Description 					Entity
 (	  (						(
 )	  )						)
 [	  [						[
 ]	  ]						]
 {	  {						{
 }	  }						}
 (:	  Left angle bracket				&lang;
 :)	  Right angle bracket				&rang;
 {:	  Invisible left grouping element
 :}	  Invisible right grouping element

=head3 Miscellaneous symbols

 Type	  Description 					Entity
 int	  Integral					&int;
 oint	  Countour integral				&ContourIntegral;
 del	  Partial derivative				&del;
 grad	  Gradient					&nabla;
 +-	  Plus or minus					&plusmn;
 O/	  Null set					&empty;
 oo       Infinity					&infin;
 aleph	  Hebrew letter aleph				&alefsym;
 &        Ampersand					&amp;
 /_	  Angle						&ang;
 :.	  Therefore					&there4;
 ...	  Ellipsis					...
 cdots	  Three centered dots				&ctdot;
 \<sp>    Non-breaking space (<sp> means space)		&nbsp;
 quad	  Quad space					&nbsp;&nbsp;
 diamond  Diamond					&Diamond;
 square	  Square					&Square;
 |__	  Left floor					&lfloor;
 __|	  Right floor					&rfloor;
 |~	  Left ceiling					&lceil;
 ~|	  Right ceiling					&rceil;
 CC	  Complex numbers				&Copf;
 NN	  Natural numbers				&Nopf;
 QQ	  Rational numbers				&Qopf;
 RR	  Real numbers					&Ropf;
 ZZ	  Integers					&Zopf;

=head3 Arrows

 Type	  Description 					Entity
 uarr	  Up arrow					&uarr;
 darr	  Down arrow					&darr;
 rarr	  Right arrow					&rarr;
 ->	  Right arrow					&rarr;
 larr	  Left arrow					&larr;
 harr     Horizontal (two-way) arrow			&harr;
 rArr	  Right double arrow				&rArr;
 lArr	  Left double arrow				&lArr;
 hArr	  Horizontal double arrow			&hArr;

=head3 Accents

 Type	 Description	     Output
 hat x	 Hat over x	     <mover><mi>x</mi><mo>^</mo></mover>
 bar x	 Bar over x	     <mover><mi>x</mi><mo>&macr;</mo></mover>
 ul x	 Underbar under x    <munder><mi>x</mi><mo>&UnderBar;</mo></munder>
 vec x	 Right arrow over x  <mover><mi>x</mi><mo>&rarr;</mo><mover>
 dot x	 Dot over x	     <mover><mi>x</mi><mo>.</mo><mover>
 ddot x	 Double dot over x   <mover><mi>x</mi><mo>..</mo><mover>

=head3 Font commands

 Type	  Description
 bb A	  Bold A
 bbb A	  Double-struck A
 cc A	  Calligraphic (script) A
 tt A	  Teletype (monospace) A
 fr A	  Fraktur A
 sf A	  Sans-serif A

=head3 Defining new commands and symbols

It is possible to define new commands and symbols using the
'newcommand' and 'newsymbol' binary operators.  The former defines a
macro that gets expanded and reparsed as ASCIIMathML and the latter
defines a constant that gets used as a math operator (C<< <mo> >>)
element.  Both of the arguments must be text, optionally enclosed in
grouping operators.  The 'newsymbol' operator also allows the
second argument to be a group of two text strings where the first is
the mathml operator and the second is the latex code to be output.

For example, 'newcommand "DDX" "{:d/dx:}"' would define a new command
'DDX'.  It could then be invoked like 'DDXf(x)', which would
expand to '{:d/dx:}f(x)'.  The text 'newsymbol{"!le"}{"&#x2270;"}'
could be used to create a symbol you could invoke with '!le', as in 'a
!le b'.
 
=head2 Attributes for <math>

=over 4

=item C<title>

The title attribute for the element, if specified.  In many browsers,
this string will appear if you hover over the MathML markup.

=item C<id>

The id attribute for the element, if specified.  

=item C<class>

The class attribute for the element, if specified.

=back

=head2 Attributes for <mstyle>

=over 4

=item C<displaystyle>

The displaystyle attribute for the element, if specified.  One of the
values "true" or "false".  If the displaystyle is false, then fractions
are represented with a smaller font size and the placement of
subscripts and superscripts of sums and integrals changes.

=item C<mathvariant>

The mathvariant attribute for the element, if specified. One of the
values "normal", "bold", "italic", "bold-italic", "double-struck",
"bold-fraktur", "script", "bold-script", "fraktur", "sans-serif",
"bold-sans-serif", "sans-serif-italic", "sans-serif-bold-italic", or
"monospace".

=item C<mathsize>

The mathsize attribute for the element, if specified. Either "small",
"normal" or "big", or of the form "number v-unit".

=item C<mathfamily>

A string representing the font family.

=item C<mathcolor>

The mathcolor attribute for the element, if specified. It be in one of
the forms "#rgb" or "#rrggbb", or should be an html-color-name.

=item C<mathbackground>

The mathbackground attribute for the element, if specified. It should
be in one of the forms "#rgb" or "#rrggbb", or an html-color-name, or
the keyword "transparent".


=head1 METHODS

=head2 C<Text::ASCIIMathML>

=head3 C<TextToMathML($text, [$math_attr], [$mstyle_attr])>

Converts C<$text> to a MathML string. If the optional C<$math_attr>
argument is provided, it should be a reference to a hash of
attribute/value pairs for the C< <math> > node.  If the optional
C<$mstyle_attr> argument is provided, it should be a reference to a
hash of attribute/value pairs for the C< <mstyle> > node.

=head3 C<TextToMathMLTree($text, [$math_attr], [$mstyle_attr])>

Like C<TextToMathMLTree> except that instead of returning a string, it
returns a C<Text::ASCIIMathML::Node> representing the parsed MathML
structure.  

=head2 C<Text::ASCIIMathML::Node>

=head3 C<text>

Returns a MathML string representing the parsed MathML structure
encoded by the C<Text::ASCIIMathML::Node>.

=head3 C<latex>

Returns a LaTeX string representing the parsed MathML structure
encoded by the C<Text::ASCIIMathML::Node>. 

=head1 BUGS AND SUGGESTIONS

If you find bugs, think of anything that could improve Text::ASCIIMathML
or have any questions related to it, feel free to contact the author.

=head1 AUTHOR

Mark Nodine   <mnodine@alum.mit.edu>

=head1 SEE ALSO

 MathML::Entities, 
 <http://www1.chapman.edu/~jipsen/mathml/asciimathsyntax.xml>

=head1 ACKNOWLEDGEMENTS

This Perl module has been created by modifying Peter Jipsen's
ASCIIMathML.js script. He deserves full credit for the original
implementation; any bugs have probably been introduced by me.

=head1 COPYRIGHT

The Text::ASCIIMathML module is copyright (c) 2006 Mark Nodine,
USA. All rights reserved.

You may use and distribute them under the terms of either the GNU
General Public License or the Artistic License, as specified in the
Perl README file.

=cut

use strict;
use warnings;

our $VERSION = '0.81';

# Creates a new Text::ASCIIMathML parser object
sub new {
    my ($class) = @_;
    return bless {}, $class;
}

# Sets an attribute to a given value
# Arguments: Attribute name, attribute value
# Returns:   None
# Supported attributes:
#            ForMoz       Boolean to optimize for Netscape/Mozilla/Firefox
sub SetAttribute : method {
    my ($self, $attr, $val) = @_;
    $self->{attr}{$attr} = $val;
}

# Converts an AsciiMathML string to a MathML one
# Arguments: AsciiMathML string, 
#            optional ref to array of attribute/value pairs for math node,
#            optional ref to array of attribute/value pairs for mstyle node
# Returns:   MathML string
sub TextToMathML : method {
    my $tree = TextToMathMLTree(@_);
    return $tree ? $tree->text : '';
}

# Converts an AsciiMathML string to a tree of MathML nodes
# Arguments: AsciiMathML string, 
#            optional ref to array of attribute/value pairs for math node,
#            optional ref to array of attribute/value pairs for mstyle node
# Returns:   top Text::ASCIIMathML::Node object or undefined
sub TextToMathMLTree : method {
    my ($self, $expr, $mathAttr, $mstyleAttr) = @_;
    $expr = '' unless defined $expr;
    my $mstyle = $self->_createElementMathML('mstyle');
    $mstyle->setAttribute
	(ref $mstyleAttr eq 'ARRAY' ? @$mstyleAttr : %$mstyleAttr)
	if $mstyleAttr;
    $self->{nestingDepth} = 0;
    $expr =~ s/^\s+//;
    $mstyle->appendChild(($self->_parseExpr($expr, 0))[0]);
    return unless $mstyle->childNodes > 0;
    my $math = $self->_createMmlNode('math', $mstyle);
    $expr =~ s/\n\s*//g;
    $math->setAttribute(ref $mathAttr eq 'ARRAY' ? @$mathAttr : %$mathAttr)
	if $mathAttr;
    
    return $math;
}



# Creates an Text::ASCIIMathML::Node object with no tag
# Arguments: None
# Returns:   node object
sub _createDocumentFragment : method {
    my ($self) = @_;
    return Text::ASCIIMathML::Node->new($self);
}

# Creates an Text::ASCIIMathML::Node object
# Arguments: tag
# Returns:   node object
sub _createElementMathML : method {
    my ($self, $t) = @_;
    return Text::ASCIIMathML::Node->new($self, $t);
}

# Creates an Text::ASCIIMathML::Node object and appends a node as a child
# Arguments: tag, node
# Returns:   node object
sub _createMmlNode : method {
    my ($self, $t, $obj) = @_;
    my $node = Text::ASCIIMathML::Node->new($self, $t);
    $node->appendChild($obj);
    return $node;
}

# Creates an Text::ASCIIMathML::Node text object with the given text
# Arguments: text
# Returns:   node object
sub _createTextNode : method {
    my ($self, $text) = @_;
    return Text::ASCIIMathML::Node->newText ($self, $text);
}

# Finds maximal initial substring of str that appears in names
# return null if there is none
# Arguments: string
# Returns:   matched input, entry from AMSymbol (if any)
sub _getSymbol : method {
    my $self = shift;
    my ($input, $symbol) = $self->_getSymbol_(@_);
    $self->{previousSymbol} = $symbol->{ttype} if $symbol;
    return $input, $symbol;
}

BEGIN {
# character lists for Mozilla/Netscape fonts
my $AMcal = [0xEF35,0x212C,0xEF36,0xEF37,0x2130,0x2131,0xEF38,0x210B,0x2110,0xEF39,0xEF3A,0x2112,0x2133,0xEF3B,0xEF3C,0xEF3D,0xEF3E,0x211B,0xEF3F,0xEF40,0xEF41,0xEF42,0xEF43,0xEF44,0xEF45,0xEF46];
my $AMfrk = [0xEF5D,0xEF5E,0x212D,0xEF5F,0xEF60,0xEF61,0xEF62,0x210C,0x2111,0xEF63,0xEF64,0xEF65,0xEF66,0xEF67,0xEF68,0xEF69,0xEF6A,0x211C,0xEF6B,0xEF6C,0xEF6D,0xEF6E,0xEF6F,0xEF70,0xEF71,0x2128];
my $AMbbb = [0xEF8C,0xEF8D,0x2102,0xEF8E,0xEF8F,0xEF90,0xEF91,0x210D,0xEF92,0xEF93,0xEF94,0xEF95,0xEF96,0x2115,0xEF97,0x2119,0x211A,0x211D,0xEF98,0xEF99,0xEF9A,0xEF9B,0xEF9C,0xEF9D,0xEF9E,0x2124];

# Create closure for static variables
my %AMSymbol = (
"sqrt" => { tag=>"msqrt", output=>"sqrt", tex=>'', ttype=>"UNARY" },
"root" => { tag=>"mroot", output=>"root", tex=>'', ttype=>"BINARY" },
"frac" => { tag=>"mfrac", output=>"/",    tex=>'', ttype=>"BINARY" },
"/" => { tag=>"mfrac", output=>"/",    tex=>'', ttype=>"INFIX" },
"stackrel" => { tag=>"mover", output=>"stackrel", tex=>'', ttype=>"BINARY" },
"_" => { tag=>"msub",  output=>"_",    tex=>'', ttype=>"INFIX" },
"^" => { tag=>"msup",  output=>"^",    tex=>'', ttype=>"INFIX" },
"text" => { tag=>"mtext", output=>"text", tex=>'', ttype=>"TEXT" },
"mbox" => { tag=>"mtext", output=>"mbox", tex=>'', ttype=>"TEXT" },
"\"" => { tag=>"mtext", output=>"mbox", tex=>'', ttype=>"TEXT" },

# new for perl
"newcommand" => { ttype=>"BINARY"},
"newsymbol" => { ttype=>"BINARY" },

# some greek symbols
"alpha" => { tag=>"mi", output=>"&#x03B1;", tex=>'', ttype=>"CONST" },
"beta" => { tag=>"mi", output=>"&#x03B2;", tex=>'', ttype=>"CONST" },
"chi" => { tag=>"mi", output=>"&#x03C7;", tex=>'', ttype=>"CONST" },
"delta" => { tag=>"mi", output=>"&#x03B4;", tex=>'', ttype=>"CONST" },
"Delta" => { tag=>"mo", output=>"&#x0394;", tex=>'', ttype=>"CONST" },
"epsi" => { tag=>"mi", output=>"&#x03B5;", tex=>"epsilon", ttype=>"CONST" },
"varepsilon" => { tag=>"mi", output=>"&#x025B;", tex=>'', ttype=>"CONST" },
"eta" => { tag=>"mi", output=>"&#x03B7;", tex=>'', ttype=>"CONST" },
"gamma" => { tag=>"mi", output=>"&#x03B3;", tex=>'', ttype=>"CONST" },
"Gamma" => { tag=>"mo", output=>"&#x0393;", tex=>'', ttype=>"CONST" },
"iota" => { tag=>"mi", output=>"&#x03B9;", tex=>'', ttype=>"CONST" },
"kappa" => { tag=>"mi", output=>"&#x03BA;", tex=>'', ttype=>"CONST" },
"lambda" => { tag=>"mi", output=>"&#x03BB;", tex=>'', ttype=>"CONST" },
"Lambda" => { tag=>"mo", output=>"&#x039B;", tex=>'', ttype=>"CONST" },
"mu" => { tag=>"mi", output=>"&#x03BC;", tex=>'', ttype=>"CONST" },
"nu" => { tag=>"mi", output=>"&#x03BD;", tex=>'', ttype=>"CONST" },
"omega" => { tag=>"mi", output=>"&#x03C9;", tex=>'', ttype=>"CONST" },
"Omega" => { tag=>"mo", output=>"&#x03A9;", tex=>'', ttype=>"CONST" },
"phi" => { tag=>"mi", output=>"&#x03D5;", tex=>'', ttype=>"CONST" },
"varphi" => { tag=>"mi", output=>"&#x03C6;", tex=>'', ttype=>"CONST" },
"Phi" => { tag=>"mo", output=>"&#x03A6;", tex=>'', ttype=>"CONST" },
"pi" => { tag=>"mi", output=>"&#x03C0;", tex=>'', ttype=>"CONST" },
"Pi" => { tag=>"mo", output=>"&#x03A0;", tex=>'', ttype=>"CONST" },
"psi" => { tag=>"mi", output=>"&#x03C8;", tex=>'', ttype=>"CONST" },
"Psi" => { tag=>"mi", output=>"&#x03A8;", tex=>'', ttype=>"CONST" },
"rho" => { tag=>"mi", output=>"&#x03C1;", tex=>'', ttype=>"CONST" },
"sigma" => { tag=>"mi", output=>"&#x03C3;", tex=>'', ttype=>"CONST" },
"Sigma" => { tag=>"mo", output=>"&#x03A3;", tex=>'', ttype=>"CONST" },
"tau" => { tag=>"mi", output=>"&#x03C4;", tex=>'', ttype=>"CONST" },
"theta" => { tag=>"mi", output=>"&#x03B8;", tex=>'', ttype=>"CONST" },
"vartheta" => { tag=>"mi", output=>"&#x03D1;", tex=>'', ttype=>"CONST" },
"Theta" => { tag=>"mo", output=>"&#x0398;", tex=>'', ttype=>"CONST" },
"upsilon" => { tag=>"mi", output=>"&#x03C5;", tex=>'', ttype=>"CONST" },
"xi" => { tag=>"mi", output=>"&#x03BE;", tex=>'', ttype=>"CONST" },
"Xi" => { tag=>"mo", output=>"&#x039E;", tex=>'', ttype=>"CONST" },
"zeta" => { tag=>"mi", output=>"&#x03B6;", tex=>'', ttype=>"CONST" },

# binary operation symbols
"*" => { tag=>"mo", output=>"&#x22C5;", tex=>"cdot", ttype=>"CONST" },
"**" => { tag=>"mo", output=>"&#x22C6;", tex=>"star", ttype=>"CONST" },
"//" => { tag=>"mo", output=>"/",      tex=>'', ttype=>"CONST" },
"\\\\" => { tag=>"mo", output=>"\\",   tex=>"backslash", ttype=>"CONST" },
"setminus" => { tag=>"mo", output=>"\\", tex=>'', ttype=>"CONST" },
"xx" => { tag=>"mo", output=>"&#x00D7;", tex=>"times", ttype=>"CONST" },
"-:" => { tag=>"mo", output=>"&#x00F7;", tex=>"div", ttype=>"CONST" },
"@" => { tag=>"mo", output=>"&#x2218;", tex=>"circ", ttype=>"CONST" },
"o+" => { tag=>"mo", output=>"&#x2295;", tex=>"oplus", ttype=>"CONST" },
"ox" => { tag=>"mo", output=>"&#x2297;", tex=>"otimes", ttype=>"CONST" },
"o." => { tag=>"mo", output=>"&#x2299;", tex=>"odot", ttype=>"CONST" },
"sum" => { tag=>"mo", output=>"&#x2211;", tex=>'', ttype=>"UNDEROVER" },
"prod" => { tag=>"mo", output=>"&#x220F;", tex=>'', ttype=>"UNDEROVER" },
"^^" => { tag=>"mo", output=>"&#x2227;", tex=>"wedge", ttype=>"CONST" },
"^^^" => { tag=>"mo", output=>"&#x22C0;", tex=>"bigwedge", ttype=>"UNDEROVER" },
"vv" => { tag=>"mo", output=>"&#x2228;", tex=>"vee", ttype=>"CONST" },
"vvv" => { tag=>"mo", output=>"&#x22C1;", tex=>"bigvee", ttype=>"UNDEROVER" },
"nn" => { tag=>"mo", output=>"&#x2229;", tex=>"cap", ttype=>"CONST" },
"nnn" => { tag=>"mo", output=>"&#x22C2;", tex=>"bigcap", ttype=>"UNDEROVER" },
"uu" => { tag=>"mo", output=>"&#x222A;", tex=>"cup", ttype=>"CONST" },
"uuu" => { tag=>"mo", output=>"&#x22C3;", tex=>"bigcup", ttype=>"UNDEROVER" },

# binary relation symbols
"!=" => { tag=>"mo", output=>"&#x2260;", tex=>"ne", ttype=>"CONST" },
":=" => { tag=>"mo", output=>":=",     tex=>'', ttype=>"CONST" },
#"lt" => { tag=>"mo", output=>"<",      tex=>'', ttype=>"CONST" },
"lt" => { tag=>"mo", output=>"&lt;",      tex=>'', ttype=>"CONST" },
"<=" => { tag=>"mo", output=>"&#x2264;", tex=>"le", ttype=>"CONST" },
"lt=" => { tag=>"mo", output=>"&#x2264;", tex=>"leq", ttype=>"CONST", latex=>1 },
">=" => { tag=>"mo", output=>"&#x2265;", tex=>"ge", ttype=>"CONST" },
"geq" => { tag=>"mo", output=>"&#x2265;", tex=>'', ttype=>"CONST", latex=>1 },
"-<" => { tag=>"mo", output=>"&#x227A;", tex=>"prec", ttype=>"CONST", latex=>1 },
"-lt" => { tag=>"mo", output=>"&#x227A;", tex=>'', ttype=>"CONST" },
">-" => { tag=>"mo", output=>"&#x227B;", tex=>"succ", ttype=>"CONST" },
"in" => { tag=>"mo", output=>"&#x2208;", tex=>'', ttype=>"CONST" },
"!in" => { tag=>"mo", output=>"&#x2209;", tex=>"notin", ttype=>"CONST" },
"sub" => { tag=>"mo", output=>"&#x2282;", tex=>"subset", ttype=>"CONST" },
"sup" => { tag=>"mo", output=>"&#x2283;", tex=>"supset", ttype=>"CONST" },
"sube" => { tag=>"mo", output=>"&#x2286;", tex=>"subseteq", ttype=>"CONST" },
"supe" => { tag=>"mo", output=>"&#x2287;", tex=>"supseteq", ttype=>"CONST" },
"-=" => { tag=>"mo", output=>"&#x2261;", tex=>"equiv", ttype=>"CONST" },
"~=" => { tag=>"mo", output=>"&#x2245;", tex=>"cong", ttype=>"CONST" },
"~~" => { tag=>"mo", output=>"&#x2248;", tex=>"approx", ttype=>"CONST" },
"prop" => { tag=>"mo", output=>"&#x221D;", tex=>"propto", ttype=>"CONST" },

# new for perl
"<" => { tag=>"mo", output=>"&lt;",      tex=>'', ttype=>"CONST" },
"gt" => { tag=>"mo", output=>"&gt;",      tex=>'', ttype=>"CONST" },
">" => { tag=>"mo", output=>"&gt;",      tex=>'', ttype=>"CONST" },
"\\!" => { tag=>"", output=>'',   tex=>'', ttype=>"NOP" },


# logical symbols
"and" => { tag=>"mtext", output=>"and", tex=>'', ttype=>"SPACE" },
"or" => { tag=>"mtext", output=>"or",  tex=>'', ttype=>"SPACE" },
"not" => { tag=>"mo", output=>"&#x00AC;", tex=>"neg", ttype=>"CONST" },
"=>" => { tag=>"mo", output=>"&#x21D2;", tex=>"implies", ttype=>"CONST" },
"if" => { tag=>"mo", output=>"if",     tex=>'if', ttype=>"SPACE" },
"<=>" => { tag=>"mo", output=>"&#x21D4;", tex=>"iff", ttype=>"CONST" },
"AA" => { tag=>"mo", output=>"&#x2200;", tex=>"forall", ttype=>"CONST" },
"EE" => { tag=>"mo", output=>"&#x2203;", tex=>"exists", ttype=>"CONST" },
"_|_" => { tag=>"mo", output=>"&#x22A5;", tex=>"bot", ttype=>"CONST" },
"TT" => { tag=>"mo", output=>"&#x22A4;", tex=>"top", ttype=>"CONST" },
"|--" => { tag=>"mo", output=>"&#x22A2;", tex=>"vdash", ttype=>"CONST" },
"|==" => { tag=>"mo", output=>"&#x22A8;", tex=>"models", ttype=>"CONST" },

# grouping brackets
"(" => { tag=>"mo", output=>"(", tex=>'', ttype=>"LEFTBRACKET" },
")" => { tag=>"mo", output=>")", tex=>'', ttype=>"RIGHTBRACKET" },
"[" => { tag=>"mo", output=>"[", tex=>'', ttype=>"LEFTBRACKET" },
"]" => { tag=>"mo", output=>"]", tex=>'', ttype=>"RIGHTBRACKET" },
"{" => { tag=>"mo", output=>"{", tex=>'', ttype=>"LEFTBRACKET" },
"}" => { tag=>"mo", output=>"}", tex=>'', ttype=>"RIGHTBRACKET" },
"|" => { tag=>"mo", output=>"|", tex=>'', ttype=>"LEFTRIGHT" },
# {input:"||", tag:"mo", output:"||", tex:null, ttype:LEFTRIGHT},
"(:" => { tag=>"mo", output=>"&#x2329;", tex=>"langle", ttype=>"LEFTBRACKET" },
":)" => { tag=>"mo", output=>"&#x232A;", tex=>"rangle", ttype=>"RIGHTBRACKET" },
"<<" => { tag=>"mo", output=>"&#x2329;", tex=>'langle', ttype=>"LEFTBRACKET" },
">>" => { tag=>"mo", output=>"&#x232A;", tex=>'rangle', ttype=>"RIGHTBRACKET" },
"{:" => { tag=>"mo", output=>"{:", tex=>'', ttype=>"LEFTBRACKET", invisible=>"true" },
":}" => { tag=>"mo", output=>":}", tex=>'', ttype=>"RIGHTBRACKET", invisible=>"true" },

# miscellaneous symbols
"int" => { tag=>"mo", output=>"&#x222B;", tex=>'', ttype=>"CONST" },
"dx" => { tag=>"mi", output=>"{:d x:}", tex=>'', ttype=>"DEFINITION" },
"dy" => { tag=>"mi", output=>"{:d y:}", tex=>'', ttype=>"DEFINITION" },
"dz" => { tag=>"mi", output=>"{:d z:}", tex=>'', ttype=>"DEFINITION" },
"dt" => { tag=>"mi", output=>"{:d t:}", tex=>'', ttype=>"DEFINITION" },
"oint" => { tag=>"mo", output=>"&#x222E;", tex=>'', ttype=>"CONST" },
"del" => { tag=>"mo", output=>"&#x2202;", tex=>"partial", ttype=>"CONST" },
"grad" => { tag=>"mo", output=>"&#x2207;", tex=>"nabla", ttype=>"CONST" },
"+-" => { tag=>"mo", output=>"&#x00B1;", tex=>"pm", ttype=>"CONST" },
"O/" => { tag=>"mo", output=>"&#x2205;", tex=>"emptyset", ttype=>"CONST" },
"oo" => { tag=>"mo", output=>"&#x221E;", tex=>"infty", ttype=>"CONST" },
"aleph" => { tag=>"mo", output=>"&#x2135;", tex=>'', ttype=>"CONST" },
"..." => { tag=>"mo", output=>"...",    tex=>"ldots", ttype=>"CONST" },
":." => { tag=>"mo", output=>"&#x2234;",  tex=>"therefore", ttype=>"CONST" },
"/_" => { tag=>"mo", output=>"&#x2220;",  tex=>"angle", ttype=>"CONST" },
"&"  => { tag=>"mo", output=>"&amp;",     tex=>'\&',    ttype=>"CONST" },
"\\ " => { tag=>"mo", output=>"&#x00A0;", tex=>'\,', ttype=>"CONST" },
"quad" => { tag=>"mo", output=>"&#x00A0;&#x00A0;", tex=>'', ttype=>"CONST" },
"qquad" => { tag=>"mo", output=>"&#x00A0;&#x00A0;&#x00A0;&#x00A0;", tex=>'', ttype=>"CONST" },
"cdots" => { tag=>"mo", output=>"&#x22EF;", tex=>'', ttype=>"CONST" },
"vdots" => { tag=>"mo", output=>"&#x22EE;", tex=>'', ttype=>"CONST" },
"ddots" => { tag=>"mo", output=>"&#x22F1;", tex=>'', ttype=>"CONST" },
"diamond" => { tag=>"mo", output=>"&#x22C4;", tex=>'', ttype=>"CONST" },
"square" => { tag=>"mo", output=>"&#x25A1;", tex=>'', ttype=>"CONST" },
"|__" => { tag=>"mo", output=>"&#x230A;",  tex=>"lfloor", ttype=>"CONST" },
"__|" => { tag=>"mo", output=>"&#x230B;",  tex=>"rfloor", ttype=>"CONST" },
"|~" => { tag=>"mo", output=>"&#x2308;",  tex=>"lceil", ttype=>"CONST" },
"~|" => { tag=>"mo", output=>"&#x2309;",  tex=>"rceil", ttype=>"CONST" },
"CC" => { tag=>"mo", output=>"&#x2102;", tex=>'', ttype=>"CONST" },
"NN" => { tag=>"mo", output=>"&#x2115;", tex=>'', ttype=>"CONST" },
"QQ" => { tag=>"mo", output=>"&#x211A;", tex=>'', ttype=>"CONST" },
"RR" => { tag=>"mo", output=>"&#x211D;", tex=>'', ttype=>"CONST" },
"ZZ" => { tag=>"mo", output=>"&#x2124;", tex=>'', ttype=>"CONST" },
"f" => { tag=>"mi", output=>"f",      tex=>'', ttype=>"UNARY", func=>"true" },
"g" => { tag=>"mi", output=>"g",      tex=>'', ttype=>"UNARY", func=>"true" },

# standard functions
"lim" => { tag=>"mo", output=>"lim", tex=>'', ttype=>"UNDEROVER" },
"Lim" => { tag=>"mo", output=>"Lim", tex=>'', ttype=>"UNDEROVER" },
"sin" => { tag=>"mo", output=>"sin", tex=>'', ttype=>"UNARY", func=>"true" },
"cos" => { tag=>"mo", output=>"cos", tex=>'', ttype=>"UNARY", func=>"true" },
"tan" => { tag=>"mo", output=>"tan", tex=>'', ttype=>"UNARY", func=>"true" },
"sinh" => { tag=>"mo", output=>"sinh", tex=>'', ttype=>"UNARY", func=>"true" },
"cosh" => { tag=>"mo", output=>"cosh", tex=>'', ttype=>"UNARY", func=>"true" },
"tanh" => { tag=>"mo", output=>"tanh", tex=>'', ttype=>"UNARY", func=>"true" },
"cot" => { tag=>"mo", output=>"cot", tex=>'', ttype=>"UNARY", func=>"true" },
"sec" => { tag=>"mo", output=>"sec", tex=>'', ttype=>"UNARY", func=>"true" },
"csc" => { tag=>"mo", output=>"csc", tex=>'', ttype=>"UNARY", func=>"true" },
"log" => { tag=>"mo", output=>"log", tex=>'', ttype=>"UNARY", func=>"true" },
"ln" => { tag=>"mo", output=>"ln",  tex=>'', ttype=>"UNARY", func=>"true" },
"det" => { tag=>"mo", output=>"det", tex=>'', ttype=>"UNARY", func=>"true" },
"dim" => { tag=>"mo", output=>"dim", tex=>'', ttype=>"CONST" },
"mod" => { tag=>"mo", output=>"mod", tex=>'', ttype=>"CONST" },
"gcd" => { tag=>"mo", output=>"gcd", tex=>'', ttype=>"UNARY", func=>"true" },
"lcm" => { tag=>"mo", output=>"lcm", tex=>'', ttype=>"UNARY", func=>"true" },
"lub" => { tag=>"mo", output=>"lub", tex=>'', ttype=>"CONST" },
"glb" => { tag=>"mo", output=>"glb", tex=>'', ttype=>"CONST" },
"min" => { tag=>"mo", output=>"min", tex=>'', ttype=>"UNDEROVER" },
"max" => { tag=>"mo", output=>"max", tex=>'', ttype=>"UNDEROVER" },

# arrows
"uarr" => { tag=>"mo", output=>"&#x2191;", tex=>"uparrow", ttype=>"CONST" },
"darr" => { tag=>"mo", output=>"&#x2193;", tex=>"downarrow", ttype=>"CONST" },
"rarr" => { tag=>"mo", output=>"&#x2192;", tex=>"rightarrow", ttype=>"CONST" },
"->" => { tag=>"mo", output=>"&#x2192;", tex=>"to", ttype=>"CONST", latex=>1 },
"|->" => { tag=>"mo", output=>"&#x21A6;", tex=>"mapsto", ttype=>"CONST" },
"larr" => { tag=>"mo", output=>"&#x2190;", tex=>"leftarrow", ttype=>"CONST" },
"harr" => { tag=>"mo", output=>"&#x2194;", tex=>"leftrightarrow", ttype=>"CONST" },
"rArr" => { tag=>"mo", output=>"&#x21D2;", tex=>"Rightarrow", ttype=>"CONST", latex=>1 },
"lArr" => { tag=>"mo", output=>"&#x21D0;", tex=>"Leftarrow", ttype=>"CONST" },
"hArr" => { tag=>"mo", output=>"&#x21D4;", tex=>"Leftrightarrow", ttype=>"CONST", latex=>1 },

# commands with argument

"hat" => { tag=>"mover", output=>"^", tex=>'', ttype=>"UNARY", acc=>"true" },
"bar" => { tag=>"mover", output=>"&#x00AF;", tex=>"overline", ttype=>"UNARY", acc=>"true" },
"vec" => { tag=>"mover", output=>"&#x2192;", tex=>'', ttype=>"UNARY", acc=>"true" },
"dot" => { tag=>"mover", output=>".",      tex=>'', ttype=>"UNARY", acc=>"true" },
"ddot" => { tag=>"mover", output=>"..",    tex=>'', ttype=>"UNARY", acc=>"true" },
"ul" => { tag=>"munder", output=>"&#x0332;", tex=>"underline", ttype=>"UNARY", acc=>"true" },

"bb" => { tag=>"mstyle", atname=>"fontweight", atval=>"bold", output=>"bb", tex=>'', ttype=>"UNARY" },
"mathbf" => { tag=>"mstyle", atname=>"fontweight", atval=>"bold", output=>"mathbf", tex=>'', ttype=>"UNARY" },
"sf" => { tag=>"mstyle", atname=>"fontfamily", atval=>"sans-serif", output=>"sf", tex=>'', ttype=>"UNARY" },
"mathsf" => { tag=>"mstyle", atname=>"fontfamily", atval=>"sans-serif", output=>"mathsf", tex=>'', ttype=>"UNARY" },
"bbb" => { tag=>"mstyle", atname=>"mathvariant", atval=>"double-struck", output=>"bbb", tex=>'', ttype=>"UNARY", codes=>$AMbbb },
"mathbb" => { tag=>"mstyle", atname=>"mathvariant", atval=>"double-struck", output=>"mathbb", tex=>'', ttype=>"UNARY", codes=>$AMbbb },
"cc" => { tag=>"mstyle", atname=>"mathvariant", atval=>"script", output=>"cc", tex=>'', ttype=>"UNARY", codes=>$AMcal },
"mathcal" => { tag=>"mstyle", atname=>"mathvariant", atval=>"script", output=>"mathcal", tex=>'', ttype=>"UNARY", codes=>$AMcal },
"tt" => { tag=>"mstyle", atname=>"fontfamily", atval=>"monospace", output=>"tt", tex=>'', ttype=>"UNARY" },
"mathtt" => { tag=>"mstyle", atname=>"fontfamily", atval=>"monospace", output=>"mathtt", tex=>'', ttype=>"UNARY" },
"fr" => { tag=>"mstyle", atname=>"mathvariant", atval=>"fraktur", output=>"fr", tex=>'', ttype=>"UNARY", codes=>$AMfrk },
"mathfrak" => { tag=>"mstyle", atname=>"mathvariant", atval=>"fraktur", output=>"mathfrak", tex=>'', ttype=>"UNARY", codes=>$AMfrk },
);

# Preprocess AMSymbol for lexer regular expression
# Preprocess AMSymbol for tex input
my %AMTexSym = map(($AMSymbol{$_}{tex} || $_, $_),
		   grep($AMSymbol{$_}{tex}, keys %AMSymbol));
my $Ident_RE = join '|', map("\Q$_\E",
			     sort {length($b) - length($a)} (keys %AMSymbol,
							     keys %AMTexSym));

sub _getSymbol_ : method {
    my ($self, $str) = @_;
    for ($str) {
        /^(\d+(\.\d+)?)/ || /^(\.\d+)/
	    and return $1, {tag=>'mn', output=>$1, ttype=>'CONST'};
	$self->{Definition_RE} && /^($self->{Definition_RE})/ and
	    return $1, $self->{Definitions}{$1};
	/^($Ident_RE)/o and
	    return $1,$AMTexSym{$1} ? $AMSymbol{$AMTexSym{$1}} : $AMSymbol{$1};
        /^([A-Za-z])/ and
	    return $1, {tag=>'mi', output=>$1, ttype=>'CONST'};
        /^(.)/ and 
	    return $1 eq '-' && defined $self->{previousSymbol} &&
	    $self->{previousSymbol} eq 'INFIX' ?
	    ($1, {tag=>'mo', output=>$1, ttype=>'UNARY', func=>"true"} ) :
	    ($1, {tag=>'mo', output=>$1, ttype=>'CONST'});
    }
}

# Used so that Text::ASCIIMathML::Node can get access to the symbol table
sub _get_amsymbol_ {
    return \%AMSymbol;
}
}

# Parses an E expression
# Arguments: string to parse, whether to look for a right bracket
# Returns: parsed node (if successful), remaining unparsed string
sub _parseExpr : method {
    my ($self, $str, $rightbracket) = @_;
    my $newFrag = $self->_createDocumentFragment();
    my ($node, $input, $symbol);
    do {
	$str = _removeCharsAndBlanks($str, 0);
	($node, $str) = $self->_parseIexpr($str);
	($input, $symbol) = $self->_getSymbol($str);
	if (defined $symbol && $symbol->{ttype} eq 'INFIX' && $input eq '/') {
	    $str = _removeCharsAndBlanks($str, length $input);
	    my @result = $self->_parseIexpr($str);
	    if ($result[0]) {
		_removeBrackets($result[0]);
	    }
	    else { # show box in place of missing argument
		$result[0] = $self->_createMmlNode
		    ('mo', $self->_createTextNode('&#25A1;'));
	    }
	    $str = $result[1];
	    _removeBrackets($node);
	    $node = $self->_createMmlNode($symbol->{tag}, $node);
	    $node->appendChild($result[0]);
	    $newFrag->appendChild($node);
	    ($input, $symbol) = $self->_getSymbol($str);
	}
	elsif (defined $node) {
	    $newFrag->appendChild($node);
	}
    } while (defined $symbol && ($symbol->{ttype} ne 'RIGHTBRACKET' &&
				 ($symbol->{ttype} ne 'LEFTRIGHT'  ||
				  $rightbracket)
				 || $self->{nestingDepth} == 0) &&
	     $symbol->{output} ne '');
    if (defined $symbol && $symbol->{ttype} =~ /RIGHTBRACKET|LEFTRIGHT/) {
	my @childNodes = $newFrag->childNodes;
	if (@childNodes > 1 &&
	    $childNodes[-1]->nodeName eq 'mrow' &&
	    $childNodes[-2]->nodeName eq 'mo' &&
	    $childNodes[-2]->firstChild->nodeValue eq ',') { # matrix
	    my $right = $childNodes[-1]->lastChild->firstChild->nodeValue;
	    if ($right =~ /[\)\]]/) {
		my $left = $childNodes[-1]->firstChild->firstChild->nodeValue;
		if ("$left$right" =~ /^\(\)$/ && $symbol->{output} ne '}' ||
		    "$left$right" =~ /^\[\]$/) {
		    my @pos;	# positions of commas
		    my $matrix = 1;
		    my $m = @childNodes;
		    for (my $i=0; $matrix && $i < $m; $i += 2) {
			$pos[$i] = [];
			$node = $childNodes[$i];
			$matrix =
			    $node->nodeName eq 'mrow' &&
			    ($i == $m-1 ||
			     $node->nextSibling->nodeName eq 'mo' &&
			     $node->nextSibling->firstChild->nodeValue eq ',')&&
			    $node->firstChild->firstChild->nodeValue eq $left&&
			    $node->lastChild->firstChild->nodeValue eq $right
			    if $matrix;
			if ($matrix) {
			    for (my $j=0; $j<($node->childNodes); $j++) {
				if (($node->childNodes)[$j]->firstChild->
				    nodeValue eq ',') {
				    push @{$pos[$i]}, $j;
				}
			    }
			}
			if ($matrix && $i > 1) {
			    $matrix = @{$pos[$i]} == @{$pos[$i-2]};
			}
		    }
		    if ($matrix) {
			my $table = $self->_createDocumentFragment();
			for (my $i=0; $i<$m; $i += 2) {
			    my $row  = $self->_createDocumentFragment();
			    my $frag = $self->_createDocumentFragment();
			    # <mrow>(-,-,...,-,-)</mrow>
			    $node = $newFrag->firstChild;
			    my $n = $node->childNodes;
			    my $k = 0;
			    $node->removeChild($node->firstChild); # remove (
			    for (my $j=1; $j<$n-1; $j++) {
				if ($k < @{$pos[$i]} && $j == $pos[$i][$k]) {
				    # remove ,
				    $row->appendChild
					($self->_createMmlNode('mtd', $frag));
				    $frag = $self->_createDocumentFragment();
				    $k++;
				}
				else {
				    $frag->appendChild($node->firstChild);
				}
				$node->removeChild($node->firstChild);
			    }
			    $row->appendChild
				($self->_createMmlNode('mtd', $frag));
			    if ($newFrag->childNodes > 2) {
				# remove <mrow>)</mrow>
				$newFrag->removeChild($newFrag->firstChild);
				# remove <mo>,</mo>
				$newFrag->removeChild($newFrag->firstChild);
			    }
			    $table->appendChild
				($self->_createMmlNode('mtr', $row));
			}
			$node = $self->_createMmlNode('mtable', $table);
			$node->setAttribute('columnalign', 'left')
			    if $symbol->{invisible};
			$newFrag->replaceChild($node, $newFrag->firstChild);
		    }
		}
	    }
	}
	$str = _removeCharsAndBlanks($str, length $input);
	if (! $symbol->{invisible}) {
	    $node = $self->_createMmlNode
		('mo', $self->_createTextNode($symbol->{output}));
	    $newFrag->appendChild($node);
	}
    }
    return $newFrag, $str;
}

# Parses an I expression
# Arguments: string to parse
# Returns: parsed node (if successful), remaining unparsed string
sub _parseIexpr : method {
    my ($self, $str) = @_;
    $str = _removeCharsAndBlanks($str, 0);
    my ($in1, $sym1) = $self->_getSymbol($str);
    my $node;
    ($node, $str) = $self->_parseSexpr($str);
    my ($input, $symbol) = $self->_getSymbol($str);
    if (defined $symbol && $symbol->{ttype} eq 'INFIX' && $input ne '/') {
#    if (symbol.input == "/") result = AMparseIexpr(str); else ...
	$str = _removeCharsAndBlanks($str, length $input);
	my @result = $self->_parseSexpr($str);
	if ($result[0]) {
	    _removeBrackets($result[0]);
	}
	else { # show box in place of missing argument
	    $result[0] = $self->_createMmlNode
		('mo', $self->_createTextNode("&#25A1;"));
	}
	$str = $result[1];
	if ($input eq '_') {
	    my ($in2, $sym2) = $self->_getSymbol($str);
	    my $underover = $sym1->{ttype} eq 'UNDEROVER';
	    if ($in2 eq '^') {
		$str = _removeCharsAndBlanks($str, length $in2);
		my @res2 = $self->_parseSexpr($str);
		_removeBrackets($res2[0]);
		$str = $res2[1];
		$node = $self->_createMmlNode
		    ($underover ? 'munderover' : 'msubsup', $node);
		$node->appendChild($result[0]);
		$node->appendChild($res2[0]);
		$node = $self->_createMmlNode('mrow',$node); # so sum does not stretch
	    }
	    else {
		$node = $self->_createMmlNode
		    ($underover ? 'munder' : 'msub', $node);
		$node->appendChild($result[0]);
	    }
	}
	elsif ($input eq '^') {
	    my ($in2, $sym2) = $self->_getSymbol($str);
	    my $underover = $sym1->{ttype} eq 'UNDEROVER';
	    if ($in2 eq '_') {
		$str = _removeCharsAndBlanks($str, length $in2);
		my @res2 = $self->_parseSexpr($str);
		_removeBrackets($res2[0]);
		$str = $res2[1];
		$node = $self->_createMmlNode
		    ($underover ? 'munderover' : 'msubsup', $node);
		$node->appendChild($res2[0]);
		$node->appendChild($result[0]);
		$node = $self->_createMmlNode('mrow',$node); # so sum does not stretch
	    }
	    else {
		$node = $self->_createMmlNode
		    ($underover ? 'mover' : 'msup', $node);
		$node->appendChild($result[0]);
	    }
	}
	else {
	    $node = $self->_createMmlNode($symbol->{tag}, $node);
	    $node->appendChild($result[0]);
	}
    }
    return $node, $str;
}

# Parses an S expression
# Arguments: string to parse
# Returns: parsed node (if successful), remaining unparsed string
sub _parseSexpr : method {
    my ($self, $str) = @_;
    my $newFrag = $self->_createDocumentFragment();
    $str = _removeCharsAndBlanks($str, 0);
    my ($input, $symbol) = $self->_getSymbol($str);
    return (undef, $str)
	if ! defined $symbol ||
	$symbol->{ttype} eq 'RIGHTBRACKET' && $self->{nestingDepth} > 0;
    if ($symbol->{ttype} eq 'DEFINITION') {
	$str = $symbol->{output} . _removeCharsAndBlanks($str, length $input);
	($input, $symbol) = $self->_getSymbol($str);
    }
    my $ttype = $symbol->{ttype};
    if ($ttype =~ /UNDEROVER|CONST/) {
	$str = _removeCharsAndBlanks($str, length $input);
	return
	    $self->_createMmlNode($symbol->{tag},
				  $self->_createTextNode($symbol->{output})),
	    $str;
    }
    if ($ttype eq 'LEFTBRACKET') {
	$self->{nestingDepth}++;
	$str = _removeCharsAndBlanks($str, length $input);
	my @result = $self->_parseExpr($str, 1);
	$self->{nestingDepth}--;
	my $node;
	if ($symbol->{invisible}) {
	    $node = $self->_createMmlNode('mrow', $result[0]);
	}
	else {
	    $node = $self->_createMmlNode
		('mo', $self->_createTextNode($symbol->{output}));
	    $node = $self->_createMmlNode('mrow', $node);
	    $node->appendChild($result[0]);
	}
	return $node, $result[1];
    }
    if ($ttype eq 'TEXT') {
	$str = _removeCharsAndBlanks($str, length $input) unless $input eq '"';
	my $st;
	($input, $st) = ($1, $2)
	    if $str =~ /^(\"()\")/ || $str =~ /^(\"((?:\\\\|\\\"|.)+?)\")/;
	($input, $st) = ($1, $2)
	    if ($str =~ /^(\((.*?)\))/ ||
		$str =~ /^(\[(.*?)\])/ ||
		$str =~ /^(\{(.*?)\})/);
	($input, $st) = ($str) x 2 unless defined $st;
	if (substr($st, 0, 1) eq ' ') {
	    my $node = $self->_createElementMathML('mspace');
	    $node->setAttribute(width=>'1ex');
	    $newFrag->appendChild($node);
	}
	$newFrag->appendChild
	    ($self->_createMmlNode($symbol->{tag},
				   $self->_createTextNode($st)));
	if (substr($st, -1) eq ' ') {
	    my $node = $self->_createElementMathML('mspace');
	    $node->setAttribute(width=>'1ex');
	    $newFrag->appendChild($node);
	}
	$str = _removeCharsAndBlanks($str, length $input);
	return $self->_createMmlNode('mrow', $newFrag), $str;
    }
    if ($ttype eq 'UNARY') {
	$str = _removeCharsAndBlanks($str, length $input);
	my @result = $self->_parseSexpr($str);
	return ($self->_createMmlNode
		($symbol->{tag},
		 $self->_createTextNode($symbol->{output})), $str)
	    if ! defined $result[0];
	if ($symbol->{func}) {
	    return ($self->_createMmlNode
		    ($symbol->{tag},
		     $self->_createTextNode($symbol->{output})), $str)
		if $str =~ m!^[\^_/|]!;
	    my $node = $self->_createMmlNode
		('mrow', $self->_createMmlNode
		 ($symbol->{tag}, $self->_createTextNode($symbol->{output})));
	    $node->appendChild($result[0]);
	    return $node, $result[1];
	}
	_removeBrackets($result[0]);
	if ($symbol->{acc}) {	# accent
	    my $node = $self->_createMmlNode($symbol->{tag}, $result[0]);
	    $node->appendChild
		($self->_createMmlNode
		 ('mo', $self->_createTextNode($symbol->{output})));
	    return $node, $result[1];
	}
	if ($symbol->{atname}) { # font change command
	    if ($self->{attr}{ForMoz} && $symbol->{codes}) {
		my @childNodes = $result[0]->childNodes;
		my $nodeName = $result[0]->nodeName;
		for (my $i=0; $i<@childNodes; $i++) {
		    if ($childNodes[$i]->nodeName eq 'mi'||$nodeName eq 'mi') {
			my $st = $nodeName eq 'mi' ?
			    $result[0]     ->firstChild->nodeValue :
			    $childNodes[$i]->firstChild->nodeValue;
			$st =~ s/([A-Z])/sprintf "&#x%X;",$symbol->{codes}[ord($1)-65]/ge;
			if ($nodeName eq 'mi') {
			    $result[0] = $self->_createTextNode($st);
			}
			else {
			    $result[0]->replaceChild
				($self->_createTextNode($st), $childNodes[$i]);
			}
		    }
		}
	    }
	    my $node = $self->_createMmlNode($symbol->{tag}, $result[0]);
	    $node->setAttribute($symbol->{atname}=>$symbol->{atval});
	    return $node, $result[1];
	}
	return $self->_createMmlNode($symbol->{tag}, $result[0]), $result[1];
    }
    if ($ttype eq 'BINARY') {
	$str = _removeCharsAndBlanks($str, length $input);
	my @result = $self->_parseSexpr($str);
	return ($self->_createMmlNode
		('mo', $self->_createTextNode($input)), $str)
	    if ! defined $result[0];
	_removeBrackets($result[0]);
	my @result2 = $self->_parseSexpr($result[1]);
	return ($self->_createMmlNode
		('mo', $self->_createTextNode($input)), $str)
	    if ! defined $result2[0];
	_removeBrackets($result2[0]);
	if ($input =~ /new(command|symbol)/) {
	    my $what = $1;
	    # Look for text in both arguments
	    my $text1 = $result[0];
	    my $haveTextArgs = 0;
	    $text1 = $text1->firstChild while $text1->nodeName eq 'mrow';
	    if ($text1->nodeName eq 'mtext') {
		my $text2 = $result2[0];
		$text2 = $text2->firstChild while $text2->nodeName eq 'mrow';
		my $latex;
		if ($result2[0]->childNodes > 1 && $input eq 'newsymbol') {
		    # Process the latex string for a newsymbol
		    my $latexdef = $result2[0]->child(1);
		    $latexdef = $latexdef->firstChild
			while $latexdef->nodeName eq 'mrow';
		    $latex = $latexdef->firstChild->nodeValue;
		}
		if ($text2->nodeName eq 'mtext') {
		    $self->{Definitions}{$text1->firstChild->nodeValue} = {
			tag   =>'mo',
			output=>$text2->firstChild->nodeValue,
			ttype =>$what eq 'symbol' ? 'CONST' : 'DEFINITION',
		    };
		    $self->{Definition_RE} = join '|',
		    map("\Q$_\E", sort {length($b) - length($a)}
			keys %{$self->{Definitions}});
		    $self->{Latex}{$text2->firstChild->nodeValue} = $latex
			if defined $latex;
		    $haveTextArgs = 1;
		}
	    }
	    if (! $haveTextArgs) {
		$newFrag->appendChild($self->_createMmlNode
				      ('mo', $self->_createTextNode($input)),
				      $result[0], $result2[0]);
		return $self->_createMmlNode('mrow', $newFrag), $result2[1];
	    }
	    return undef, $result2[1];
	}
	if ($input =~ /root|stackrel/) {
	    $newFrag->appendChild($result2[0]);
	}
	$newFrag->appendChild($result[0]);
	if ($input eq 'frac') {
	    $newFrag->appendChild($result2[0]);
	}
	return $self->_createMmlNode($symbol->{tag}, $newFrag), $result2[1];
    }
    if ($ttype eq 'INFIX') {
	$str = _removeCharsAndBlanks($str, length $input);
	return $self->_createMmlNode
	    ('mo', $self->_createTextNode($symbol->{output})), $str;
    }
    if ($ttype eq 'SPACE') {
	$str = _removeCharsAndBlanks($str, length $input);
	my $node = $self->_createElementMathML('mspace');
	$node->setAttribute('width', '1ex');
	$newFrag->appendChild($node);
	$newFrag->appendChild
	    ($self->_createMmlNode($symbol->{tag},
				   $self->_createTextNode($symbol->{output})));
 	$node = $self->_createElementMathML('mspace');
 	$node->setAttribute('width', '1ex');
	$newFrag->appendChild($node);
	return $self->_createMmlNode('mrow', $newFrag), $str;
    }
    if ($ttype eq 'LEFTRIGHT') {
	$self->{nestingDepth}++;
	$str = _removeCharsAndBlanks($str, length $input);
	my @result = $self->_parseExpr($str, 0);
	$self->{nestingDepth}--;
	my $st = $result[0]->lastChild ?
	    $result[0]->lastChild->firstChild->nodeValue : '';
	my $node = $self->_createMmlNode
	    ('mo',$self->_createTextNode($symbol->{output}));
	$node = $self->_createMmlNode('mrow', $node);
	if ($st eq '|') { 	# it's an absolute value subterm
	    $node->appendChild($result[0]);
	    return $node, $result[1];
	}
	# the "|" is a \mid
	return $node, $str;
    }
    if ($ttype eq 'NOP') {
	$str = _removeCharsAndBlanks($str, length $input);
	return $self->_parseSexpr($str);
    }
    $str = _removeCharsAndBlanks($str, length $input);
    return $self->_createMmlNode
	($symbol->{tag}, # it's a constant
	 $self->_createTextNode($symbol->{output})), $str;
}

# Removes brackets at the beginning or end of an mrow node
# Arguments: node object
# Returns:   None
# Side-effects: may change children of node object
sub _removeBrackets {
    my ($node) = @_;
    if ($node->nodeName eq 'mrow') {
	my $st = $node->firstChild->firstChild->nodeValue;
	$node->removeChild($node->firstChild) if $st =~ /^[\(\[\{]$/;
	$st = $node->lastChild->firstChild->nodeValue;
	$node->removeChild($node->lastChild) if $st =~ /^[\)\]\}]$/;
    }
}

# Removes the first n characters and any following blanks
# Arguments: string, n
# Returns:   resultant string
sub _removeCharsAndBlanks {
    my ($str, $n) = @_;
    my $st = substr($str, 
		    substr($str, $n) =~ /^\\[^\\ ,!]/ ? $n+1 : $n);
    $st =~ s/^[\x00-\x20]+//;
    return $st;
}

# Removes outermost parenthesis
# Arguments: string
# Returns:   string with parentheses removed
sub _unparen {
    my ($s) = @_;
    $s =~ s!^(<mrow>)<mo>[\(\[\{]</mo>!$1!;
    $s =~ s!<mo>[\)\]\}]</mo>(</mrow>)$!$1!;
    $s;
}

BEGIN {
my %Conversion = ('<'=>'lt', '>'=>'gt', '"'=>'quot', '&'=>'amp');

# Encodes special xml characters
# Arguments: string
# Returns:   encoded string
sub _xml_encode {
    my ($s) = @_;
    $s =~ s/([<>\"&])/&$Conversion{$1};/g;
    $s;
}
}

package Text::ASCIIMathML::Node;

{
    # Create a closure for the following attributes
    my %parser_of;

# Creates a new Text::ASCIIMathML::Node object
# Arguments: Text::ASCIIMathML object, optional tag
# Returns: new object
sub new {
    my ($class, $parser, $tag) = @_;
    my $obj = bless { children=>[] }, $class;
    if (defined $tag) { $obj->{tag} = $tag }
    else { $obj->{frag} = 1 }
    $parser_of{$obj} = $parser;
    return $obj;
}

# Creates a new Text::ASCIIMathML::Node text object
# Arguments: Text::ASCIIMathML object, text
# Returns: new object
sub newText {
    my ($class, $parser, $text) = @_;
    $text =~ s/^\s*(.*?)\s*$/$1/;	# Delete leading/trailing spaces
    my $obj = bless { text=>$text }, $class;
    $parser_of{$obj} = $parser;
    return $obj;
}

my %Parent;
my $Null;
BEGIN {
    $Null = new Text::ASCIIMathML::Node;
}

# Appends one or more node objects to the children of an object
# Arguments: list of objects to append
# Returns:   self
sub appendChild : method {
    my $self = shift;
    my @new = map $_->{frag} ? @{$_->{children}} : $_, @_;
    push @{$self->{children}}, @new;
    map do {$Parent{$_} = $self}, @new;
    return $self;
}

# Returns a the value for an attribute of a node object
# Arguments: Attribute name
# Returns:   Value for the attribute
sub attribute {
    my ($self, $attr) = @_;
    return $self->{attr}{$attr};
}

# Returns a list of the attributes of a node object
# Arguments: None
# Returns:   Array of attribute names
sub attributeList {
    my ($self) = @_;
    return $self->{attrlist} ? @{$self->{attrlist}} : ();
}

# Returns a child with a given index in the array of children of a node
# Arguments: index
# Returns:   Array of node objects
sub child {
    my ($self, $index) = @_;
    return $self->{children} && @{$self->{children}} > $index ?
	$self->{children}[$index] : $Null;
}

# Returns an array of children of a node
# Arguments: None
# Returns:   Array of node objects
sub childNodes {
    my ($self) = @_;
    return $self->{children} ? @{$self->{children}} : ();
}

# Returns the first child of a node; ignores any fragments
# Arguments: None
# Returns:   node object or self
sub firstChild {
    my ($self) = @_;
    return $self->{children} && @{$self->{children}} ?
	$self->{children}[0] : $Null;
}

# Returns true if the object is a fragment
# Arguments: None
# Returns:   Boolean
sub isFragment {
    return $_[0]->{frag};
}

# Returns true if the object is a named node
# Arguments: None
# Returns:   Boolean
sub isNamed {
    return $_[0]->{tag};
}

# Returns true if the object is a text node
# Arguments: None
# Returns:   Boolean
sub isText {
    return defined $_[0]->{text};
}

# Returns the last child of a node
# Arguments: None
# Returns:   node object or self
sub lastChild {
    my ($self) = @_;
    return  $self->{children} && @{$self->{children}} ?
	$self->{children}[-1] : $Null;
}

BEGIN {
# Creates closure for following "static" variables
my (%LatexSym, %LatexMover, %LatexFont, %LatexOp);

# Returns a latex representation of a node object 
# Arguments: None
# Returns:   Text string
sub latex : method {
    my ($self) = @_;

    my $parser = $parser_of{$self};
    if (! %LatexSym) {
	# Build the entity to latex symbol translator
	my $amsymbol = Text::ASCIIMathML::_get_amsymbol_();
	foreach my $sym (keys %$amsymbol) {
	    next unless (defined $amsymbol->{$sym}{output} &&
			 $amsymbol->{$sym}{output} =~ /&\#x.*;/);
	    my ($output, $tex) = map $amsymbol->{$sym}{$_}, qw(output tex);
	    next if defined $LatexSym{$output} && ! $amsymbol->{$sym}{latex};
	    $tex = $sym if $tex eq '';
	    $LatexSym{$output} = "\\$tex";
	}
	my %math_font = (bbb      => 'mathds',
			 mathbb   => 'mathds',
			 cc       => 'cal',
			 mathcal  => 'cal',
			 fr       => 'mathfrak',
			 mathfrak => 'mathfrak',
			 );
	# Add character codes
	foreach my $coded (grep $amsymbol->{$_}{codes}, keys %$amsymbol) {
	    @LatexSym{map(sprintf("&#x%X;", $_),
			  @{$amsymbol->{$coded}{codes}})} =
			      map("\\$math_font{$coded}\{$_}", ('A' .. 'Z'));
	}
	# Post-process protected symbols
	$LatexSym{$_} =~ s/^\\\\/\\/ foreach keys %LatexSym;
	%LatexMover = ('^'           => '\hat',
		       '\overline'   => '\overline',
		       '\to'         => '\vec',
		       '\vec'        => '\vec',
		       '\rightarrow' => '\vec',
		       '.'           => '\dot',
		       '..'          => '\ddot',
		       );
	%LatexFont = (bold            => '\bf',
		      'double-struck' => '\mathds',
		      fraktur         => '\mathfrak',
		      monospace       => '\tt',
		      'sans-serif'    => '\sf',
		      script          => '\cal',
		      );
	%LatexOp = (if         => '\mbox{if }',
		    lcm        => '\mbox{lcm}',
		    newcommand => '\mbox{newcommand}',
		    "\\"       => '\backslash',
		    '&lt;'     => '<',
		    '&gt;'     => '>',
		    '&amp;'    => '\&',
		    '...'      => '\ldots',
		    );
    }
    if (defined $self->{text}) {
	my $text = $self->{text};
	$text =~ s/([{}])/\\$1/;
	$text =~ s/(&\#x.*?;)/
	    defined $parser->{Latex}{$1} ? $parser->{Latex}{$1} :
	    defined $LatexSym{$1} ? $LatexSym{$1} : $1/eg;
	$text =~ s/([\#])/\\$1/;
	return $text;
    }
    my $tag = $self->{tag};
    my @child_str;
    my $child_str = '';
    if (@{$self->{children}}) {
	foreach (@{$self->{children}}) {
	    push @child_str, $_->latex($parser);
	}
    }

# mo
    if ($tag eq 'mo') {
	# Need to distinguish bmod from pmod
	my $parent = $self->parent;
	return $self eq $parent->child(1) &&
	    $parent->firstChild->firstChild->{text} eq '('
	    ? '\pmod' : '\bmod'
	    if $child_str[0] eq 'mod';
	return $LatexOp{$child_str[0]} if $LatexOp{$child_str[0]};
	return $child_str[0] =~ /^\w+$/ ? "\\$child_str[0]" : $child_str[0];
    }

# mrow
    if ($tag eq 'mrow') {
	@child_str = grep $_ ne '', @child_str;
	# Check for pmod function
	if (@child_str > 1 && $child_str[1] eq '\pmod') {
	    pop @child_str if $child_str[-1] eq ')';
	    splice @child_str, 0, 2;
	    return "\\pmod{@child_str}";
	}
	# Check if we need \left ... \right
	my $is_tall = grep(/[_^]|\\(begin\{array\}|frac|sqrt|stackrel)/,
			   @child_str);
	if ($is_tall && @child_str > 1 &&
	    ($child_str[0]  =~ /^([\(\[|]|\\\{)$/ ||
	     $child_str[-1] =~ /^([\)\]|]|\\\})$/)) {
	    if ($child_str[0] =~ /^([\(\[|]|\\\{)$/) {
		$child_str[0] = "\\left$child_str[0]";
	    }
	    else {
		unshift @child_str, "\\left.";
	    }
	    if ($child_str[-1] =~ /^([\)\]|]|\\\})$/) {
		$child_str[-1] = "\\right$child_str[-1]";
	    }
	    else {
		push @child_str, "\\right.";
	    }
	}
	return "@child_str";
    }


# mi
# mn
# math
# mtd
    if ($tag =~ /^m([in]|ath|row|td)$/) {
	@child_str = grep $_ ne '', @child_str;
	return "@child_str";
    }

# msub
# msup
# msubsup
# munderover
    if ($tag =~ /^(msu[bp](sup)?|munderover)$/) {
	my $base = shift @child_str;
	$base = '\mbox{}' if $base eq '';
	# Put {} around arguments with more than one character
	@child_str = map length($_) > 1 ? "{$_}" : $_, @child_str;
	return ($tag eq 'msub' ? "${base}_$child_str[0]" :
		$tag eq 'msup' ? "${base}^$child_str[0]" :
		"${base}_$child_str[0]^$child_str[1]");
    }

# mover
    if ($tag eq 'mover') {
	# Need to special-case math mode accents
	return
	    ($child_str[1] eq '\overline' && length($child_str[0]) == 1 ?
	     "\\bar{$child_str[0]}" :
	     $LatexMover{$child_str[1]} ?
	     "$LatexMover{$child_str[1]}\{$child_str[0]\}" :
	     "\\stackrel{$child_str[1]}{$child_str[0]}");
    }

# munder
    if ($tag eq 'munder') {
	return $child_str[1] eq '\underline' ? "$child_str[1]\{$child_str[0]}"
	    : "$child_str[0]_\{$child_str[1]\}";
    }

# mfrac
    if ($tag eq 'mfrac') {
	return "\\frac{$child_str[0]}{$child_str[1]}";
    }

# msqrt
    if ($tag eq 'msqrt') {
	return "\\sqrt{$child_str[0]}";
    }

# mroot
    if ($tag eq 'mroot') {
	return "\\sqrt[$child_str[1]]{$child_str[0]}";
    }

# mtext
    if ($tag eq 'mtext') {
	my $text = $child_str[0];
	my $next = $self->nextSibling;
	my $prev = $self->previousSibling;
	if (defined $next->{tag} && $next->{tag} eq 'mspace') {
	    $text = "$text ";
	}
	if (defined $prev->{tag} && $prev->{tag} eq 'mspace') {
	    $text = " $text";
	}
	$text = ' ' if $text eq '  ';
	return "\\mbox{$text}";
    }


# mspace
    if ($tag eq 'mspace') {
	return ''; 
    }

# mtable
    if ($tag eq 'mtable') {
	my $cols = ($child_str[0] =~ tr/&//) + 1;
	my $colspec = ($self->{attr}{columnalign} || '') eq 'left' ? 'l' : 'c';
	my $colspecs = $colspec x $cols;
	return ("\\begin{array}{$colspecs}\n" .
		join('', map("  $_ \\\\\n", @child_str)) .
		"\\end{array}\n");
    }

# mtr
    if ($tag eq 'mtr') {
	return join ' & ', @child_str;
    }

# mstyle
    if ($tag eq 'mstyle') {
	@child_str = grep $_ ne '', @child_str;
	if ($self->parent->{tag} eq 'math') {
	    push @child_str, ' ' unless @child_str;
	    # The top-level mstyle
	    return (defined $self->{attr}{displaystyle} &&
		    $self->{attr}{displaystyle} eq 'true') ?
		    "\$\$@child_str\$\$" : "\$@child_str\$";
	}
	else {
	    # It better be a font changing command
	    return $child_str[0] if $self->{attr}{mathvariant};
	    my ($attr) = map($self->{attr}{$_},
			     grep $self->{attr}{$_},
			     qw(fontweight fontfamily));
	    return $attr && $LatexFont{$attr} ?
		"$LatexFont{$attr}\{$child_str[0]}" : $child_str[0];
	}
    }
}
}

# Returns the next sibling of a node
# Arguments: None
# Returns:   node object or undef
sub nextSibling {
    my ($self) = @_;
    my $parent = $self->parent;
    for (my $i=0; $i<@{$parent->{children}}; $i++) {
	return $parent->{children}[$i+1] if $self eq $parent->{children}[$i];
    }
    return $Null;
}

# Returns the tag of a node
# Arguments: None
# Returns:   string
sub nodeName : method {
    return $_[0]{tag} || '';
}

# Returns the text of a text node
# Arguments: None
# Returns:   string
sub nodeValue : method {
    return $_[0]{text} || '';
}

# Returns the parent of a node
# Arguments: none
# Returns:   parent node object or undef
sub parent : method {
    return $Parent{$_[0]} || $Null;
}

# Returns the previous sibling of a node
# Arguments: None
# Returns:   node object or undef
sub previousSibling {
    my ($self) = @_;
    my $parent = $self->parent;
    for (my $i=1; $i<@{$parent->{children}}; $i++) {
	return $parent->{children}[$i-1] if $self eq $parent->{children}[$i];
    }
    return $Null;
}

# Removes a given child node from a node
# Arguments: child node
# Returns:   None
# Side-effects: May affect children of the node
sub removeChild : method {
    my ($self, $child) = @_;
    @{$self->{children}} = grep $_ ne $child, @{$self->{children}}
    if $self->{children};
    delete $Parent{$child};
}

# Replaces one child node object with another
# Arguments: old child node object, new child node object
# Returns:   None
sub replaceChild : method {
    my ($self, $new, $old) = @_;
    @{$self->{children}} = map $_ eq $old ? $new : $_, @{$self->{children}};
    delete $Parent{$old};
    $Parent{$new} = $self;
}

# Sets one or more attributes on a node object
# Arguments: set of attribute/value pairs
# Returns:   None
sub setAttribute : method {
    my $self = shift;
    if (@_) {
	$self->{attr} = {} unless $self->{attr};
	$self->{attrlist} = [] unless $self->{attrlist};
    }
    while (my($aname, $aval) = splice(@_, 0, 2)) {
	$aval =~ s/\n//g;
	push @{$self->{attrlist}}, $aname unless defined $self->{attr}{$aname};
	$self->{attr}{$aname} = $aval;
    }
}

# Returns the ASCII representation of a node object 
# Arguments: None
# Returns:   Text string
sub text : method {
    my ($self) = @_;
    return $self->{text} if defined $self->{text};
    my $tag = $self->{tag};
    my $attr = join '', map(" $_=\"" .
			    ($_ eq 'xmlns' ? $self->{attr}{$_} :
			     Text::ASCIIMathML::_xml_encode($self->{attr}{$_})) .
			    "\"", @{$self->{attrlist}})
	if $tag;
    if (@{$self->{children}}) {
	my $child_str;
	foreach (@{$self->{children}}) {
	    $child_str .= $_->text;
	}
	return $tag ? "<$tag$attr>$child_str</$tag>" : $child_str;
    }
    return $tag ? "<$tag$attr/>" : '';
}
}

1;
