#!/usr/bin/env perl
#
# mmd2OPML.pl
#
# Utility script to convert MultiMarkdown files into OPML
#
# Copyright (c) 2010 Fletcher T. Penney
#	<http://fletcherpenney.net/>
#
#

# This script will process the text received via stdin, and output to stdout,
# OR
# will accept a list of files, and process each file individually.
#
# If a list of files is received, the input from "test.txt" will be output
# to "test.opml", for example.

use strict;
use warnings;

use File::Basename;
use Cwd;
use Cwd 'abs_path';

# Determine whether we are in "file mode" or "stdin mode"

my $count = @ARGV;

if ($count == 0) {
	# We're in "stdin mode"

	# process stdin
	undef $/;
	my $data .= <>;

	#MultiMarkdown::Support::ProcessMMD2XHTML($MMDPath, "", $data);
	convertToOPML("", $data);

} else {
	# We're in "file mode"

	foreach(@ARGV) {
		# process each file individually

		# warn if directory
		if ( -d $_ ) {
			warn "This utility will not process directories.  Please specify the files to process.\n";
		} elsif ( -f $_ ) {
			# Determine filenames
			my $filename = $_;

			# Read input and process
			open(INPUT, "<$filename");
			local $/;
			my $data .= <INPUT>;
			close(INPUT);

			#MultiMarkdown::Support::ProcessMMD2XHTML($MMDPath, $filename, $data);
			convertToOPML($filename, $data);
		} else {
			system("perldoc $0");
		}
	}
}


sub convertToOPML {
	my ($filename, $data) = @_;
	my $output = "";
	
	(my $title = $filename) =~ s/^(.*\/)?(.*?)(\..*)?$/$2/;
	
	# Add OPML header
	$output .= qq{<?xml version="1.0" encoding="utf-8"?>
<opml version="1.0">
	<head>
		<title>$title</title>
	</head>
	<body>
};

	# Move metadata to end
	my $meta = "";
	
	$data =~ s{
		\A([^\n]+\:[^\n]+
		.*?)
		\n\n
	}{
		$meta = $1;
		"";
	}emsx;

	$meta =~ s{
		^([^\s][^\n\:]+?)\:[\t ]*(.*?)(?=(\n[^\t ])|\Z)$
	}{
		"## $1\n\n$2\n\n";
	}egmxs;
	
	$data .= "\n# Metadata\n\n$meta\n";

	# Convert protected characters
	
	$data =~ s/&/&amp;/g;
	$data =~ s/</&lt;/g;
	$data =~ s/>/&gt;/g;
	$data =~ s/"/&quot;/g;
	
	
	# Split into sections
	
	$data =~ s{
		^(\#{1,6})	# $1 = string of #'s
		[ \t]*
		(.+?)		# $2 = Header text
		[ \t]*
		\#*			# optional closing #'s (not counted)
		\n+
	}{
		my $h_level = length($1);
		"\n<outline _level=\"$h_level\" text=\"$2\" _note=\""; 
	}egmx;

	# Add closing tags for <text>
	
	$data =~ s{
		_note="
		(.*?)
		\n*\<outline
	}{
		my $body = $1;
		$body =~ s/(\n|\r)/&#10;/g;
		"_note=\"$body\">\n<outline";
	}egsx;
	
	$data =~ s{
		_note="
		(.*?)
		\s*\Z
	}{
		my $body = $1;
		$body =~ s/(\n|\r)/&#10;/g;
		"_note=\"$body\"\/>\n";
	}egsx;

	$data =~ s/&#10;<outline/\n<outline/g;
	
	# Now, reorganize outline sections into proper hierarchy
	my $last_depth = 0;
	
	$data =~ s{
		\<outline
		\s+
		_level="(.*?)" (.*?)\>
		\n?
	}{
		my $current_depth = $1;
		my $headers = $2;
		my $result = "";
		if ($current_depth > $last_depth) {
			# Nest
			my $delta = $current_depth - $last_depth;
			for (my $i = 0; $i < $delta; $i++) {
				$result .= "<outline $headers>\n";
			}
		} else {
			my $delta = $last_depth - $current_depth;
			for (my $i = 0; $i <= $delta; $i++) {
				$result .= "</outline>\n";
			}
			$result .= "<outline $headers>\n";
		}
		$last_depth = $current_depth;
		$result;
	}egsx;
	
	for (my $i = 1; $i < $last_depth; $i++) {
		$data .= "</outline>\n";
	}	
	
	# close document
	$output .= $data;
	
	$output .= "\n	</body>
</opml>
";

	if ($filename ne "") {
		my $output_file = _Input2Output($filename, "opml");
		open(MMD, ">$output_file") or die $!;
		print MMD $output;
		close(MMD);
	} else {
		print $output;
	}
	
}


sub _Input2Output {
	# Convert the filename given to an output file with new extension
	my $input_file = shift;
	my $file_extension = shift;
	my $output_file = abs_path($input_file);
	
	$output_file =~ s/\.[^\.\\\/]*?$/.$file_extension/;		# strip extension
	
	return $output_file;
}


=head1 NAME

mmd2OPML - utility script for MultiMarkdown to convert MultiMarkdown text
into OPML.

=head1 SYNOPSIS

mmd2OPML.pl [file ...]


=head1 DESCRIPTION

This script is designed as a "front-end" for MultiMarkdown. It can convert a
series of text files into OPML.


=head1 SEE ALSO

Designed for use with MultiMarkdown.

<http://fletcherpenney.net/multimarkdown/>

Mailing list support for MultiMarkdown:

<http://groups.google.com/group/multimarkdown/>

	OR

<mailto:multimarkdown@googlegroups.com>

=head1 AUTHOR

Fletcher T. Penney, E<lt>owner@fletcherpenney.netE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2010 by Fletcher T. Penney

This program is free software; you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation; either version 2 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the
   Free Software Foundation, Inc.
   59 Temple Place, Suite 330
   Boston, MA 02111-1307 USA

=cut