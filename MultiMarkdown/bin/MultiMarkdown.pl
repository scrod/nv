#!/usr/bin/env perl

# MultiMarkdown -- A modification of John Gruber's original Markdown
#	that adds new features and an output format that can more readily
#	be converted into other document formats
#
# $Id: MultiMarkdown.pl 525 2009-06-15 18:45:44Z fletcher $
#
# Original Code Copyright (c) 2004-2007 John Gruber
#	<http://daringfireball.net/projects/markdown/>
#
# MultiMarkdown changes Copyright (c) 2005-2009 Fletcher T. Penney
#	<http://fletcherpenney.net/>
#
# MultiMarkdown Version 2.0.b6
#
# Based on Markdown.pl 1.0.2b8 -  Wed 09 May 2007
#
#
#	TODO: Change math mode delimiter?
#	TODO: Still need to get the glossary working in non-memoir documents
#	TODO: A mechanism to include arbitrary code (LaTeX, etc) without being "ugly"
#	TODO: Look into discussion re: assigning classes to div's/span's on Markdown list.
#	TODO: Improve support for tables with long items and overall width in LaTeX
#	TODO: Need a syntax for long table cells in MMD, even if no rowspan feature yet
#	TODO: Create utilities to convert MMD tables to/from tab-delimited


package MultiMarkdown;
require 5.006_000;
use strict;
use warnings;

use File::Basename;

eval {require MT};  # Test to see if we're running in MT.
unless ($@) {
	require Text::ASCIIMathML;
} else {	# Otherwise look for ASCIIMathML.pm next to MultiMarkdown.pl
	my $me = $0;				# Where am I?

	# Am I running in Windoze?
	my $os = $^O;

	# Get just the directory portion
	if ($os =~ /MSWin/) {
		$me = dirname($me) . "\\";
	} else {
		$me = dirname($me) . "/"; 
	}
	require $me ."ASCIIMathML.pm";
}


use Digest::MD5 qw(md5_hex);
use vars qw($VERSION $g_use_metadata $g_base_url
	$g_bibliography_title $g_allow_mathml $g_base_header_level $mathParser);
$VERSION = '2.0.b6';

$mathParser = new Text::ASCIIMathML();

## Disabled; causes problems under Perl 5.6.1:
# use utf8;
# binmode( STDOUT, ":utf8" );  # c.f.: http://acis.openlib.org/dev/perl-unicode-struggle.html

#
# Global default settings:
#
my $g_empty_element_suffix = " />";     # Change to ">" for HTML output
my $g_tab_width = 4;
my $g_allow_mathml = 1;
my $g_base_header_level = 1;

#
# Globals:
#

# Reusable patterns to match balanced [brackets] and (parens). See
# Friedl's "Mastering Regular Expressions", 2nd Ed., pp. 328-331.
my ($g_nested_brackets, $g_nested_parens);
$g_nested_brackets = qr{
	(?> 								# Atomic matching
	   [^\[\]]+							# Anything other than brackets
	 | 
	   \[
		 (??{ $g_nested_brackets })		# Recursive set of nested brackets
	   \]
	)*
}x;

# Doesn't allow for whitespace, because we're using it to match URLs:
$g_nested_parens = qr{
	(?> 								# Atomic matching
	   [^()\s]+							# Anything other than parens or whitespace
	 | 
	   \(
		 (??{ $g_nested_parens })		# Recursive set of nested brackets
	   \)
	)*
}x;


# Table of hash values for escaped characters:
my %g_escape_table;
foreach my $char (split //, '\\`*_{}[]()>#+-.!') {
	$g_escape_table{$char} = md5_hex($char);
}


# Global hashes, used by various utility routines
my %g_urls = ();
my %g_titles= ();
my %g_html_blocks = ();
my %g_metadata = ();
my %g_metadata_newline = ();
my %g_crossrefs = ();
my %g_footnotes = ();
my %g_attributes = ();
my @g_used_footnotes = ();
my $g_footnote_counter = 0;

my $g_citation_counter = 0;
my @g_used_references = ();
my %g_references = ();
$g_bibliography_title = "Bibliography";

$g_use_metadata = 1;
$g_metadata_newline{default} = "\n";
$g_metadata_newline{keywords} = ", ";
my $g_document_format = "";

# Used to track when we're inside an ordered or unordered list
# (see _ProcessListItems() for details):
my $g_list_level = 0;


#### Blosxom plug-in interface ##########################################

# Set $g_blosxom_use_meta to 1 to use Blosxom's meta plug-in to determine
# which posts Markdown should process, using a "meta-markup: markdown"
# header. If it's set to 0 (the default), Markdown will process all
# entries.
my $g_blosxom_use_meta = 0;

sub start { 1; }
sub story {
	my($pkg, $path, $filename, $story_ref, $title_ref, $body_ref) = @_;

	if ( (! $g_blosxom_use_meta) or
	     (defined($meta::markup) and ($meta::markup =~ /^\s*markdown\s*$/i))
	     ){
			$$body_ref  = Markdown($$body_ref);
     }
     1;
}


#### Movable Type plug-in interface #####################################
eval {require MT};  # Test to see if we're running in MT.
unless ($@) {
    require MT;
    import  MT;
    require MT::Template::Context;
    import  MT::Template::Context;

	eval {require MT::Plugin};  # Test to see if we're running >= MT 3.0.
	unless ($@) {
		require MT::Plugin;
		import  MT::Plugin;
		my $plugin = new MT::Plugin({
			name => "MultiMarkdown",
			description => "Based on the original Markdown",
			doc_link => 'http://fletcherpenney.net/multimarkdown/'
		});
		MT->add_plugin( $plugin );
	}

	MT::Template::Context->add_container_tag(MultiMarkdownOptions => sub {
		my $ctx	 = shift;
		my $args = shift;
		my $builder = $ctx->stash('builder');
		my $tokens = $ctx->stash('tokens');

		if (defined ($args->{'output'}) ) {
			$ctx->stash('multimarkdown_output', lc $args->{'output'});
		}

		defined (my $str = $builder->build($ctx, $tokens) )
			or return $ctx->error($builder->errstr);
		$str;		# return value
	});

	MT->add_text_filter('multimarkdown' => {
		label     => 'MultiMarkdown',
		docs      => 'http://fletcherpenney.net/MultiMarkdown/',
		on_format => sub {
			my $text = shift;
			my $ctx  = shift;
			my $raw  = 0;
		    if (defined $ctx) {
		    	my $output = $ctx->stash('multimarkdown_output'); 
				if (defined $output  &&  $output =~ m/^html/i) {
					$g_empty_element_suffix = ">";
					$ctx->stash('multimarkdown_output', '');
				}
				elsif (defined $output  &&  $output eq 'raw') {
					$raw = 1;
					$ctx->stash('multimarkdown_output', '');
				}
				else {
					$raw = 0;
					$g_empty_element_suffix = " />";
				}
			}
			$text = $raw ? $text : Markdown($text);
			$text;
		},
	});

	# If SmartyPants is loaded, add a combo Markdown/SmartyPants text filter:
	my $smartypants;

	{
		no warnings "once";
		$smartypants = $MT::Template::Context::Global_filters{'smarty_pants'};
	}

	if ($smartypants) {
		MT->add_text_filter('multimarkdown_with_smartypants' => {
			label     => 'MultiMarkdown With SmartyPants',
			docs      => 'http://fletcherpenney.net/MultiMarkdown/',
			on_format => sub {
				my $text = shift;
				my $ctx  = shift;
				if (defined $ctx) {
					my $output = $ctx->stash('multimarkdown_output'); 
					if (defined $output  &&  $output eq 'html') {
						$g_empty_element_suffix = ">";
					}
					else {
						$g_empty_element_suffix = " />";
					}
				}
				$text = Markdown($text);
				$text = $smartypants->($text, '1');
			},
		});
	}
}
else {
#### BBEdit/command-line text filter interface ##########################
# Needs to be hidden from MT (and Blosxom when running in static mode).

    # We're only using $blosxom::version once; tell Perl not to warn us:
	no warnings 'once';
    unless ( defined($blosxom::version) ) {
		use warnings;

		#### Check for command-line switches: #################
		my %cli_opts;
		use Getopt::Long;
		Getopt::Long::Configure('pass_through');
		GetOptions(\%cli_opts,
			'version',
			'shortversion',
			'html4tags',
		);
		if ($cli_opts{'version'}) {		# Version info
			print "\nThis is MultiMarkdown, version $VERSION.\n";
			print "Original code Copyright 2004 John Gruber\n";
			print "MultiMarkdown changes Copyright 2005-2009 Fletcher Penney\n";
			print "http://fletcherpenney.net/multimarkdown/\n";
			print "http://daringfireball.net/projects/markdown/\n\n";
			exit 0;
		}
		if ($cli_opts{'shortversion'}) {		# Just the version number string.
			print $VERSION;
			exit 0;
		}
		if ($cli_opts{'html4tags'}) {			# Use HTML tag style instead of XHTML
			$g_empty_element_suffix = ">";
		}


		#### Process incoming text: ###########################
		my $text;
		{
			local $/;               # Slurp the whole file
			$text = <>;
		}
        print Markdown($text);
    }
}



