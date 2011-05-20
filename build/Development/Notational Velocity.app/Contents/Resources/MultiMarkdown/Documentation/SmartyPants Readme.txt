SmartyPants
===========

by John Gruber   
http://daringfireball.net/

Version 1.5.1 - Fri 12 Mar 2004


SmartyPants is a free web publishing plug-in for Movable Type, Blosxom,
and BBEdit that easily translates plain ASCII punctuation characters
into "smart" typographic punctuation HTML entities. SmartyPants can also
be invoked as a standalone Perl script.

SmartyPants can perform the following transformations:

*   Straight quotes (`"` and `'`) into "curly" quote HTML entities

*   Backtick-style quotes (` ``like this'' `) into "curly" quote HTML
    entities

*   Dashes (`--` and `---`) into en- and em-dash entities

*   Three consecutive dots (`...`) into an ellipsis entity

This means you can write, edit, and save your posts using plain old
ASCII straight quotes, plain dashes, and plain dots, but your published
posts (and final HTML output) will appear with smart quotes, em-dashes,
and proper ellipses.

SmartyPants is a combination plug-in -- the same file works with Movable
Type, Blosxom, and BBEdit. It can also be used from a Unix-style
command-line. Version requirements and installation instructions for
each of these tools can be found in the corresponding sub-section under
"Installation", below.

SmartyPants does not modify characters within `<pre>`, `<code>`,
`<kbd>`, or `<script>` tag blocks. Typically, these tags are used to
display text where smart quotes and other "smart punctuation" would not
be appropriate, such as source code or example markup.


### Backslash Escapes ###

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
foot and inch marks:

    6\'2\" tall

translates into:

    6&#39;2&#34; tall

in SmartyPants's HTML output. Which, when rendered by a web browser,
looks like:

    6'2" tall


### Markdown and MT-Textile Integration ###

Movable Type users should also note that SmartyPants can be used in
conjunction with two text filtering plug-ins: [Markdown] [1] and Brad
Choate's [MT-Textile] [2].

    [1]: http://daringfireball.net/projects/markdown/
    [2]: http://www.bradchoate.com/mt-plugins/textile

Markdown is my text-to-HTML filter, and is intended to be an
easy-to-write and easy-to-read structured text format for writing for
the web. You write plain text; Markdown turns it into HTML. This readme
file is formatted in Markdown.

When Markdown and SmartyPants are both present in the same Movable Type
installation, the "Markdown With SmartyPants" filter will be available
from MT's Text Formatting pop-up menu. The "Markdown With SmartyPants"
filter automatically applies SmartyPants to the bodies of your entries;
the regular "Markdown" filter does not. See the Markdown web page for
more details.

MT-Textile is a port of Dean Allen's original [Textile] [3] project to
Perl and Movable Type. MT-Textile by itself only translates Textile
markup to HTML. However, if SmartyPants is also installed, MT-Textile
will call on SmartyPants to educate quotes, dashes, and ellipses,
automatically. Textile is Dean Allen's "humane web text generator",
another easy-to-write and easy-to-read shorthand for web writing. An
[online Textile web application] [3] is available at Mr. Allen's site.

    [3]: http://textism.com/tools/textile/

Using SmartyPants in conjunction with MT-Textile or the "Markdown With
SmartyPants" filter requires no modifications to your Movable Type
templates. You simply choose the appropriate filter from the Text
Formatting menu, on a per-post basis. However, note that as of this
writing, Movable Type does not apply text filters to article titles or
excerpts; you'll need to edit your templates to get SmartyPants
processing for those fields.

You'll also need to invoke SmartyPants from your templates if you want
to use non-default settings, such as en-dash support. For explicit
control, I recommend using the regular "Markdown" text filter, and
invoking SmartyPants from your templates.


Installation
------------

### Movable Type ###

SmartyPants works with Movable Type version 2.5 or later.

1.  Copy the "SmartyPants.pl" file into your Movable Type "plugins"
    directory. The "plugins" directory should be in the same directory
    as "mt.cgi"; if it doesn't already exist, use your FTP program to
    create it. Your installation should look like this:

        (mt home)/plugins/SmartyPants.pl

