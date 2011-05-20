#!/usr/bin/env perl
##
# Utility script to process OPML files back into MMD
#
# Copyright (c) 2010 Fletcher T. Penney
#	<http://fletcherpenney.net/>
#

# This script will process the text received via stdin, and output to stdout,
# OR
# will accept a list of files, and process each file individually.
#
# If a list of files is received, the input from "test.opml" will be output
# to "test.txt", for example.

use strict;
use warnings;

use File::Basename;
use Cwd;
use Cwd 'abs_path';


# Determine where MMD is installed.  Use a "common installation" if available.

my $me = $0;		# Where is this script located?
my $MMDPath = LocateMMD($me);


# Determine whether we are in "file mode" or "stdin mode"

my $count = @ARGV;

if ($count == 0) {
	# We're in "stdin mode"

	# process stdin
	undef $/;
	my $data .= <>;

	MultiMarkdown::Support::ProcessOPML2MMD($MMDPath, "", $data);

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
			my $data = <INPUT>;
			close(INPUT);

			MultiMarkdown::Support::ProcessOPML2MMD($MMDPath, $filename, $data);
		} else {
			system("perldoc $0");
		}
	}
}

sub LocateMMD {
	my $me = shift;		# Where am I running from?

	my $os = $^O;	# Mac = darwin; Linux = linux; Windows contains MSWin
	my $MMDPath = "";

	# Determine where MMD is installed.  Use a "common installation"
	# if available.

	$me = dirname($me);

	if ($os =~ /MSWin/) {
		# We're running Windows
	
		# First check our directory to see if we're running inside MMD
		
		if ( -f "$me\\MultiMarkdown\\Support.pm") {
			$MMDPath = "$me\\..";
		}
		
		# Next, look in user's home directory, then in common directories
		if ($MMDPath eq "") {
			if ( -d "$ENV{HOMEDRIVE}$ENV{HOMEPATH}\\MultiMarkdown") {
				$MMDPath = "$ENV{HOMEDRIVE}$ENV{HOMEPATH}\\MultiMarkdown";
			} elsif ( -d "$ENV{HOMEDRIVE}\\Documents and Settings\\All Users\\MultiMarkdown") {
				$MMDPath = "$ENV{HOMEDRIVE}\\Documents and Settings\\All Users\\MultiMarkdown";
			}
		}

		# Load the MultiMarkdown::Support.pm module
		do "$MMDPath\\bin\\MultiMarkdown\\Support.pm" if ($MMDPath ne "");
	} else {
		# We're running Mac OS X or some *nix
		
		# First check our directory to see if we're running inside MMD
		
		if ( -f "$me/MultiMarkdown/Support.pm") {
			$MMDPath = "$me/..";
		}
		
		# Next, look in user's home directory, then in common directories
		if ($MMDPath eq "") {
			if (defined($ENV{HOME})) {
				if ( -d "$ENV{HOME}/Library/Application Support/MultiMarkdown") {
					$MMDPath = "$ENV{HOME}/Library/Application Support/MultiMarkdown";
				} elsif ( -d "$ENV{HOME}/.multimarkdown") {
					$MMDPath = "$ENV{HOME}/.multimarkdown";	
				}
			}
			if ($MMDPath eq "") {
				if ( -d "/Library/Application Support/MultiMarkdown") {
					$MMDPath = "/Library/Application Support/MultiMarkdown";
				} elsif ( -d "/usr/share/multimarkdown") {
					$MMDPath = "/usr/share/multimarkdown";
				}
			}
		}
	}

	if ($MMDPath eq "") {
		die "You do not appear to have MultiMarkdown installed.\n";
	} else {
		# Load the MultiMarkdown::Support.pm module
		$MMDPath = abs_path($MMDPath);
		LoadModule("$MMDPath/bin/MultiMarkdown/Support.pm");
	}

	# Clean up the path
	$MMDPath = abs_path($MMDPath);

	return $MMDPath;
}

sub LoadModule {
	my $file = shift;
	my $os = $^O;	# Mac = darwin; Linux = linux; Windows contains MSWin

	if ($os =~ /MSWin/) {
		# Not sure what I can do her
	} else {
		unless (my $return = eval `cat "$file"`) {
			warn "couldn't parse $file: $@" if $@;
			warn "couldn't do $file: $!" unless defined $return;
			warn "couldn't run $file" unless $return;
		}
	}
}

=head1 NAME

OPML2mmd - utility script for MultiMarkdown to convert OPML back into
MultiMarkdown text.

=head1 SYNOPSIS

OPML2mmd.pl [file ...]


=head1 DESCRIPTION

This  script is  designed as  a  "reversal" for  MultiMarkdown generated  OPML
files. It can convert a series of text files from OPML back into MultiMarkdown
text files.


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

This program is free software; you  can redistribute it and/or modify it under
the terms of the GNU General Public  License as published by the Free Software
Foundation; either  version 2 of  the License, or  (at your option)  any later
version.

This program is  distributed in the hope  that it will be  useful, but WITHOUT
ANY WARRANTY; without even the  implied warranty of MERCHANTABILITY or FITNESS
FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received  a copy of the GNU General  Public License along with
this program; if not, write to the

   Free Software Foundation, Inc.
   59 Temple Place, Suite 330
   Boston, MA 02111-1307 USA

=cut