sub Markdown {
#
# Main function. The order in which other subs are called here is
# essential. Link and image substitutions need to happen before
# _EscapeSpecialCharsWithinTagAttributes(), so that any *'s or _'s in the <a>
# and <img> tags get encoded.
#
	my $text = shift;

	# Clear the global hashes. If we don't clear these, you get conflicts
	# from other articles when generating a page which contains more than
	# one article (e.g. an index page that shows the N most recent
	# articles):
	%g_urls = ();
	%g_titles = ();
	%g_html_blocks = ();
	%g_metadata = ();
	%g_crossrefs = ();
	%g_footnotes = ();
	@g_used_footnotes = ();
	$g_footnote_counter = 0;
	@g_used_references = ();
	%g_references = ();
	$g_citation_counter = 0;
	%g_attributes = ();


	# Standardize line endings:
	$text =~ s{\r\n}{\n}g; 	# DOS to Unix
	$text =~ s{\r}{\n}g; 	# Mac to Unix

	# Make sure $text ends with a couple of newlines:
	$text .= "\n\n";

	# Convert all tabs to spaces.
	$text = _Detab($text);

	# Strip any lines consisting only of spaces and tabs.
	# This makes subsequent regexen easier to write, because we can
	# match consecutive blank lines with /\n+/ instead of something
	# contorted like /[ \t]*\n+/ .
	$text =~ s/^[ \t]+$//mg;
	
	# Strip out MetaData
	$text = _ParseMetaData($text) if $g_use_metadata;

	# And recheck for leading blank lines
	$text =~ s/^\n+//s;
		
	# Turn block-level HTML blocks into hash entries
	$text = _HashHTMLBlocks($text);

	# Strip footnote and link definitions, store in hashes.
	$text = _StripFootnoteDefinitions($text);

	$text = _StripLinkDefinitions($text);

	_GenerateImageCrossRefs($text);
	
	$text = _StripMarkdownReferences($text);

	$text = _RunBlockGamut($text);
	
	$text = _DoMarkdownCitations($text);
	
	$text = _DoFootnotes($text);
	
	$text = _UnescapeSpecialChars($text);
	
	# Clean encoding within HTML comments
	$text = _UnescapeComments($text);
	
	$text = _FixFootnoteParagraphs($text);
	$text .= _PrintFootnotes();
	
	$text .= _PrintMarkdownBibliography();
		
	$text = _ConvertCopyright($text);
	
	if (lc($g_document_format) =~ /^complete\s*$/i) {
		return xhtmlMetaData() . "<body>\n\n" . $text . "\n</body>\n</html>";
	} elsif (lc($g_document_format) =~ /^snippet\s*$/i) {
		return $text . "\n";
	} else {
		return $g_document_format . textMetaData() . $text . "\n";
	}
	
}