2.  If you're using SmartyPants with Markdown or MT-Textile, you're
    done.

    If not, or if you want explicit control over SmartyPants's behavior,
    you need to edit your MT templates. The easiest way is to add the
    "smarty_pants" attribute to each MT template tag whose contents you
    wish to apply SmartyPants's transformations. Obvious tags would
    include `MTEntryTitle`, `MTEntryBody`, and `MTEntryMore`.
    SmartyPants should work within any MT content tag.

    For example, to apply SmartyPants to your entry titles:

        <$MTEntryTitle smarty_pants="1"$>

    The value passed to the `smarty_pants` attribute specifies the way
    SmartyPants works. See "Options", below, for full details on all of
    the supported options.


### Blosxom ###

SmartyPants works with Blosxom version 2.0 or later.

1.  Rename the "SmartyPants.pl" plug-in to "SmartyPants" (case is
    important). Movable Type requires plug-ins to have a ".pl"
    extension; Blosxom forbids it (at least as of this writing).

2.  Copy the "SmartyPants" plug-in file to your Blosxom plug-ins folder.
    If you're not sure where your Blosxom plug-ins folder is, see the
    Blosxom documentation for information.

3.  That's it. The entries in your weblog should now automatically have
    SmartyPants's default transformations applied.

4.  If you wish to configure SmartyPants's behavior, open the
    "SmartyPants" plug-in, and edit the value of the `$smartypants_attr`
    configuration variable, located near the top of the script. The
    default value is 1; see "Options", below, for the full list of
    supported values.


### BBEdit ###

SmartyPants works with BBEdit 6.1 or later on Mac OS X; and BBEdit 5.1
or later on Mac OS 9 or earlier (provided you have MacPerl installed).

1.  Copy the "SmartyPants.pl" file to appropriate filters folder in your
    "BBEdit Support" folder. On Mac OS X, this should be:

        BBEdit Support/Unix Support/Unix Filters/

    On Mac OS 9 or earlier, this should be:

        BBEdit Support:MacPerl Support:Perl Filters:

    See the BBEdit documentation for more details on the location of
    these folders.

    You can rename "SmartyPants.pl" to whatever you wish.

2.  That's it. To use SmartyPants, select some text in a BBEdit
    document, then choose SmartyPants from the Filters sub-menu or the
    Filters floating palette. On Mac OS 9, the Filters sub-menu is in
    the "Camel" menu; on Mac OS X, it is in the "#!" menu.

3.  If you wish to configure SmartyPants's behavior, open the SmartyPants
    file and edit the value of the `$smartypants_attr` configuration
    variable, located near the top of the script. The default value is
    1; see "Options", below, for the full list of supported values.


### Perl ###

SmartyPants works as a standalone Perl script. You can invoke it from a
Unix-style command line, passing input as a file argument or as piped
input via STDIN. See the POD documentation for information on the
command-line switches SmartyPants accepts.


Options and Configuration
-------------------------

For MT users, the `smarty_pants` template tag attribute is where you
specify configuration options. For Blosxom and BBEdit users, settings
are specified by editing the value of the `$smartypants_attr` variable in
the script itself.

Numeric values are the easiest way to configure SmartyPants's behavior:

"0"
    Suppress all transformations. (Do nothing.)

"1"
    Performs default SmartyPants transformations: quotes (including
    backticks-style), em-dashes, and ellipses. `--` (dash dash) is
    used to signify an em-dash; there is no support for en-dashes.

"2"
    Same as smarty_pants="1", except that it uses the old-school
    typewriter shorthand for dashes: `--` (dash dash) for en-dashes,
    `---` (dash dash dash) for em-dashes.

"3"
    Same as smarty_pants="2", but inverts the shorthand for dashes: `--`
    (dash dash) for em-dashes, and `---` (dash dash dash) for en-dashes.

"-1"
    Stupefy mode. Reverses the SmartyPants transformation process,
    turning the HTML entities produced by SmartyPants into their ASCII
    equivalents. E.g. `&#8220;` is turned into a simple double-quote
    (`"`), `&#8212;` is turned into two dashes, etc. This is useful if you
    are using SmartyPants from Brad Choate's MT-Textile text filter, but
    wish to suppress smart punctuation in specific MT templates, such as
    RSS feeds. Text filters do their work before templates are
    processed; but you can use smarty_pants="-1" to reverse the
    transformations in specific templates.

The following single-character attribute values can be combined to
toggle individual transformations from within the smarty_pants
attribute. For example, to educate normal quotes and em-dashes, but not
ellipses or backticks-style quotes:

    <$MTFoo smarty_pants="qd"$>

"q"
    Educates normal quote characters: (`"`) and (`'`).

