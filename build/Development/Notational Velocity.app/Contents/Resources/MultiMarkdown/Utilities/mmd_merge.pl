#!/usr/bin/env perl
#
# mmd_merge.pl
#
# Combine text documents to create a MultiMarkdown structured document
#
# Copyright (c) 2009 Fletcher T. Penney
#	<http://fletcherpenney.net/>
#
# MultiMarkdown Version 2.0.b6
#

use strict;
use warnings;

my $data = "";
my $line = "";

my $count = @ARGV;

if ($count == 0) {
	# We're in "stdin mode"

	# process stdin
	undef $/;
	my $data .= <>;

	mergeLines($data);
} else {
	foreach(@ARGV) {
		open(INPUT, "<$_");
		local $/;
		my $data = <INPUT>;
		close(INPUT);
		mergeLines($data);
	}
}


sub mergeLines {
	my $file = shift;
	
	while ($file =~ /^(.*?)$/mg) {
		$line = $1;
		if (($line !~ /^\s*$/) && ($line !~ /^\#/)) {
			$line =~ s/ {4}/\t/g;
			$line =~ s/\s*$//;
			my $indent = ($line =~ tr/\t/\t/);
			$line =~ /^\s*(.*?)\s*$/;
			
			open(FILE, "<$1");
			local $/;
			my $file = <FILE>;
			close FILE;
			
			for (my $i = 0; $i< $indent; $i++) {
				$file =~ s/^\#/##/gm;
			}
			
			$data .= $file;
		}
	}
	
	print $data;
}

=head1 NAME

mmd_merge.pl - Combine text documents to create a MultiMarkdown structured
document.

=head1 SYNOPSIS

mmd_merge.pl [file ...]


=head1 DESCRIPTION

This script is designed to allow you to use different files to store parts of
a larger MultiMarkdown document, making it easier to reorganize the document
if you so desire. Each line consists of the url or filename of the next
document. If the line is indented, each tab (or 4 spaces) will increase the
header level of the document by 1 (similar to the `Base Header Level`
metadata). Blank lines are ignored. Lines starting with `#` are treated as
comments. Only metadata from the first file would be properly handles, since
it would be the only metadata at the top of the new "virtual" document.

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

Copyright (C) 2009 by Fletcher T. Penney

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
