#!/usr/bin/env perl
#
# $Id: addmetadata.pl 499 2008-03-23 13:03:19Z fletcher $
#
# Command line tool to prepend metadata in a MultiMarkdown document
# before processing.
#
# Copyright (c) 2006-2008 Fletcher T. Penney
#	<http://fletcherpenney.net/>
#
# MultiMarkdown Version 2.0.b6
#

# grab metadata from args

my $result = "";

foreach $data (@ARGV) {
	$result .= $data . "\n";	
}

@ARGV = ();

# grab document from stdin

undef $/;
$result .= <>;


print $result;