"b"
    Educates ` ``backticks'' ` double quotes.

"B"
    Educates backticks-style double quotes and ` `single' ` quotes.

"d"
    Educates em-dashes.

"D"
    Educates em-dashes and en-dashes, using old-school typewriter
    shorthand: (dash dash) for en-dashes, (dash dash dash) for
    em-dashes.

"i"
    Educates em-dashes and en-dashes, using inverted old-school
    typewriter shorthand: (dash dash) for em-dashes, (dash dash dash)
    for en-dashes.

"e"
    Educates ellipses.

"w"
    Translates any instance of `&quot;` into a normal double-quote
    character. This should be of no interest to most people, but of
    particular interest to anyone who writes their posts using
    Dreamweaver, as Dreamweaver inexplicably uses this entity to
    represent a literal double-quote character. SmartyPants only
    educates normal quotes, not entities (because ordinarily, entities
    are used for the explicit purpose of representing the specific
    character they represent). The "w" option must be used in
    conjunction with one (or both) of the other quote options ("q" or
    "b"). Thus, if you wish to apply all SmartyPants transformations
    (quotes, en- and em-dashes, and ellipses) and also translate
    `&quot;` entities into regular quotes so SmartyPants can educate
    them, you should pass the following to the smarty_pants attribute:

        <$MTFoo smarty_pants="qDew"$>

    For Blosxom and BBEdit users, set:

        my $smartypants_attr = "qDew";


### Deprecated MT Attributes ###

Older versions of SmartyPants supplied optional `smart_quotes`,
`smart_dashes`, and `smart_ellipses` MT template attributes. These
attributes are now officially deprecated.


### Version Info Tag ###

If you include this tag in a Movable Type template:

    <$MTSmartyPantsVersion$>

it will be replaced with a string representing the version number of the
installed version of SmartyPants, e.g. "1.5".


Caveats
-------

### Why You Might Not Want to Use Smart Quotes in Your Weblog ###

For one thing, you might not care.

Most normal, mentally stable individuals do not take notice of proper
typographic punctuation. Many design and typography nerds, however,
break out in a nasty rash when they encounter, say, a restaurant sign
that uses a straight apostrophe to spell "Joe's".

If you're the sort of person who just doesn't care, you might well want
to continue not caring. Using straight quotes -- and sticking to the
7-bit ASCII character set in general -- is certainly a simpler way to
live.

Even if you *do* care about accurate typography, you still might want to
think twice before educating the quote characters in your weblog. One
side effect of publishing curly quote HTML entities is that it makes
your weblog a bit harder for others to quote from using copy-and-paste.
What happens is that when someone copies text from your blog, the copied
text contains the 8-bit curly quote characters (as well as the 8-bit
characters for em-dashes and ellipses, if you use these options). These
characters are not standard across different text encoding methods,
which is why they need to be encoded as HTML entities.

People copying text from your weblog, however, may not notice that
you're using curly quotes, and they'll go ahead and paste the unencoded
8-bit characters copied from their browser into an email message or
their own weblog. When pasted as raw "smart quotes", these characters
are likely to get mangled beyond recognition.

That said, my own opinion is that any decent text editor or email client
makes it easy to stupefy smart quote characters into their 7-bit
equivalents, and I don't consider it my problem if you're using an
indecent text editor or email client.

### Algorithmic Shortcomings ###

One situation in which quotes will get curled the wrong way is when
apostrophes are used at the start of leading contractions. For example:

    'Twas the night before Christmas.

In the case above, SmartyPants will turn the apostrophe into an opening
single-quote, when in fact it should be a closing one. I don't think
this problem can be solved in the general case -- every word processor
I've tried gets this wrong as well. In such cases, it's best to use the
proper HTML entity for closing single-quotes (`&#8217;` or `&rsquo;`) by
hand.


Bugs
----

To file bug reports or feature requests (other than topics listed in the
Caveats section above) please send email to:

    smartypants@daringfireball.net

If the bug involves quotes being curled the wrong way, please send
example text to illustrate.


Version History
---------------

1.5.1: Fri 12 Mar 2004

*   Fixed a goof where if you had SmartyPants 1.5.0 installed,
	but didn't have Markdown installed, when SmartyPants checked
	for Markdown's presence, it created a blank entry in MT's
	global hash of installed text filters. This showed up in MT's
	Text Formatting pop-up menu as a blank entry.


1.5: Mon 29 Dec 2003

