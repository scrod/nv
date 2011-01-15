NAME
    MultiMarkdown

SYNOPSIS
    MultiMarkdown.pl [ --html4tags ] [ --version ] [ -shortversion ] [
    *file* ... ]

DESCRIPTION
    MultiMarkdown is an extended version of Markdown. See the website for
    more information.

            http://fletcherpenney.net/multimarkdown/

    Markdown is a text-to-HTML filter; it translates an easy-to-read /
    easy-to-write structured text format into HTML. Markdown's text format
    is most similar to that of plain text email, and supports features such
    as headers, *emphasis*, code blocks, blockquotes, and links.

    Markdown's syntax is designed not as a generic markup language, but
    specifically to serve as a front-end to (X)HTML. You can use span-level
    HTML tags anywhere in a Markdown document, and you can use block level
    HTML tags (like <div> and <table> as well).

    For more information about Markdown's syntax, see:

        http://daringfireball.net/projects/markdown/

OPTIONS
    Use "--" to end switch parsing. For example, to open a file named "-z",
    use:

            Markdown.pl -- -z

    --html4tags
        Use HTML 4 style for empty element tags, e.g.:

            <br>

        instead of Markdown's default XHTML style tags, e.g.:

            <br />

    -v, --version
        Display Markdown's version number and copyright information.

    -s, --shortversion
        Display the short-form version number.

BUGS
    To file bug reports or feature requests (other than topics listed in the
    Caveats section above) please send email to:

        support@daringfireball.net (for Markdown issues)
        
        owner@fletcherpenney.net (for MultiMarkdown issues)

    Please include with your report: (1) the example input; (2) the output
    you expected; (3) the output (Multi)Markdown actually produced.

AUTHOR
        John Gruber
        http://daringfireball.net/

        PHP port and other contributions by Michel Fortin
        http://michelf.com/

        MultiMarkdown changes by Fletcher Penney
        http://fletcherpenney.net/

COPYRIGHT AND LICENSE
    Original Markdown Code Copyright (c) 2003-2007 John Gruber
    <http://daringfireball.net/> All rights reserved.

    MultiMarkdown changes Copyright (c) 2005-2009 Fletcher T. Penney
    <http://fletcherpenney.net/> All rights reserved.

    Redistribution and use in source and binary forms, with or without
    modification, are permitted provided that the following conditions are
    met:

    * Redistributions of source code must retain the above copyright notice,
    this list of conditions and the following disclaimer.

    * Redistributions in binary form must reproduce the above copyright
    notice, this list of conditions and the following disclaimer in the
    documentation and/or other materials provided with the distribution.

    * Neither the name "Markdown" nor the names of its contributors may be
    used to endorse or promote products derived from this software without
    specific prior written permission.

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