sub _StripLinkDefinitions {
#
# Strips link definitions from text, stores the URLs and titles in
# hash references.
#
	my $text = shift;
	my $less_than_tab = $g_tab_width - 1;

	# Link defs are in the form: ^[id]: url "optional title"
	while ($text =~ s{
						# Pattern altered for MultiMarkdown
						# in order to not match citations or footnotes
						^[ ]{0,$less_than_tab}\[([^#^].*)\]:	# id = $1
						  [ \t]*
						  \n?				# maybe *one* newline
						  [ \t]*
						<?(\S+?)>?			# url = $2
						  [ \t]*
						  \n?				# maybe one newline
						  [ \t]*
						(?:
							(?<=\s)			# lookbehind for whitespace
							["(]
							(.+?)			# title = $3
							[")]
							[ \t]*
						)?	# title is optional
						
						# MultiMarkdown addition for attribute support
						\n?
						(				# Attributes = $4
							(?<=\s)			# lookbehind for whitespace
							(([ \t]*\n)?[ \t]*((\S+=\S+)|(\S+=".*?")))*
						)?
						[ \t]*
						# /addition
						(?:\n+|\Z)
					}
					{}mx) {
#		$g_urls{lc $1} = _EncodeAmpsAndAngles( $2 );	# Link IDs are case-insensitive
		$g_urls{lc $1} = $2;	# Link IDs are case-insensitive
		if ($3) {
			$g_titles{lc $1} = $3;
			$g_titles{lc $1} =~ s/"/&quot;/g;
		}
		
		# MultiMarkdown addition "
		if ($4) {
			$g_attributes{lc $1} = $4;
		}
		# /addition
	}

	return $text;
}

sub _StripHTML {
	# Strip (X)HTML code from string
	my $text = shift;
	
	$text =~ s/<.*?>//g;
	
	return $text;
}

sub _HashHTMLBlocks {
	my $text = shift;
	my $less_than_tab = $g_tab_width - 1;

	# Hashify HTML blocks:
	# We only want to do this for block-level HTML tags, such as headers,
	# lists, and tables. That's because we still want to wrap <p>s around
	# "paragraphs" that are wrapped in non-block-level tags, such as anchors,
	# phrase emphasis, and spans. The list of tags we're looking for is
	# hard-coded:
	my $block_tags = qr{
		  (?:
			p         |  div     |  h[1-6]  |  blockquote  |  pre       |  table  |
			dl        |  ol      |  ul      |  script      |  noscript  |  form   |
			fieldset  |  iframe     |  ins         |  del
		  )
		}x;			# MultiMarkdown does not include `math` in the above list so that 
					# Equations can optionally be included in separate paragraphs

	my $tag_attrs = qr{
						(?:				# Match one attr name/value pair
							\s+				# There needs to be at least some whitespace
											# before each attribute name.
							[\w.:_-]+		# Attribute name
							\s*=\s*
							(?:
								".+?"		# "Attribute value"
							 |
								'.+?'		# 'Attribute value'
							)
						)*				# Zero or more
					}x;

	my $empty_tag = qr{< \w+ $tag_attrs \s* />}xms;
	my $open_tag =  qr{< $block_tags $tag_attrs \s* >}xms;
	my $close_tag = undef;	# let Text::Balanced handle this

	use Text::Balanced qw(gen_extract_tagged);
	my $extract_block = gen_extract_tagged($open_tag, $close_tag, undef, { ignore => [$empty_tag] });

	my @chunks;
	## TO-DO: the 0,3 on the next line ought to respect the
	## tabwidth, or else, we should mandate 4-space tabwidth and
	## be done with it:
	while ($text =~ s{^(([ ]{0,3}<)?.*\n)}{}m) {
		my $cur_line = $1;
		if (defined $2) {
			# current line could be start of code block

			my ($tag, $remainder) = $extract_block->($cur_line . $text);
			if ($tag) {
				my $key = md5_hex($tag);
				$g_html_blocks{$key} = $tag;
				push @chunks, "\n\n" . $key . "\n\n";
				$text = $remainder;
			}
			else {
				# No tag match, so toss $cur_line into @chunks
				push @chunks, $cur_line;
			}
		}
		else {
			# current line could NOT be start of code block
			push @chunks, $cur_line;
		}

	}
	push @chunks, $text; # Whatever is left.

	$text = join '', @chunks;



	# Special case just for <hr />. It was easier to make a special case than
	# to make the other regex more complicated.	
	$text =~ s{
				(?:
					(?<=\n\n)		# Starting after a blank line
					|				# or
					\A\n?			# the beginning of the doc
				)
				(						# save in $1
					[ ]{0,$less_than_tab}
					<(hr)				# start tag = $2
					\b					# word break
					([^<>])*?			# 
					/?>					# the matching end tag
					[ \t]*
					(?=\n{2,}|\Z)		# followed by a blank line or end of document
				)
			}{
				my $key = md5_hex($1);
				$g_html_blocks{$key} = $1;
				"\n\n" . $key . "\n\n";
			}egx;

	# Special case for standalone HTML comments:
	$text =~ s{
				(?:
					(?<=\n\n)		# Starting after a blank line
					|				# or
					\A\n?			# the beginning of the doc
				)
				(						# save in $1
					[ ]{0,$less_than_tab}
					(?s:
						<!
						(--.*?--\s*)+
						>
					)
					[ \t]*
					(?=\n{2,}|\Z)		# followed by a blank line or end of document
				)
			}{
				my $key = md5_hex($1);
				$g_html_blocks{$key} = $1;
				"\n\n" . $key . "\n\n";
			}egx;

	# PHP and ASP-style processor instructions (<?…?> and <%…%>)
	$text =~ s{
				(?:
					(?<=\n\n)		# Starting after a blank line
					|				# or
					\A\n?			# the beginning of the doc
				)
				(						# save in $1
					[ ]{0,$less_than_tab}
					(?s:
						<([?%])			# $2
						.*?
						\2>
					)
					[ \t]*
					(?=\n{2,}|\Z)		# followed by a blank line or end of document
				)
			}{
				my $key = md5_hex($1);
				$g_html_blocks{$key} = $1;
				"\n\n" . $key . "\n\n";
			}egx;


	return $text;
}


sub _RunBlockGamut {
#
# These are all the transformations that form block-level
# tags like paragraphs, headers, and list items.
#
	my $text = shift;

	$text = _DoHeaders($text);

	# Do tables first to populate the table id's for cross-refs
	# Escape <pre><code> so we don't get greedy with tables
	$text = _DoTables($text);
	
	# And now, protect our tables
	$text = _HashHTMLBlocks($text);

	# Do Horizontal Rules:
	$text =~ s{^[ ]{0,2}([ ]?\*[ ]?){3,}[ \t]*$}{\n<hr$g_empty_element_suffix\n}gmx;
	$text =~ s{^[ ]{0,2}([ ]? -[ ]?){3,}[ \t]*$}{\n<hr$g_empty_element_suffix\n}gmx;
	$text =~ s{^[ ]{0,2}([ ]? _[ ]?){3,}[ \t]*$}{\n<hr$g_empty_element_suffix\n}gmx;

	$text = _DoDefinitionLists($text);
	$text = _DoLists($text);
	$text = _DoCodeBlocks($text);
	$text = _DoBlockQuotes($text);

	# We already ran _HashHTMLBlocks() before, in Markdown(), but that
	# was to escape raw HTML in the original Markdown source. This time,
	# we're escaping the markup we've just created, so that we don't wrap
	# <p> tags around block-level tags.
	$text = _HashHTMLBlocks($text);
	$text = _FormParagraphs($text);

	return $text;
}


sub _RunSpanGamut {
#
# These are all the transformations that occur *within* block-level
# tags like paragraphs, headers, and list items.
#
	my $text = shift;

	$text = _DoCodeSpans($text);
	$text = _DoMathSpans($text);
	$text = _EscapeSpecialCharsWithinTagAttributes($text);
	$text = _EncodeBackslashEscapes($text);

	# Process anchor and image tags. Images must come first,
	# because ![foo][f] looks like an anchor.
	$text = _DoImages($text);
	$text = _DoAnchors($text);	

	# Make links out of things like `<http://example.com/>`
	# Must come after _DoAnchors(), because you can use < and >
	# delimiters in inline links like [this](<url>).
	$text = _DoAutoLinks($text);
	$text = _EncodeAmpsAndAngles($text);
	$text = _DoItalicsAndBold($text);

	# Do hard breaks:
	$text =~ s/ {2,}\n/ <br$g_empty_element_suffix\n/g;

	return $text;
}


sub _EscapeSpecialCharsWithinTagAttributes {
#
# Within tags -- meaning between < and > -- encode [\ ` * _] so they
# don't conflict with their use in Markdown for code, italics and strong.
# We're replacing each such character with its corresponding MD5 checksum
# value; this is likely overkill, but it should prevent us from colliding
# with the escape values by accident.
#
	my $text = shift;
	my $tokens ||= _TokenizeHTML($text);
	$text = '';   # rebuild $text from the tokens

	foreach my $cur_token (@$tokens) {
		if ($cur_token->[0] eq "tag") {
			$cur_token->[1] =~  s! \\ !$g_escape_table{'\\'}!gx;
			$cur_token->[1] =~  s{ (?<=.)</?code>(?=.)  }{$g_escape_table{'`'}}gx;
			$cur_token->[1] =~  s! \* !$g_escape_table{'*'}!gx;
			$cur_token->[1] =~  s! _  !$g_escape_table{'_'}!gx;
		}
		$text .= $cur_token->[1];
	}
	return $text;
}


sub _DoAnchors {
#
# Turn Markdown link shortcuts into XHTML <a> tags.
#
	my $text = shift;

	#
	# First, handle reference-style links: [link text] [id]
	#
	$text =~ s{
		(					# wrap whole match in $1
		  \[
		    ($g_nested_brackets)	# link text = $2
		  \]

		  [ ]?				# one optional space
		  (?:\n[ ]*)?		# one optional newline followed by spaces

		  \[
		    (.*?)		# id = $3
		  \]
		)
	}{
		my $result;
		my $whole_match = $1;
		my $link_text   = $2;
		my $link_id     = lc $3;

		if ($link_id eq "") {
			$link_id = lc $link_text;     # for shortcut links like [this][].
		}

		# Allow automatic cross-references to headers
		my $label = Header2Label($link_id);
		if (defined $g_urls{$link_id}) {
			my $url = $g_urls{$link_id};
			$url =~ s! \* !$g_escape_table{'*'}!gx;		# We've got to encode these to avoid
			$url =~ s!  _ !$g_escape_table{'_'}!gx;		# conflicting with italics/bold.
			$result = "<a href=\"$url\"";
			if ( defined $g_titles{$link_id} ) {
				my $title = $g_titles{$link_id};
				$title =~ s! \* !$g_escape_table{'*'}!gx;
				$title =~ s!  _ !$g_escape_table{'_'}!gx;
				$result .=  " title=\"$title\"";
			}
			$result .= _DoAttributes($label);
			$result .= ">$link_text</a>";
		} elsif (defined $g_crossrefs{$label}) {
			my $url = $g_crossrefs{$label};
			$url =~ s! \* !$g_escape_table{'*'}!gx;		# We've got to encode these to avoid
			$url =~ s!  _ !$g_escape_table{'_'}!gx;		# conflicting with italics/bold.
			$result = "<a href=\"$url\"";
			if ( defined $g_titles{$label} ) {
				my $title = $g_titles{$label};
				$title =~ s! \* !$g_escape_table{'*'}!gx;
				$title =~ s!  _ !$g_escape_table{'_'}!gx;
				$result .=  " title=\"$title\"";
			}
			$result .= _DoAttributes($label);
			$result .= ">$link_text</a>";
		} else {
			$result = $whole_match;
		}
		$result;
	}xsge;

	#
	# Next, inline-style links: [link text](url "optional title")
	#
	$text =~ s{
		(				# wrap whole match in $1
		  \[
		    ($g_nested_brackets)	# link text = $2
		  \]
		  \(			# literal paren
		  	[ \t]*
			($g_nested_parens)		# href = $3
		  	[ \t]*
			(			# $4
			  (['"])	# quote char = $5
			  (.*?)		# Title = $6
			  \5		# matching quote
  		  	  [ \t]*	# ignore any spaces/tabs between closing quote and )
			)?			# title is optional
		  \)
		)
	}{
		my $result;
		my $whole_match = $1;
		my $link_text   = $2;
		my $url	  		= $3;
		my $title		= $6;

		$url =~ s! \* !$g_escape_table{'*'}!gx;		# We've got to encode these to avoid
		$url =~ s!  _ !$g_escape_table{'_'}!gx;		# conflicting with italics/bold.
		$url =~ s{^<(.*)>$}{$1};					# Remove <>'s surrounding URL, if present
		$result = "<a href=\"$url\"";

		if (defined $title) {
			$title =~ s/"/&quot;/g;
			$title =~ s! \* !$g_escape_table{'*'}!gx;
			$title =~ s!  _ !$g_escape_table{'_'}!gx;
			$result .=  " title=\"$title\"";
		}
		$result .= ">$link_text</a>";

		$result;
	}xsge;

	#
	# Last, handle reference-style shortcuts: [link text]
	# These must come last in case you've also got [link test][1]
	# or [link test](/foo)
	#
	$text =~ s{
		(					# wrap whole match in $1
		  \[
		    ([^\[\]]+)		# link text = $2; can't contain '[' or ']'
		  \]
		)
	}{
		my $result;
		my $whole_match = $1;
		my $link_text   = $2;
		(my $link_id = lc $2) =~ s{[ ]?\n}{ }g; # lower-case and turn embedded newlines into spaces

		# Allow automatic cross-references to headers
		my $label = Header2Label($link_id);
		if (defined $g_urls{$link_id}) {
			my $url = $g_urls{$link_id};
			$url =~ s! \* !$g_escape_table{'*'}!gx;		# We've got to encode these to avoid
			$url =~ s!  _ !$g_escape_table{'_'}!gx;		# conflicting with italics/bold.
			$result = "<a href=\"$url\"";
			if ( defined $g_titles{$link_id} ) {
				my $title = $g_titles{$link_id};
				$title =~ s! \* !$g_escape_table{'*'}!gx;
				$title =~ s!  _ !$g_escape_table{'_'}!gx;
				$result .=  " title=\"$title\"";
			}
			$result .= _DoAttributes($link_id);
			$result .= ">$link_text</a>";
		} elsif (defined $g_crossrefs{$label}) {
			my $url = $g_crossrefs{$label};
			$url =~ s! \* !$g_escape_table{'*'}!gx;		# We've got to encode these to avoid
			$url =~ s!  _ !$g_escape_table{'_'}!gx;		# conflicting with italics/bold.
			$result = "<a href=\"$url\"";
			if ( defined $g_titles{$label} ) {
				my $title = $g_titles{$label};
				$title =~ s! \* !$g_escape_table{'*'}!gx;
				$title =~ s!  _ !$g_escape_table{'_'}!gx;
				$result .=  " title=\"$title\"";
			}
			$result .= _DoAttributes($label);
			$result .= ">$link_text</a>";
		} else {
			$result = $whole_match;
		}
		$result;
	}xsge;

	return $text;
}


sub _DoImages {
#
# Turn Markdown image shortcuts into <img> tags.
#
	my $text = shift;

	#
	# First, handle reference-style labeled images: ![alt text][id]
	#
	$text =~ s{
		(				# wrap whole match in $1
		  !\[
		    (.*?)		# alt text = $2
		  \]

		  [ ]?				# one optional space
		  (?:\n[ ]*)?		# one optional newline followed by spaces

		  \[
		    (.*?)		# id = $3
		  \]

		)
	}{
		my $result;
		my $whole_match = $1;
		my $alt_text    = $2;
		my $link_id     = lc $3;

		if ($link_id eq "") {
			$link_id = lc $alt_text;     # for shortcut links like ![this][].
		}

		$alt_text =~ s/"/&quot;/g;
		if (defined $g_urls{$link_id}) {
			my $url = $g_urls{$link_id};
			$url =~ s! \* !$g_escape_table{'*'}!gx;		# We've got to encode these to avoid
			$url =~ s!  _ !$g_escape_table{'_'}!gx;		# conflicting with italics/bold.
			
			my $label = Header2Label($alt_text);
			$g_crossrefs{$label} = "#$label";
			if (! defined $g_titles{$link_id}) {
				$g_titles{$link_id} = $alt_text;
			}
			
			$result = "<img id=\"$label\" src=\"$url\" alt=\"$alt_text\"";
			if (defined $g_titles{$link_id}) {
				my $title = $g_titles{$link_id};
				$title =~ s! \* !$g_escape_table{'*'}!gx;
				$title =~ s!  _ !$g_escape_table{'_'}!gx;
				$result .=  " title=\"$title\"";
			}
			$result .= _DoAttributes($link_id);
			$result .= $g_empty_element_suffix;		
		}
		else {
			# If there's no such link ID, leave intact:
			$result = $whole_match;
		}

		$result;
	}xsge;

	#
	# Next, handle inline images:  ![alt text](url "optional title")
	# Don't forget: encode * and _

	$text =~ s{
		(				# wrap whole match in $1
		  !\[
		    (.*?)		# alt text = $2
		  \]
		  \s?			# One optional whitespace character
		  \(			# literal paren
		  	[ \t]*
			($g_nested_parens)		# href = $3
		  	[ \t]*
			(			# $4
			  (['"])	# quote char = $5
			  (.*?)		# title = $6
			  \5		# matching quote
			  [ \t]*
			)?			# title is optional
		  \)
		)
	}{
		my $result;
		my $whole_match = $1;
		my $alt_text    = $2;
		my $url	  		= $3;
		my $title		= (defined $6) ? $6 : '';

		$alt_text =~ s/"/&quot;/g;
		$title    =~ s/"/&quot;/g;
		$url =~ s! \* !$g_escape_table{'*'}!gx;		# We've got to encode these to avoid
		$url =~ s!  _ !$g_escape_table{'_'}!gx;		# conflicting with italics/bold.
		$url =~ s{^<(.*)>$}{$1};					# Remove <>'s surrounding URL, if present

		my $label = Header2Label($alt_text);
		$g_crossrefs{$label} = "#$label";
#		$g_titles{$label} = $alt_text;			# I think this line should not be here
			
		$result = "<img id=\"$label\" src=\"$url\" alt=\"$alt_text\"";
		if (defined $title) {
			$title =~ s! \* !$g_escape_table{'*'}!gx;
			$title =~ s!  _ !$g_escape_table{'_'}!gx;
			$result .=  " title=\"$title\"";
		}
		$result .= $g_empty_element_suffix;

		$result;
	}xsge;

	return $text;
}


sub _DoHeaders {
	my $text = shift;
	my $header = "";
	my $label = "";
	my $idString = "";
		
	# Setext-style headers:
	#	  Header 1
	#	  ========
	#  
	#	  Header 2
	#	  --------
	#
	$text =~ s{ ^(.+?)(?:\s*(?<!\\)\[([^\[]*?)\])?[ \t]*\n=+[ \t]*\n+ }{
		if (defined $2) {
			$label = Header2Label($2);
		} else {
			$label = Header2Label($1);
		}
		$header = _RunSpanGamut($1);
		$header =~ s/^\s*//s;
		
		if ($label ne "") {
			$g_crossrefs{$label} = "#$label";
			$g_titles{$label} = _StripHTML($header);
			$idString = " id=\"$label\"";			
		} else {
			$idString = "";
		}
		my $h_level = $g_base_header_level;
		
		"<h$h_level$idString>"  .  $header  .  "</h$h_level>\n\n";
	}egmx;

	$text =~ s{ ^(.+?)(?:\s*(?<!\\)\[([^\[]*?)\])?[ \t]*\n-+[ \t]*\n+ }{
		if (defined $2) {
			$label = Header2Label($2);
		} else {
			$label = Header2Label($1);
		}
		$header = _RunSpanGamut($1);
		$header =~ s/^\s*//s;
		
		if ($label ne "") {
			$g_crossrefs{$label} = "#$label";
			$g_titles{$label} = _StripHTML($header);
			$idString = " id=\"$label\"";			
		} else {
			$idString = "";
		}
		
		my $h_level = $g_base_header_level +1;
		
		"<h$h_level$idString>"  .  $header  .  "</h$h_level>\n\n";
	}egmx;


	# atx-style headers:
	#	# Header 1
	#	## Header 2
	#	## Header 2 with closing hashes ##
	#	...
	#	###### Header 6
	#
	$text =~ s{
			^(\#{1,6})	# $1 = string of #'s
			[ \t]*
			(.+?)		# $2 = Header text
			[ \t]*
			(?:(?<!\\)\[([^\[]*?)\])?	# $3 = optional label for cross-reference
			[ \t]*
			\#*			# optional closing #'s (not counted)
			\n+
		}{
			my $h_level = length($1) + $g_base_header_level - 1;
			if (defined $3) {
				$label = Header2Label($3);
			} else {
				$label = Header2Label($2);
			}
			$header = _RunSpanGamut($2);
			$header =~ s/^\s*//s;
			
			if ($label ne "") {
				$g_crossrefs{$label} = "#$label";
				$g_titles{$label} = _StripHTML($header);
				$idString = " id=\"$label\"";			
			} else {
				$idString = "";
			}

			"<h$h_level$idString>"  .  $header  .  "</h$h_level>\n\n";
		}egmx;

	return $text;
}


sub _DoLists {
#
# Form HTML ordered (numbered) and unordered (bulleted) lists.
#
	my $text = shift;
	my $less_than_tab = $g_tab_width - 1;

	# Re-usable patterns to match list item bullets and number markers:
	my $marker_ul  = qr/[*+-]/;
	my $marker_ol  = qr/\d+[.]/;
	my $marker_any = qr/(?:$marker_ul|$marker_ol)/;

	# Re-usable pattern to match any entirel ul or ol list:
	my $whole_list = qr{
		(								# $1 = whole list
		  (								# $2
			[ ]{0,$less_than_tab}
			(${marker_any})				# $3 = first list item marker
			[ \t]+
		  )
		  (?s:.+?)
		  (								# $4
			  \z
			|
			  \n{2,}
			  (?=\S)
			  (?!						# Negative lookahead for another list item marker
				[ \t]*
				${marker_any}[ \t]+
			  )
		  )
		)
	}mx;

	# We use a different prefix before nested lists than top-level lists.
	# See extended comment in _ProcessListItems().
	#
	# Note: There's a bit of duplication here. My original implementation
	# created a scalar regex pattern as the conditional result of the test on
	# $g_list_level, and then only ran the $text =~ s{...}{...}egmx
	# substitution once, using the scalar as the pattern. This worked,
	# everywhere except when running under MT on my hosting account at Pair
	# Networks. There, this caused all rebuilds to be killed by the reaper (or
	# perhaps they crashed, but that seems incredibly unlikely given that the
	# same script on the same server ran fine *except* under MT. I've spent
	# more time trying to figure out why this is happening than I'd like to
	# admit. My only guess, backed up by the fact that this workaround works,
	# is that Perl optimizes the substition when it can figure out that the
	# pattern will never change, and when this optimization isn't on, we run
	# afoul of the reaper. Thus, the slightly redundant code that uses two
	# static s/// patterns rather than one conditional pattern.

	if ($g_list_level) {
		$text =~ s{
				^
				$whole_list
			}{
				my $list = $1;
				my $list_type = ($3 =~ m/$marker_ul/) ? "ul" : "ol";

				# Turn double returns into triple returns, so that we can make a
				# paragraph for the last item in a list, if necessary:
				$list =~ s/\n{2,}/\n\n\n/g;
				my $result = _ProcessListItems($list, $marker_any);

				# Trim any trailing whitespace, to put the closing `</$list_type>`
				# up on the preceding line, to get it past the current stupid
				# HTML block parser. This is a hack to work around the terrible
				# hack that is the HTML block parser.
				$result =~ s{\s+$}{};
				$result = "<$list_type>" . $result . "</$list_type>\n";
				$result;
			}egmx;
	}
	else {
		$text =~ s{
				(?:(?<=\n\n)|\A\n?)
				$whole_list
			}{
				my $list = $1;
				my $list_type = ($3 =~ m/$marker_ul/) ? "ul" : "ol";
				# Turn double returns into triple returns, so that we can make a
				# paragraph for the last item in a list, if necessary:
				$list =~ s/\n{2,}/\n\n\n/g;
				my $result = _ProcessListItems($list, $marker_any);
				$result = "<$list_type>\n" . $result . "</$list_type>\n";
				$result;
			}egmx;
	}


	return $text;
}


sub _ProcessListItems {
#
#	Process the contents of a single ordered or unordered list, splitting it
#	into individual list items.
#

	my $list_str = shift;
	my $marker_any = shift;


	# The $g_list_level global keeps track of when we're inside a list.
	# Each time we enter a list, we increment it; when we leave a list,
	# we decrement. If it's zero, we're not in a list anymore.
	#
	# We do this because when we're not inside a list, we want to treat
	# something like this:
	#
	#		I recommend upgrading to version
	#		8. Oops, now this line is treated
	#		as a sub-list.
	#
	# As a single paragraph, despite the fact that the second line starts
	# with a digit-period-space sequence.
	#
	# Whereas when we're inside a list (or sub-list), that line will be
	# treated as the start of a sub-list. What a kludge, huh? This is
	# an aspect of Markdown's syntax that's hard to parse perfectly
	# without resorting to mind-reading. Perhaps the solution is to
	# change the syntax rules such that sub-lists must start with a
	# starting cardinal number; e.g. "1." or "a.".

	$g_list_level++;

	# trim trailing blank lines:
	$list_str =~ s/\n{2,}\z/\n/;


	$list_str =~ s{
		(\n)?							# leading line = $1
		(^[ \t]*)						# leading whitespace = $2
		($marker_any) [ \t]+			# list marker = $3
		((?s:.+?)						# list item text   = $4
		(\n{1,2}))
		(?= \n* (\z | \2 ($marker_any) [ \t]+))
	}{
		my $item = $4;
		my $leading_line = $1;
		my $leading_space = $2;

		if ($leading_line or ($item =~ m/\n{2,}/)) {
			$item = _RunBlockGamut(_Outdent($item));
		}
		else {
			# Recursion for sub-lists:
			$item = _DoLists(_Outdent($item));
			chomp $item;
			$item = _RunSpanGamut($item);
		}

		"<li>" . $item . "</li>\n";
	}egmx;

	$g_list_level--;
	return $list_str;
}



sub _DoCodeBlocks {
#
#	Process Markdown `<pre><code>` blocks.
#	

	my $text = shift;

	$text =~ s{
			(?:\n\n|\A)
			(	            # $1 = the code block -- one or more lines, starting with a space/tab
			  (?:
			    (?:[ ]{$g_tab_width} | \t)  # Lines must start with a tab or a tab-width of spaces
			    .*\n+
			  )+
			)
			((?=^[ ]{0,$g_tab_width}\S)|\Z)	# Lookahead for non-space at line-start, or end of doc
		}{
			my $codeblock = $1;
			my $result; # return value

			$codeblock = _EncodeCode(_Outdent($codeblock));
			$codeblock = _Detab($codeblock);
			$codeblock =~ s/\A\n+//; # trim leading newlines
			$codeblock =~ s/\n+\z//; # trim trailing newlines

			$result = "\n\n<pre><code>" . $codeblock . "</code></pre>\n\n";	# CHANGED: Removed newline for MMD

			$result;
		}egmx;

	return $text;
}


sub _DoCodeSpans {
#
# 	*	Backtick quotes are used for <code></code> spans.
# 
# 	*	You can use multiple backticks as the delimiters if you want to
# 		include literal backticks in the code span. So, this input:
#     
#         Just type ``foo `bar` baz`` at the prompt.
#     
#     	Will translate to:
#     
#         <p>Just type <code>foo `bar` baz</code> at the prompt.</p>
#     
#		There's no arbitrary limit to the number of backticks you
#		can use as delimters. If you need three consecutive backticks
#		in your code, use four for delimiters, etc.
#
#	*	You can use spaces to get literal backticks at the edges:
#     
#         ... type `` `bar` `` ...
#     
#     	Turns to:
#     
#         ... type <code>`bar`</code> ...
#

	my $text = shift;

	$text =~ s@
			(?<!\\)		# Character before opening ` can't be a backslash
			(`+)		# $1 = Opening run of `
			(.+?)		# $2 = The code block
			(?<!`)
			\1			# Matching closer
			(?!`)
		@
 			my $c = "$2";
 			$c =~ s/^[ \t]*//g; # leading whitespace
 			$c =~ s/[ \t]*$//g; # trailing whitespace
 			$c = _EncodeCode($c);
			"<code>$c</code>";
		@egsx;

	return $text;
}


sub _EncodeCode {
#
# Encode/escape certain characters inside Markdown code runs.
# The point is that in code, these characters are literals,
# and lose their special Markdown meanings.
#
    local $_ = shift;
	
	# Encode all ampersands; HTML entities are not
	# entities within a Markdown code span.
	s/&/&amp;/g;

	# Encode $'s, but only if we're running under Blosxom.
	# (Blosxom interpolates Perl variables in article bodies.)
	{
		no warnings 'once';
    	if (defined($blosxom::version)) {
    		s/\$/&#036;/g;	
    	}
    }


	# Do the angle bracket song and dance:
	s! <  !&lt;!gx;
	s! >  !&gt;!gx;

	# Now, escape characters that are magic in Markdown:
	s! \* !$g_escape_table{'*'}!gx;
	s! _  !$g_escape_table{'_'}!gx;
	s! {  !$g_escape_table{'{'}!gx;
	s! }  !$g_escape_table{'}'}!gx;
	s! \[ !$g_escape_table{'['}!gx;
	s! \] !$g_escape_table{']'}!gx;
	s! \\ !$g_escape_table{'\\'}!gx;

	return $_;
}


sub _DoItalicsAndBold {
	my $text = shift;

	# Cave in - `*` and `_` behave differently...  We'll see how it works out
	
	
	# <strong> must go first:
	$text =~ s{ (?<!\w) (\*\*|__) (?=\S) (.+?[*_]*) (?<=\S) \1 }
		{<strong>$2</strong>}gsx;

	$text =~ s{ (?<!\w) (\*|_) (?=\S) (.+?) (?<=\S) \1 }
		{<em>$2</em>}gsx;

	# And now, a second pass to catch nested strong and emphasis special cases
	$text =~ s{ (?<!\w) (\*\*|__) (?=\S) (.+?[*_]*) (?<=\S) \1 }
		{<strong>$2</strong>}gsx;

	$text =~ s{ (?<!\w) (\*|_) (?=\S) (.+?) (?<=\S) \1 }
		{<em>$2</em>}gsx;

	# And now, allow `*` in the middle of words

	# <strong> must go first:
	$text =~ s{ (\*\*) (?=\S) (.+?[*]*) (?<=\S) \1 }
		{<strong>$2</strong>}gsx;

	$text =~ s{ (\*) (?=\S) (.+?) (?<=\S) \1 }
		{<em>$2</em>}gsx;

	return $text;
}


sub _DoBlockQuotes {
	my $text = shift;

	$text =~ s{
		  (								# Wrap whole match in $1
			(
			  ^[ \t]*>[ \t]?			# '>' at the start of a line
			    .+\n					# rest of the first line
			  (.+\n)*					# subsequent consecutive lines
			  \n*						# blanks
			)+
		  )
		}{
			my $bq = $1;
			$bq =~ s/^[ \t]*>[ \t]?//gm;	# trim one level of quoting
			$bq =~ s/^[ \t]+$//mg;			# trim whitespace-only lines
			$bq = _RunBlockGamut($bq);		# recurse

			$bq =~ s/^/  /g;
			# These leading spaces screw with <pre> content, so we need to fix that:
			$bq =~ s{
					(\s*<pre>.+?</pre>)
				}{
					my $pre = $1;
					$pre =~ s/^  //mg;
					$pre;
				}egsx;

			"<blockquote>\n$bq\n</blockquote>\n\n";
		}egmx;


	return $text;
}


sub _FormParagraphs {
#
#	Params:
#		$text - string to process with html <p> tags
#
	my $text = shift;

	# Strip leading and trailing lines:
	$text =~ s/\A\n+//;
	$text =~ s/\n+\z//;

	my @grafs = split(/\n{2,}/, $text);

	#
	# Wrap <p> tags.
	#
	foreach (@grafs) {
		unless (defined( $g_html_blocks{$_} )) {
			$_ = _RunSpanGamut($_);
			s/^([ \t]*)/<p>/;
			$_ .= "</p>";
		}
	}

	#
	# Unhashify HTML blocks
	#
# 	foreach my $graf (@grafs) {
# 		my $block = $g_html_blocks{$graf};
# 		if (defined $block) {
# 			$graf = $block;
# 		}
# 	}

	foreach my $graf (@grafs) {
		# Modify elements of @grafs in-place...
		my $block = $g_html_blocks{$graf};
		if (defined $block) {
			$graf = $block;
			if ($block =~ m{
							\A
							(							# $1 = <div> tag
							  <div  \s+
							  [^>]*
							  \b
							  markdown\s*=\s*  (['"])	#	$2 = attr quote char
							  1
							  \2
							  [^>]*
							  >
							)
							(							# $3 = contents
							.*
							)
							(</div>)					# $4 = closing tag
							\z

							}xms
				) {
				my ($div_open, $div_content, $div_close) = ($1, $3, $4);

				# We can't call Markdown(), because that resets the hash;
				# that initialization code should be pulled into its own sub, though.
				$div_content = _HashHTMLBlocks($div_content);
				$div_content = _StripLinkDefinitions($div_content);
				$div_content = _RunBlockGamut($div_content);
				$div_content = _UnescapeSpecialChars($div_content);

				$div_open =~ s{\smarkdown\s*=\s*(['"]).+?\1}{}ms;

				$graf = $div_open . "\n" . $div_content . "\n" . $div_close;
			}
		}
	}


	return join "\n\n", @grafs;
}


sub _EncodeAmpsAndAngles {
# Smart processing for ampersands and angle brackets that need to be encoded.

	my $text = shift;

	# Ampersand-encoding based entirely on Nat Irons's Amputator MT plugin:
	#   http://bumppo.net/projects/amputator/
 	$text =~ s/&(?!#?[xX]?(?:[0-9a-fA-F]+|\w+);)/&amp;/g;

	# Encode naked <'s
 	$text =~ s{<(?![a-z/?\$!])}{&lt;}gi;

	return $text;
}


sub _EncodeBackslashEscapes {
#
#   Parameter:  String.
#   Returns:    The string, with after processing the following backslash
#               escape sequences.
#
    local $_ = shift;

    s! \\\\  !$g_escape_table{'\\'}!gx;		# Must process escaped backslashes first.
    s! \\`   !$g_escape_table{'`'}!gx;
    s! \\\*  !$g_escape_table{'*'}!gx;
    s! \\_   !$g_escape_table{'_'}!gx;
    s! \\\{  !$g_escape_table{'{'}!gx;
    s! \\\}  !$g_escape_table{'}'}!gx;
    s! \\\[  !$g_escape_table{'['}!gx;
    s! \\\]  !$g_escape_table{']'}!gx;
    s! \\\(  !$g_escape_table{'('}!gx;
    s! \\\)  !$g_escape_table{')'}!gx;
    s! \\>   !$g_escape_table{'>'}!gx;
    s! \\\#  !$g_escape_table{'#'}!gx;
    s! \\\+  !$g_escape_table{'+'}!gx;
    s! \\\-  !$g_escape_table{'-'}!gx;
    s! \\\.  !$g_escape_table{'.'}!gx;
    s{ \\!  }{$g_escape_table{'!'}}gx;

    return $_;
}


sub _DoAutoLinks {
	my $text = shift;

	$text =~ s{<((https?|ftp|dict):[^'">\s]+)>}{<a href="$1">$1</a>}gi;

	# Email addresses: <address@domain.foo>
	$text =~ s{
		<
        (?:mailto:)?
		(
			[-.\w]+
			\@
			[-a-z0-9]+(\.[-a-z0-9]+)*\.[a-z]+
		)
		>
	}{
		_EncodeEmailAddress( _UnescapeSpecialChars($1) );
	}egix;

	return $text;
}


sub _EncodeEmailAddress {
#
#	Input: an email address, e.g. "foo@example.com"
#
#	Output: the email address as a mailto link, with each character
#		of the address encoded as either a decimal or hex entity, in
#		the hopes of foiling most address harvesting spam bots. E.g.:
#
#	  <a href="&#x6D;&#97;&#105;&#108;&#x74;&#111;:&#102;&#111;&#111;&#64;&#101;
#       x&#x61;&#109;&#x70;&#108;&#x65;&#x2E;&#99;&#111;&#109;">&#102;&#111;&#111;
#       &#64;&#101;x&#x61;&#109;&#x70;&#108;&#x65;&#x2E;&#99;&#111;&#109;</a>
#
#	Based on a filter by Matthew Wickline, posted to the BBEdit-Talk
#	mailing list: <http://tinyurl.com/yu7ue>
#

	my $addr = shift;

	srand;
	my @encode = (
		sub { '&#' .                 ord(shift)   . ';' },
		sub { '&#x' . sprintf( "%X", ord(shift) ) . ';' },
		sub {                            shift          },
	);

	$addr = "mailto:" . $addr;

	$addr =~ s{(.)}{
		my $char = $1;
		if ( $char eq '@' ) {
			# this *must* be encoded. I insist.
			$char = $encode[int rand 1]->($char);
		} elsif ( $char ne ':' ) {
			# leave ':' alone (to spot mailto: later)
			my $r = rand;
			# roughly 10% raw, 45% hex, 45% dec
			$char = (
				$r > .9   ?  $encode[2]->($char)  :
				$r < .45  ?  $encode[1]->($char)  :
							 $encode[0]->($char)
			);
		}
		$char;
	}gex;

	$addr = qq{<a href="$addr">$addr</a>};
	$addr =~ s{">.+?:}{">}; # strip the mailto: from the visible part

	return $addr;
}


sub _UnescapeSpecialChars {
#
# Swap back in all the special characters we've hidden.
#
	my $text = shift;

	while( my($char, $hash) = each(%g_escape_table) ) {
		$text =~ s/$hash/$char/g;
	}
    return $text;
}


sub _TokenizeHTML {
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
#   Derived from the _tokenize() subroutine from Brad Choate's MTRegex plugin.
#       <http://www.bradchoate.com/past/mtregex.php>
#

    my $str = shift;
    my $pos = 0;
    my $len = length $str;
    my @tokens;

    my $depth = 6;
    my $nested_tags = join('|', ('(?:<[a-z/!$](?:[^<>]') x $depth) . (')*>)' x  $depth);
    my $match = qr/(?s: <! ( -- .*? -- \s* )+ > ) |  # comment
                   (?s: <\? .*? \?> ) |              # processing instruction
                   $nested_tags/ix;                   # nested tags

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

    return \@tokens;
}


sub _Outdent {
#
# Remove one level of line-leading tabs or spaces
#
	my $text = shift;

	$text =~ s/^(\t|[ ]{1,$g_tab_width})//gm;
	return $text;
}


sub _Detab {
#
# Cribbed from a post by Bart Lateur:
# <http://www.nntp.perl.org/group/perl.macperl.anyperl/154>
#
	my $text = shift;

	$text =~ s{(.*?)\t}{$1.(' ' x ($g_tab_width - length($1) % $g_tab_width))}ge;
	return $text;
}

#
# MultiMarkdown Routines
#

sub _ParseMetaData {
	my $text = shift;
	my $clean_text = "";
	
	my ($inMetaData, $currentKey) = (1,'');
	
	# If only metadata is "Format: complete" then skip
	
	if ($text =~ s/^(Format):\s*complete\n(.*?)\n/$2\n/is) {
		# If "Format: complete" was added automatically, don't force first 
		#	line of text to be metadata
		$g_metadata{$1}= "complete";
		$g_document_format = "complete";
	}
	
	foreach my $line ( split /\n/, $text ) {
		$line =~ /^$/ and $inMetaData = 0;
		if ($inMetaData) {
			if ($line =~ /^([a-zA-Z0-9][0-9a-zA-Z _-]*?):\s*(.*)$/ ) {
				$currentKey = $1;
				my $meta = $2;
				$currentKey =~ s/\s+/ /g;
				$currentKey =~ s/\s$//;
				$g_metadata{$currentKey} = $meta;
				if (lc($currentKey) eq "format") {
					$g_document_format = lc($g_metadata{$currentKey});
				}
				if (lc($currentKey) eq "base url") {
					$g_base_url = $g_metadata{$currentKey};
				}
				if (lc($currentKey) eq "bibliography title") {
					$g_bibliography_title = $g_metadata{$currentKey};
					$g_bibliography_title =~ s/\s*$//;
				}
				if (lc($currentKey) eq "base header level") {
					$g_base_header_level = $g_metadata{$currentKey};
				}
				if (!$g_metadata_newline{$currentKey}) {
					$g_metadata_newline{$currentKey} = $g_metadata_newline{default};
				}
			} else {
				if ($currentKey eq "") {
					# No metadata present
					$clean_text .= "$line\n";
					$inMetaData = 0;
					next;
				}
				if ($line =~ /^\s*(.+)$/ ) {
					$g_metadata{$currentKey} .= "$g_metadata_newline{$currentKey}$1";
				}
			}
		} else {
			$clean_text .= "$line\n";
		}
	}
		
	return $clean_text;
}

sub _StripFootnoteDefinitions {
	my $text = shift;
	my $less_than_tab = $g_tab_width - 1;

	while ($text =~ s{
		\n[ ]{0,$less_than_tab}\[\^([^\n]+?)\]\:[ \t]*# id = $1
		\n?
		(.*?)\n{1,2}		# end at new paragraph
		((?=\n[ ]{0,$less_than_tab}\S)|\Z)	# Lookahead for non-space at line-start, or end of doc
	}
	{\n}sx)
	{
		my $id = $1;
		my $footnote = "$2\n";
		$footnote =~ s/^[ ]{0,$g_tab_width}//gm;
	
		$g_footnotes{id2footnote($id)} = $footnote;
	}
	
	return $text;
}

sub _DoFootnotes {
	my $text = shift;
	
	# First, run routines that get skipped in footnotes
	foreach my $label (sort keys %g_footnotes) {
		my $footnote = _RunBlockGamut($g_footnotes{$label});

		$footnote = _DoMarkdownCitations($footnote);
		$g_footnotes{$label} = $footnote;
	}
	
	$text =~ s{
		\[\^(.+?)\]		# id = $1
	}{
		my $result = "";
		my $id = id2footnote($1);
		if (defined $g_footnotes{$id} ) {
			$g_footnote_counter++;
			if ($g_footnotes{$id} =~ /^(<p>)?glossary:/i) {
				$result = "<a href=\"#fn:$id\" id=\"fnref:$id\" title=\"see glossary\" class=\"footnote glossary\">$g_footnote_counter</a>";
			} else {
				$result = "<a href=\"#fn:$id\" id=\"fnref:$id\" title=\"see footnote\" class=\"footnote\">$g_footnote_counter</a>";
			}
			push (@g_used_footnotes,$id);
		}
		$result;
	}xsge;
	
	return $text;
}

sub _FixFootnoteParagraphs {
	my $text = shift;
	
	$text =~ s/^\<p\>\<\/footnote\>/<\/footnote>/gm;
	
	return $text;
}

sub _PrintFootnotes{
	my $footnote_counter = 0;
	my $result = "";
	
	foreach my $id (@g_used_footnotes) {
		$footnote_counter++;
		my $footnote = $g_footnotes{$id};
		my $footnote_closing_tag = "";

		$footnote =~ s/(\<\/(p(re)?|ol|ul)\>)$//;
		$footnote_closing_tag = $1;
		
		if ($footnote =~ s/^(<p>)?glossary:\s*//i) {
			# Add some formatting for glossary entries

			$footnote =~ s{
				^(.*?)				# $1 = term
				\s*
				(?:\(([^\(\)]*)\)[^\n]*)?		# $2 = optional sort key
				\n
			}{
				my $glossary = "<span class=\"glossary name\">$1</span>";
				
				if ($2) {
					$glossary.="<span class=\"glossary sort\" style=\"display:none\">$2</span>";
				};
				
				$glossary . ":<p>";	
			}egsx;

			$result.="<li id=\"fn:$id\">$footnote<a href=\"#fnref:$id\" title=\"return to article\" class=\"reversefootnote\">&#160;&#8617;</a>$footnote_closing_tag</li>\n\n";
		} else {
			$result.="<li id=\"fn:$id\">$footnote<a href=\"#fnref:$id\" title=\"return to article\" class=\"reversefootnote\">&#160;&#8617;</a>$footnote_closing_tag</li>\n\n";
		}
	}
	$result .= "</ol>\n</div>";

	if ($footnote_counter > 0) {
		$result = "\n\n<div class=\"footnotes\">\n<hr$g_empty_element_suffix\n<ol>\n\n".$result;
	} else {
		$result = "";
	}	
	
	$result= _UnescapeSpecialChars($result);
	return $result;
}

sub Header2Label {
	my $header = shift;
	my $label = lc $header;
	$label =~ s/[^A-Za-z0-9:_.-]//g;		# Strip illegal characters
	while ($label =~ s/^[^A-Za-z]//g)
		{};		# Strip illegal leading characters
	return $label;
}

sub id2footnote {
	# Since we prepend "fn:", we can allow leading digits in footnotes
	my $id = shift;
	my $footnote = lc $id;
	$footnote =~ s/[^A-Za-z0-9:_.-]//g;		# Strip illegal characters
	return $footnote;
}


sub xhtmlMetaData {
	my $result = qq{<?xml version="1.0" encoding="UTF-8" ?>\n};

	# This screws up xsltproc - make sure to use `-nonet -novalid` if you
	#	have difficulty
	if ($g_allow_mathml) {
		 $result .= qq{<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1 plus MathML 2.0//EN"\n\t"http://www.w3.org/TR/2001/REC-MathML2-20010221/dtd/xhtml-math11-f.dtd">
\n};
	
		$result.= qq{<html xmlns="http://www.w3.org/1999/xhtml">\n\t<head>\n};
	} else {
		$result .= qq{<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Strict//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd">\n};

		$result.= qq!<html xmlns="http://www.w3.org/1999/xhtml">\n\t<head>\n!;
	}
	
	$result.= "\t\t<!-- Processed by MultiMarkdown -->\n";
	
	foreach my $key (sort keys %g_metadata ) {
		# Strip trailing spaces
		$g_metadata{$key} =~ s/(\s)*$//s;
		
		# Strip spaces from key
		my $export_key = $key;
		$export_key =~ s/\s//g;
		
		if (lc($key) eq "title") {
			$result.= "\t\t<title>" . _EncodeAmpsAndAngles($g_metadata{$key}) . "</title>\n";
		} elsif (lc($key) eq "css") {
			$result.= "\t\t<link type=\"text/css\" rel=\"stylesheet\" href=\"$g_metadata{$key}\"$g_empty_element_suffix\n";
		} elsif (lc($export_key) eq "xhtmlheader") {
			$result .= "\t\t$g_metadata{$key}\n";
		} else {
			my $encodedMeta = _EncodeAmpsAndAngles($g_metadata{$key});
			$result.= qq!\t\t<meta name="$export_key" content="$encodedMeta"$g_empty_element_suffix\n!;
		}
	}
	$result.= "\t</head>\n";
	
	return $result;
}

sub textMetaData {
	my $result = "";
	
	foreach my $key (sort keys %g_metadata ) {
		$result .= "$key: $g_metadata{$key}\n";
	}
	$result =~ s/\s*\n/<br \/>\n/g;
	
	if ($result ne "") {
		$result.= "\n";
	}
	
	return $result;
}

sub _ConvertCopyright{
	my $text = shift;
	# Convert to an XML compatible form of copyright symbol
	
	$text =~ s/&copy;/&#xA9;/gi;
	
	return $text;
}


sub _DoTables {
	my $text = shift;
	my $less_than_tab = $g_tab_width - 1;
	
	# Algorithm inspired by PHP Markdown Extra's table support
	# <http://www.michelf.com/projects/php-markdown/>
		
	# Reusable regexp's to match table
	
	my $line_start = qr{
		[ ]{0,$less_than_tab}
	}mx;
	
	my $table_row = qr{
		[^\n]*?\|[^\n]*?\n
	}mx;
		
	my $first_row = qr{
		$line_start
		\S+.*?\|.*?\n
	}mx;
	
	my $table_rows = qr{
		(\n?$table_row)
	}mx;
	
	my $table_caption = qr{
		$line_start
		\[.*?\][ \t]*\n
	}mx;
	
	my $table_divider = qr{
		$line_start
		[\|\-\+\:\.][ \-\+\|\:\.]* \| [ \-\+\|\:\.]* 
	}mx;
	
	my $whole_table = qr{
		($table_caption)?		# Optional caption
		($first_row				# First line must start at beginning
		($table_row)*?)?		# Header Rows
		$table_divider			# Divider/Alignment definitions
		$table_rows+			# Body Rows
		($table_caption)?		# Optional caption
	}mx;
	
	
	# Find whole tables, then break them up and process them
	
	$text =~ s{
		^($whole_table)			# Whole table in $1
		(\n|\Z)					# End of file or 2 blank lines
	}{
		my $table = $1;
		
		# Clean extra spaces at end of lines - 
		#	they cause the processing to choke
		$table =~ s/[\t ]*\n/\n/gs;
		
		my $result = "<table>\n";
		my @alignments;
		my $use_row_header = 1;
		
		# Add Caption, if present
		
		if ($table =~ s/^$line_start(?:\[\s*(.*)\s*\])?(?:\[\s*(.*?)\s*\])[ \t]*$//m) {
			my $table_id = "";
			my $table_caption = "";

			$table_id = Header2Label($2);

			if (defined $1) {
				$table_caption = $1;
			} else {
				$table_caption = $2;
			}
			$result .= "<caption id=\"$table_id\">" . _RunSpanGamut($table_caption). "</caption>\n";
				
			$g_crossrefs{$table_id} = "#$table_id";
			$g_titles{$table_id} = "see table";		# captions with "stuff" in them break links
		}
				
		# If a second "caption" is present, treat it as a summary
		# However, this is not valid in XHTML 1.0 Strict
		# But maybe in future
		
		# A summary might be longer than one line
		if ($table =~ s/\n$line_start\[\s*(.*?)\s*\][ \t]*\n/\n/s) {
			# $result .= "<summary>" . _RunSpanGamut($1) . "</summary>\n";
		}
		
		# Now, divide table into header, alignment, and body

		# First, add leading \n in case there is no header
		
		$table = "\n" . $table;
		
		# Need to be greedy
		
		$table =~ s/\n($table_divider)\n(($table_rows)+)//s;

		my $body = "";
		my $alignment_string = "";
		if (defined $1){
			$alignment_string = $1;
		}
		if (defined $2){
			$body = $2;
		}

		# Process column alignment
		while ($alignment_string =~ /\|?\s*(.+?)\s*(\||\Z)/gs) {
			my $cell = _RunSpanGamut($1);
			if ($cell =~ /\+/){
				$result .= "<col class=\"extended\"";
			} else {
				$result .= "<col";
			}
			if ($cell =~ /\:$/) {
				if ($cell =~ /^\:/) {
					$result .= " align=\"center\"$g_empty_element_suffix\n";
					push(@alignments,"center");
				} else {
					$result .= " align=\"right\"$g_empty_element_suffix\n";
					push(@alignments,"right");
				}
			} else {
				if ($cell =~ /^\:/) {
					$result .= " align=\"left\"$g_empty_element_suffix\n";
					push(@alignments,"left");
				} else {
					if (($cell =~ /^\./) || ($cell =~ /\.$/)) {
						$result .= " align=\"char\"$g_empty_element_suffix\n";
						push(@alignments,"char");
					} else {
						$result .= "$g_empty_element_suffix\n";
						push(@alignments,"");
					}
				}
			}
		}
		
		# Process headers
		$table =~ s/^\n+//s;
		
		$result .= "<thead>\n";
		
		# Strip blank lines
		$table =~ s/\n[ \t]*\n/\n/g;
		
		foreach my $line (split(/\n/, $table)) {
			# process each line (row) in table
			$result .= "<tr>\n";
			my $count=0;
			while ($line =~ /\|?\s*([^\|]+?)\s*(\|+|\Z)/gs) {
				# process contents of each cell
				my $cell = _RunSpanGamut($1);
				my $ending = $2;
				my $colspan = "";
				if ($ending =~ s/^\s*(\|{2,})\s*$/$1/) {
					$colspan = " colspan=\"" . length($ending) . "\"";
				}
				$result .= "\t<th$colspan>$cell</th>\n";
				if ( $count == 0) {
					if ($cell =~ /^\s*$/) {
						$use_row_header = 1;
					} else {
						$use_row_header = 0;
					}
				}
				$count++;
			}
			$result .= "</tr>\n";
		}
		
		# Process body
		
		$result .= "</thead>\n<tbody>\n";

		foreach my $line (split(/\n/, $body)) {
			# process each line (row) in table
			if ($line =~ /^\s*$/) {
				$result .= "</tbody>\n\n<tbody>\n";
				next;
			}
			$result .= "<tr>\n";
			my $count=0;
			while ($line =~ /\|?\s*([^\|]+?)\s*(\|+|\Z)/gs) {
				# process contents of each cell
				my $cell = _RunSpanGamut($1);
				my $ending = "";
				if ($2 ne ""){
					$ending = $2;
				}
				my $colspan = "";
				my $cell_type = "td";
				if ($count == 0 && $use_row_header == 1) {
					$cell_type = "th";
				}
				if ($ending =~ s/^\s*(\|{2,})\s*$/$1/) {
					$colspan = " colspan=\"" . length($ending) . "\"";
				}
				if ($alignments[$count] !~ /^\s*$/) {
					$result .= "\t<$cell_type$colspan align=\"$alignments[$count]\">$cell</$cell_type>\n";
				} else {
					$result .= "\t<$cell_type$colspan>$cell</$cell_type>\n";
					}
				$count++;
			}
			$result .= "</tr>\n";
		}

		# Strip out empty <thead> sections
		$result =~ s/<thead>\s*<\/thead>\s*//s;

		# Handle pull-quotes

		# This might be too specific for my needs.  If others want it
		# removed, I am open to discussion.

		$result =~ s/<table>\s*<col \/>\s*<tbody>/<table class="pull-quote">\n<col \/>\n<tbody>/s;
		
		$result .= "</tbody>\n</table>\n";
		$result
	}egmx;
	
	my $table_body = qr{
		(								# wrap whole match in $2
			
			(.*?\|.*?)\n 					# wrap headers in $3
			
			[ ]{0,$less_than_tab}
			($table_divider) 	# alignment in $4
			
			(							# wrap cells in $5
				$table_rows
			)
		)
	}mx;
	
	return $text;
}


sub _DoAttributes{
	my $id = shift;
	my $result = "";
	
	if (defined $g_attributes{$id}) {
		my $attributes = $g_attributes{$id};
		while ($attributes =~ s/(\S+)="(.*?)"//) {
			$result .= " $1=\"$2\"";
		}
		while ($attributes =~ /(\S+)=(\S+)/g) {
			$result .= " $1=\"$2\"";
		}
	}
	
	return $result;
}


sub _StripMarkdownReferences {
	my $text = shift;
	my $less_than_tab = $g_tab_width - 1;

	while ($text =~ s{
		\n\[\#(.+?)\]:[ \t]*	# id = $1
		\n?
		(.*?)\n{1,2}			# end at new paragraph
		((?=\n[ ]{0,$less_than_tab}\S)|\Z)	# Lookahead for non-space at line-start, or end of doc
	}
	{\n}sx)
	{
		my $id = $1;
		my $reference = "$2\n";

		$reference =~ s/^[ ]{0,$g_tab_width}//gm;
		
		$reference = _RunBlockGamut($reference);

		# strip leading and trailing <p> tags (they will be added later)
		$reference =~ s/^\<p\>//s;
		$reference =~ s/\<\/p\>\s*$//s;
		
		$g_references{$id} = $reference;
	}
	
	return $text;
}

sub _DoMarkdownCitations {
	my $text = shift;
	
	$text =~ s{				# Allow for citations without locator to be written
		\[\#([^\[]*?)\]		# in usual manner, e.g. [#author][] rather than
		[ ]?				# [][#author]
		(?:\n[ ]*)?
		\[\s*\]
	}{
		"[][#$1]";
	}xsge;
	
	$text =~ s{
		\[([^\[]*?)\]		# citation text = $1
		[ ]?			# one optional space
		(?:\n[ ]*)?		# one optional newline followed by spaces
		\[\#(.*?)\]		# id = $2
	}{
		my $result;
		my $anchor_text = $1;
		my $id = $2;
		my $count;

		# implement equivalent to \citet
		my $textual_string = "";
		if ($anchor_text =~ s/^(.*?);\s*//) {
			$textual_string = "<span class=\"textual citation\">$1</span>";
		}

		if (defined $g_references{$id} ) {
			my $citation_counter=0;
			
			# See if citation has been used before
			foreach my $old_id (@g_used_references) {
				$citation_counter++;
				$count = $citation_counter if ($old_id eq $id);
			}
	
			if (! defined $count) {
				$g_citation_counter++;
				$count = $g_citation_counter;
				push (@g_used_references,$id);
			}
			
			$result = "<span class=\"markdowncitation\">$textual_string (<a href=\"#$id\" title=\"see citation\">$count</a>";
			
			if ($anchor_text ne "") {
				$result .=", <span class=\"locator\">$anchor_text</span>";
			}
			
			$result .= ")</span>";
		} else {
			# No reference exists
			$result = "<span class=\"externalcitation\">$textual_string (<a id=\"$id\">$id</a>";

			if ($anchor_text ne "") {
				$result .=", <span class=\"locator\">$anchor_text</span>";
			}
			
			$result .= ")</span>";
		}
		
		if (Header2Label($anchor_text) eq "notcited"){
			$result = "<span class=\"notcited\" id=\"$id\"/>";
		}
		$result;
	}xsge;
	
	return $text;

}

sub _PrintMarkdownBibliography{
	my $citation_counter = 0;
	my $result;
	
	foreach my $id (@g_used_references) {
		$citation_counter++;
		$result.="<div id=\"$id\"><p>[$citation_counter] <span class=\"item\">$g_references{$id}</span></p></div>\n\n";
	}
	$result .= "</div>";

	if ($citation_counter > 0) {
		$result = "\n\n<div class=\"bibliography\">\n<hr$g_empty_element_suffix\n<p>$g_bibliography_title</p>\n\n".$result;
	} else {
		$result = "";
	}	
	
	return $result;
}

sub _GenerateImageCrossRefs {
	my $text = shift;

	#
	# First, handle reference-style labeled images: ![alt text][id]
	#
	$text =~ s{
		(				# wrap whole match in $1
		  !\[
		    (.*?)		# alt text = $2
		  \]

		  [ ]?				# one optional space
		  (?:\n[ ]*)?		# one optional newline followed by spaces

		  \[
		    (.*?)		# id = $3
		  \]

		)
	}{
		my $result;
		my $whole_match = $1;
		my $alt_text    = $2;
		my $link_id     = lc $3;

		if ($link_id eq "") {
			$link_id = lc $alt_text;     # for shortcut links like ![this][].
		}

		$alt_text =~ s/"/&quot;/g;
		if (defined $g_urls{$link_id}) {
			my $label = Header2Label($alt_text);
			$g_crossrefs{$label} = "#$label";
		}
		else {
			# If there's no such link ID, leave intact:
			$result = $whole_match;
		}

		$whole_match;
	}xsge;

	#
	# Next, handle inline images:  ![alt text](url "optional title")
	# Don't forget: encode * and _

	$text =~ s{
		(				# wrap whole match in $1
		  !\[
		    (.*?)		# alt text = $2
		  \]
		  \(			# literal paren
		  	[ \t]*
			<?(\S+?)>?	# src url = $3
		  	[ \t]*
			(			# $4
			  (['"])	# quote char = $5 '
			  (.*?)		# title = $6
			  \5		# matching quote
			  [ \t]*
			)?			# title is optional
		  \)
		)
	}{
		my $result;
		my $whole_match = $1;
		my $alt_text    = $2;

		$alt_text =~ s/"/&quot;/g;
		my $label = Header2Label($alt_text);
		$g_crossrefs{$label} = "#$label";
		$whole_match;
	}xsge;

	return $text;
}

sub _FindMathEquations{
	my $text = shift;
	
	$text =~ s{
		(\<math[^\>]*)id=\"(.*?)\"> 	# "
	}{
		my $label = Header2Label($2);
		my $header = _RunSpanGamut($2);
		
		$g_crossrefs{$label} = "#$label";
		$g_titles{$label} = $header;
		
		$1 . "id=\"$label\">";
	}xsge;
	
	return $text;
}

sub _DoMathSpans {
	# Based on Gruber's _DoCodeSpans
	
	my $text = shift;
	my $display_as_block = 0;	
	$display_as_block = 1 if ($text =~ /^<<[^\>\>]*>>$/);

	$text =~ s{
			(?<!\\)		# Character before opening << can't be a backslash
			(<<)		# $1 = Opening 
			(.+?)		# $2 = The code block
			(?:\[(.+)\])?	# $3 = optional label
			(>>)
		}{
 			my $m = "$2";
			my $label = "";
			my @attr = (xmlns=>"http://www.w3.org/1998/Math/MathML");
			
			if (defined $3) {
				$label = Header2Label($3);
				my $header = _RunSpanGamut($3);

				$g_crossrefs{$label} = "#$label";
				$g_titles{$label} = $header;
			}
 			$m =~ s/^[ \t]*//g; # leading whitespace
 			$m =~ s/[ \t]*$//g; # trailing whitespace
			push(@attr,(id=>"$label")) if ($label ne "");
			push(@attr,(display=>"block")) if ($display_as_block == 1);

			$m = $mathParser->TextToMathML($m,\@attr); 
			"$m";
		}egsx;

	return $text;
}

sub _DoDefinitionLists {
	# Uses the syntax proposed by Michel Fortin in PHP Markdown Extra
	
	my $text = shift;
	my $less_than_tab = $g_tab_width -1;
	
	my $line_start = qr{
		[ ]{0,$less_than_tab}
	}mx;
	
	my $term = qr{
		$line_start
		[^:\s][^\n]*\n
	}sx;
	
	my $definition = qr{
		\n?[ ]{0,$less_than_tab}
		\:[ \t]+(.*?)\n
		((?=\n?\:)|\n|\Z)	# Lookahead for next definition, two returns,
							# or the end of the document
	}sx;
	
	my $definition_block = qr{
		((?:$term)+)				# $1 = one or more terms
		((?:$definition)+)			# $2 = by one or more definitions
	}sx;
	
	my $definition_list = qr{
		(?:$definition_block\n*)+		# One ore more definition blocks
	}sx;
	
	$text =~ s{
		($definition_list)			# $1 = the whole list
	}{
		my $list = $1;
		my $result = $1;
		
		$list =~ s{
			(?:$definition_block)\n*
		}{
			my $terms = $1;
			my $defs = $2;

			$terms =~ s{
				[ ]{0,$less_than_tab}
				(.*)
				\s*
			}{
				my $term = $1;
				my $result = "";
				$term =~ s/^\s*(.*?)\s*$/$1/;
				if ($term !~ /^\s*$/){
					$result = "<dt>" . _RunSpanGamut($1) . "</dt>\n";
				}
				$result;
			}xmge;
			
			$defs =~ s{
				$definition
			}{
				my $def = $1 . "\n";
				$def =~ s/^[ ]{0,$g_tab_width}//gm;
				"<dd>\n" . _RunBlockGamut($def) . "\n</dd>\n";
			}xsge;
			
			$terms . $defs . "\n";
		}xsge;
		
		"<dl>\n" . $list . "</dl>\n\n";
	}xsge;
	
	return $text
}

sub _UnescapeComments{
	# Remove encoding inside comments
	# Based on proposal by Toras Doran (author of Text::MultiMarkdown)

	my $text = shift;
	$text =~ s{
		(?<=<!--) # Begin comment
		(.*?)     # Anything inside
		(?=-->)   # End comments
	}{
		my $t = $1;
		$t =~ s/&amp;/&/g;
		$t =~ s/&lt;/</g;
		$t;
	}egsx;

	return $text;
}

1;

__END__


=pod

=head1 NAME

B<MultiMarkdown>


=head1 SYNOPSIS

B<MultiMarkdown.pl> [ B<--html4tags> ] [ B<--version> ] [ B<-shortversion> ]
    [ I<file> ... ]


=head1 DESCRIPTION

MultiMarkdown is an extended version of Markdown. See the website for more
information.

	http://fletcherpenney.net/multimarkdown/

Markdown is a text-to-HTML filter; it translates an easy-to-read /
easy-to-write structured text format into HTML. Markdown's text format
is most similar to that of plain text email, and supports features such
as headers, *emphasis*, code blocks, blockquotes, and links.

Markdown's syntax is designed not as a generic markup language, but
specifically to serve as a front-end to (X)HTML. You can  use span-level
HTML tags anywhere in a Markdown document, and you can use block level
HTML tags (like <div> and <table> as well).

For more information about Markdown's syntax, see:

    http://daringfireball.net/projects/markdown/


=head1 OPTIONS

Use "--" to end switch parsing. For example, to open a file named "-z", use:

	Markdown.pl -- -z

=over 4


=item B<--html4tags>

Use HTML 4 style for empty element tags, e.g.:

    <br>

instead of Markdown's default XHTML style tags, e.g.:

    <br />


=item B<-v>, B<--version>

Display Markdown's version number and copyright information.


=item B<-s>, B<--shortversion>

Display the short-form version number.


=back



=head1 BUGS

To file bug reports or feature requests (other than topics listed in the
Caveats section above) please send email to:

    support@daringfireball.net (for Markdown issues)
    
    owner@fletcherpenney.net (for MultiMarkdown issues)

Please include with your report: (1) the example input; (2) the output
you expected; (3) the output (Multi)Markdown actually produced.


=head1 AUTHOR

    John Gruber
    http://daringfireball.net/

    PHP port and other contributions by Michel Fortin
    http://michelf.com/

    MultiMarkdown changes by Fletcher Penney
    http://fletcherpenney.net/

=head1 COPYRIGHT AND LICENSE

Original Markdown Code Copyright (c) 2003-2007 John Gruber   
<http://daringfireball.net/>   
All rights reserved.

MultiMarkdown changes Copyright (c) 2005-2009 Fletcher T. Penney   
<http://fletcherpenney.net/>   
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

* Redistributions of source code must retain the above copyright notice,
  this list of conditions and the following disclaimer.

* Redistributions in binary form must reproduce the above copyright
  notice, this list of conditions and the following disclaimer in the
  documentation and/or other materials provided with the distribution.

* Neither the name "Markdown" nor the names of its contributors may
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

=cut