*   Integration with Markdown. If Markdown is already loaded
    when SmartyPants loads, SmartyPants will add a new global
    text filter, "Markdown With Smartypants".

*   Preliminary command-line options parsing. -1 -2 -3
    -v -V

*   dot-space-dot-space-dot now counts as an ellipsis.
    This is the style used by Project Gutenberg:
    http://www.gutenberg.net/faq/index.shtml#V.110
    (Thanks to Fred Condo for the patch.)

*   Added `<math>` to the list of tags to skip (pre, code, etc.).


1.4.1: Sat 8 Nov 2003

*   The bug fix from 1.4 for dashes followed by quotes with no
    intervening spaces now actually works.

*   `&nbsp;` now counts as whitespace where necessary. (Thanks to
    Greg Knauss for the patch.)


1.4: Mon 30 Jun 2003

*   Improved the HTML tokenizer so that it will parse nested <> pairs
    up to five levels deep. Previously, it only parsed up to two
    levels. What we *should* do is allow for any arbitrary level of
    nesting, but to do so, we would need to use Perl's `??` construct
    (see Fried's "Mastering Regular Expressions", 2nd Ed., pp.
    328-331), and sadly, this would only work in Perl 5.6 or later.
    SmartyPants still supports Perl 5.00503. I suppose we could test
    for the version and build a regex accordingly, but I don't think
    I want to maintain two separate patterns.

*   Thanks to Stepan Riha, the tokenizer now handles HTML comments:

        <!-- comment -->

    and PHP-style processor instructions:

        <?php code ?>

*   The quote educator now handles situations where dashes are used
    without whitespace, e.g.:

        "dashes"--without spaces--"are tricky"  

*   Special case for decade abbreviations like this: `the '80s`.
    This only works for the sequence appostrophe-digit-digit-s.


1.3: Tue 13 May 2003

*   Plugged the biggest hole in SmartyPants's smart quotes algorithm.
    Previous versions were hopelessly confused by single-character
    quote tokens, such as:

        <p>"<i>Tricky!</i>"</p>

    The problem was that the EducateQuotes() function works on each
    token separately, with no means of getting surrounding context
    from the previous or next tokens. The solution is to curl these
    single-character quote tokens as a special case, *before* calling
    EducateQuotes().

*   New single-quotes backtick mode for smarty_pants attribute.
    The only way to turn it on is to include "B" in the configuration
    string, e.g. to translate backtick quotes, dashes, and ellipses:

        smarty_pants="Bde"

*   Fixed a bug where an opening quote would get curled the wrong way
    if the quote started with three dots, e.g.:

        <p>"...meanwhile"</p>

*   Fixed a bug where opening quotes would get curled the wrong way
    if there were double sets of quotes within each other, e.g.:

        <p>"'Some' people."</p>

*   Due to popular demand, four consecutive dots (....) will now be
    turned into an ellipsis followed by a period. Previous versions
    would turn this into a period followed by an ellipsis. If you
    really want a period-then-ellipsis sequence, escape the first
    period with a backslash: \....

*   Removed `&` from our home-grown punctuation class, since it
    denotes an entity, not a literal ampersand punctuation
    character. This fixes a bug where SmartyPants would mis-curl
    the opening quote in something like this:

        "…whatever"

*   SmartyPants has always had a special case where it looks for
    "'s" in situations like this:

        <i>Custer</i>'s Last Stand

    This special case is now case-insensitive.


1.2.2: Thu Mar 13, 2003

*   1.2.1 contained a boneheaded addition which prevented SmartyPants
    from compiling under Perl 5.005. This has been remedied, and is
    the only change from 1.2.1.


1.2.1: Mon Mar 10, 2003

*   New "stupefy mode" for smarty_pants attribute. If you set

        smarty_pants="-1"

    SmartyPants will perform reverse transformations, turning HTML
    entities into plain ASCII equivalents. E.g. "“" is turned
    into a simple double-quote ("), "—" is turned into two
    dashes, etc. This is useful if you are using SmartyPants from Brad
    Choate's MT-Textile text filter, but wish to suppress smart
    punctuation in specific MT templates, such as RSS feeds. Text
    filters do their work before templates are processed; but you can
    use smarty_pants="-1" to reverse the transformations in specific
    templates.

*   Replaced the POSIX-style regex character class `[:punct:]` with an
    ugly hard-coded normal character class of all punctuation; POSIX
    classes require Perl 5.6 or later, but SmartyPants still supports
    back to 5.005.

*   Several small changes to allow SmartyPants to work when Blosxom
    is running in static mode.


1.2: Thu Feb 27, 2003

*   SmartyPants is now a combination plug-in, supporting both
    Movable Type (2.5 or later) and Blosxom (2.0 or later).
    It also works as a BBEdit text filter and standalone
    command-line Perl program. Thanks to Rael Dornfest for the
    initial Blosxom port (and for the excellent Blosxom plug-in
    API).

*   SmartyPants now accepts the following backslash escapes,
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

*   Added a new option to support inverted en- and em-dash notation:
    `--` for em-dashes, `---` for en-dashes. This is compatible with
    SmartyPants's original `--` syntax for em-dashes, but also allows
    you to specify en-dashes. It can be invoked by using
    smart_dashes="3", smarty_pants="3", or smarty_pants="i". 
    (Suggested by Aaron Swartz.)

*   Added a new option to automatically convert `&quot;` entities into
    regular double-quotes before sending text to EducateQuotes() for
    processing. This is mainly for the benefit of people who write
    posts using Dreamweaver, which substitutes this entity for any
    literal quote char. The one and only way to invoke this option
    is to use the letter shortcuts for the smarty_pants attribute;
    the shortcut for this option is "w" (for Dream_w_eaver).
    (Suggested by Jonathon Delacour.)

*   Added `<script>` to the list of tags in which SmartyPants doesn't
    touch the contents.

*   Fixed a very subtle bug that would occur if a quote was the very
    last character in a body of text, preceded immediately by a tag.
    Lacking any context, previous versions of SmartyPants would turn
    this into an opening quote mark. It's now correctly turned into
    a closing one.

*   Opening quotes were being curled the wrong way when the
    subsequent character was punctuation. E.g.: "a '.foo' file".
    Fixed.

*   New MT global template tag: `<$MTSmartyPantsVersion$>`
    Prints the version number of SmartyPants, e.g. "1.2".


1.1: Wed Feb 5, 2003

*   The smart_dashes template attribute now offers an option to
    use `--` for *en* dashes, and `---` for *em* dashes.

*   The default smart_dashes behavior now simply translates `--`
    (dash dash) into an em-dash. Previously, it would look for
    ` -- ` (space dash dash space), which was dumb, since many
    people do not use spaces around their em dashes.

*   Using the smarty_pants attribute with a value of "2" will
    do the same thing as smarty_pants="1", with one difference:
    it will use the new shortcuts for en- and em-dashes.

*   Closing quotes (single and double) were incorrectly curled in
    situations like this:

        "<a>foo</a>",

    where the comma could be just about any punctuation character.
    Fixed.

*   Added `<kbd>` to the list of tags in which text shouldn't be
    educated.


1.0: Wed Nov 13, 2002

*   Initial release.


Author
------

John Gruber
http://daringfireball.net


Additional Credits
------------------

Portions of this plug-in are based on Brad Choate's nifty MTRegex
plug-in. Brad Choate also contributed a few bits of source code to this
plug-in. Brad Choate is a fine hacker indeed. (http://bradchoate.com/)

Jeremy Hedley (http://antipixel.com/) and Charles Wiltgen
(http://playbacktime.com/) deserve mention for exemplary beta testing.

Rael Dornfest (http://raelity.org/) ported SmartyPants to Blosxom.


Copyright and License
---------------------

Copyright (c) 2004 John Gruber   
(http://daringfireball.net/)   
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

* Redistributions of source code must retain the above copyright notice,
  this list of conditions and the following disclaimer.

* Redistributions in binary form must reproduce the above copyright
  notice, this list of conditions and the following disclaimer in the
  documentation and/or other materials provided with the distribution.

* Neither the name "SmartyPants" nor the names of its contributors may
  be used to endorse or promote products derived from this software
  without specific prior written permission.

This software is provided by the copyright holders and contributors "as
is" and any express or implied warranties, including, but not limited
to, the implied warranties of merchantability and fitness for a
particular purpose are disclaimed. In no event shall the copyright owner
or contributors be liable for any direct, indirect, incidental, special,
exemplary, or consequential damages (including, but not limited to,
procurement of substitute goods or services; loss of use, data, or
profits; or business interruption) however caused and on any theory of
liability, whether in contract, strict liability, or tort (including
negligence or otherwise) arising in any way out of the use of this
software, even if advised of the possibility of such damage.
