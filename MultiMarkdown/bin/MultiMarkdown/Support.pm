#
# $Id: Support.pm 534 2009-06-19 20:52:55Z fletcher $
#
# MultiMarkdown Version 2.0.b6
#

# TODO: Add an option to turn SmartyPants off?

package MultiMarkdown::Support;

# use 5.00;
use strict;
use warnings;

use File::Basename;
use File::Path;
use File::Temp qw/tempdir/;
use File::Copy;
use File::Glob qw/:globally/;
use Cwd;
use Cwd 'abs_path';


use vars qw(%g_metadata);

our $VERSION = '1.0';

sub ProcessMMD2XHTML {
	my $MMDPath = shift;
	my $input_file = shift;
	my $text = "Format: complete\n";
	$text .= shift;
	
	my $output_file = "";
	$output_file = _Input2Output($input_file, "html") if ($input_file ne "");
	
	my $SmartyPants = _WhichSmarty($text);
	my $xslt_file = _XhtmlXSLT($text);
	
	# Generate the pipe command and run
	
	my $os = $^O;
	my $xslt = "";
	my $out = "";
	
	if ($input_file ne "") {
		$out = "> \"$output_file\"";
	}
	
	if ($os =~ /MSWin/) {
		$xslt = "| xsltproc -nonet -novalid XSLT\\$xslt_file -" if ($xslt_file ne "");
		$MMDPath =~ s/\//\\/g;
		open (MultiMarkdown, "| cd $MMDPath & perl bin\\MultiMarkdown.pl | perl bin\\$SmartyPants $xslt $out");
	} else {
		$xslt = "| xsltproc -nonet -novalid XSLT/$xslt_file -" if ($xslt_file ne "");
		open (MultiMarkdown, "| cd \"$MMDPath\"; bin/MultiMarkdown.pl | bin/$SmartyPants $xslt $out");
	}
	
	print MultiMarkdown $text;
	close (MultiMarkdown);
}

sub ProcessMMD2RTF {
	my $MMDPath = shift;
	my $input_file = shift;
	my $text = "Format: complete\n";
	$text .= shift;

	my $output_file = "";
	$output_file = _Input2Output($input_file, "rtf") if ($input_file ne "");
	
	my $SmartyPants = _WhichSmarty($text);
	my $xslt_file = _RTFXSLT($text);
	$xslt_file = "xhtml2rtf.xslt" if ($xslt_file eq "");	# Default
	
	# Generate the pipe command and run
	
	my $os = $^O;
	my $xslt = "";
	my $out = "";
	
	if ($input_file ne "") {
		$out = "> \"$output_file\"";
	}
	
	if ($os =~ /MSWin/) {
		$xslt = "| xsltproc -nonet -novalid XSLT\\$xslt_file -" if ($xslt_file ne "");
		$MMDPath =~ s/\//\\/g;
		# TOD: This version won't crash on windows, but the regexp's aren't
		# quite right.  I welcome input from Windows users but I'm tired of
		# messing with it myself for the time being.
		my $command = "| cd \"$MMDPath\" & perl -pi -e \"s/(?<![ \\\\])\\n/\\n/g\" | perl bin\\MultiMarkdown.pl | perl bin\\$SmartyPants $xslt | perl -pi -e \"s/(?<![ \\.])(?<!\\\\[fsi]\\d)(?<!\\\\fs\\d\\d)  +/ /g\" | perl -pi -e \"s/\\.   +/.  /g\"  | perl -pi -e \"s/^ +//mg\" $out";
		open (MultiMarkdown, $command);
	} else {
		$xslt = "| xsltproc -nonet -novalid XSLT/$xslt_file -" if ($xslt_file ne "");
		open (MultiMarkdown, "| cd \"$MMDPath\"; perl -pi -e 's/(?<![ #\\\\])\n/ \n/g' | bin/MultiMarkdown.pl | bin/$SmartyPants $xslt | perl -pi -e 's/(?<![ \.])(?<!\\\\[fsi]\\d)(?<!\\\\fs\\d\\d)  +/ /g' | perl -pi -e 's/\.   +/.  /g'  | perl -pi -e 's/^ +//mg' $out");
	}
	
	print MultiMarkdown $text;
	close (MultiMarkdown);
}

sub ProcessMMD2LaTeX {
	my $MMDPath = shift;
	my $input_file = shift;
	my $text = "Format: complete\n";
	$text .= shift;

	my $output_file = "";
	$output_file = _Input2Output($input_file, "tex") if ($input_file ne "");
	
	my $SmartyPants = _WhichSmarty($text);
	my $xslt_file = _LatexXSLT($text);
	$xslt_file = "memoir.xslt" if ($xslt_file eq "");	# Default to memoir
	
	# Generate the pipe command and run
	
	my $os = $^O;
	my $xslt = "";
	my $out = "";
	
	if ($input_file ne "") {
		$out = "> \"$output_file\"";
	}
	
	if ($os =~ /MSWin/) {
		$xslt = "| xsltproc -nonet -novalid XSLT\\$xslt_file -" if ($xslt_file ne "");
		$MMDPath =~ s/\//\\/g;
		open (MultiMarkdown, "| cd \"$MMDPath\" & perl bin\\MultiMarkdown.pl | perl bin\\$SmartyPants $xslt | perl Utilities\\cleancites.pl $out");
	} else {
		$xslt = "| xsltproc -nonet -novalid XSLT/$xslt_file -" if ($xslt_file ne "");
		open (MultiMarkdown, "| cd \"$MMDPath\"; bin/MultiMarkdown.pl | bin/$SmartyPants $xslt | Utilities/cleancites.pl $out");
	}
	
	print MultiMarkdown $text;
	close (MultiMarkdown);
}


sub ProcessMMD2PDF {
	my $MMDPath = shift;
	my $input_file = shift;
	my $text = shift;

	# These are not all necessary for simple files, but are included to try
	# and be as thorough as possible...  Sort of a poor man's latexmk.pl
	
	my $tex_string = "; pdflatex mmd.tex; bibtex mmd; makeindex -t mmd.glg -o mmd.gls -s mmd.ist mmd.glo; makeindex -s `kpsewhich basic.gst` -o mmd.gls mmd.glo; pdflatex mmd.tex; pdflatex mmd.tex; pdflatex mmd.tex; pdflatex mmd.tex";

	if ($^O =~ /MSWin/) {
		$tex_string = "& pdflatex mmd.tex & bibtex mmd & makeindex -t mmd.glg -o mmd.gls -s mmd.ist mmd.glo & makeindex -s `kpsewhich basic.gst` -o mmd.gls mmd.glo & pdflatex mmd.tex & pdflatex mmd.tex & pdflatex mmd.tex & pdflatex mmd.tex";
	}	
	PDFEngine($MMDPath, $input_file, $tex_string, $text);

}


sub ProcessMMD2PDFXeLaTeX {
	my $MMDPath = shift;
	my $input_file = shift;
	my $text = shift;

	# These are not all necessary for simple files, but are included to try
	# and be as thorough as possible...  Sort of a poor man's latexmk.pl

	my $tex_string = "; xelatex mmd.tex; bibtex mmd; makeindex -t mmd.glg -o mmd.gls -s mmd.ist mmd.glo; makeindex -s `kpsewhich basic.gst` -o mmd.gls mmd.glo; xelatex mmd.tex; xelatex mmd.tex; xelatex mmd.tex; xelatex mmd.tex";

	if ($^O =~ /MSWin/) {
		$tex_string = "& xelatex mmd.tex & bibtex mmd & makeindex -t mmd.glg -o mmd.gls -s mmd.ist mmd.glo & makeindex -s `kpsewhich basic.gst` -o mmd.gls mmd.glo & xelatex mmd.tex & xelatex mmd.tex & xelatex mmd.tex & xelatex mmd.tex";
	}
	PDFEngine($MMDPath, $input_file, $tex_string, $text);
}

sub ProcessXHTML2MMD {
	my $MMDPath = shift;
	my $input_file = shift;
	my $text = shift;
	
	my $output_file = "";
	$output_file = _Input2Output($input_file, "txt") if ($input_file ne "");
	
	my $xslt_file = "multimarkdown.xslt";
	
	# Generate the pipe command and run
	
	my $os = $^O;
	my $xslt = "";
	my $out = "";
	
	if ($input_file ne "") {
		$out = "> \"$output_file\"";
	}
	
	if ($os =~ /MSWin/) {
		$xslt = "| xsltproc -nonet -novalid XSLT\\$xslt_file -" if ($xslt_file ne "");
		$MMDPath =~ s/\//\\/g;
		open (MultiMarkdown, "| cd \"$MMDPath\" & xsltproc -nonet -novalid XSLT\\$xslt_file - $out");
	} else {
		$xslt = "| xsltproc -nonet -novalid XSLT/$xslt_file -" if ($xslt_file ne "");
		open (MultiMarkdown, "| cd \"$MMDPath\"; xsltproc -nonet -novalid XSLT/$xslt_file - $out");
	}
	
	print MultiMarkdown $text;
	close (MultiMarkdown);	
}


sub ProcessOPML2MMD {
	my $MMDPath = shift;
	my $input_file = shift;
	my $text = shift;
	
	# Preserve tab characters
	$text =~ s/\t/&#9;/g;
	
	my $output_file = "";
	$output_file = _Input2Output($input_file, "txt") if ($input_file ne "");
	
	my $xslt_file = "opml2mmd.xslt";
	
	# Generate the pipe command and run
	
	my $os = $^O;
	my $xslt = "";
	my $out = "";
	
	if ($input_file ne "") {
		$out = "> \"$output_file\"";
	}
	
	if ($os =~ /MSWin/) {
		$xslt = "| xsltproc -nonet -novalid XSLT\\$xslt_file -" if ($xslt_file ne "");
		$MMDPath =~ s/\//\\/g;
		open (MultiMarkdown, "| cd \"$MMDPath\" & xsltproc -nonet -novalid XSLT\\$xslt_file - $out");
	} else {
		$xslt = "| xsltproc -nonet -novalid XSLT/$xslt_file -" if ($xslt_file ne "");
		open (MultiMarkdown, "| cd \"$MMDPath\"; xsltproc -nonet -novalid XSLT/$xslt_file - $out");
	}
	
	print MultiMarkdown $text;
	close (MultiMarkdown);	
}


sub PDFEngine {
	my $MMDPath = shift;
	my $input_file = shift;
	my $tex_string = shift;
	my $text = shift;

	my $latex_file = _Input2Output($input_file, "tex");
	my $output_file = _Input2Output($input_file, "pdf");
	my $parent_folder = dirname($latex_file);
	my $temp_tex_file = "";
	my @support_files = ();
		
	# Create a temporary working folder
	my $temp_folder = tempdir();

	# Create the LaTeX file
	ProcessMMD2LaTeX($MMDPath, $input_file, $text);
		
	if ($^O =~ /MSWin/) {
		# We're in Windows
		$temp_folder =~ s/\//\\/g;
		$parent_folder =~ s/\\/\//g;
		$temp_tex_file = "$temp_folder\\mmd.tex";
		@support_files = <'$parent_folder\\*.{bib,pdf,png,gif,jpg}'>;
	} else {
		# Not in Windows
		$temp_tex_file = "$temp_folder/mmd.tex";
		my $temp_parent_folder = $parent_folder;
		$temp_parent_folder =~ s/ /\\ /g;
		@support_files = <$temp_parent_folder/*.{bib,pdf,png,gif,jpg}>;
	
		# Try to be sure we have access to the LaTeX binaries in our PATH,
		# especially if they were installed by Fink
		$ENV{'PATH'} .= ':/usr/texbin:/usr/local/teTeX/bin/powerpc-apple-darwin-current:/sw/bin';
	}

	# Copy tex into temp directory
	copy($latex_file, $temp_tex_file);

	# Copy possible images, .bib files, etc to the temp folder
	copy($_,$temp_folder) foreach(@support_files);

	# Now, do the latex stuff
	system("cd \"$temp_folder\" $tex_string");
	
	# Retrieve the pdf
	my $temp_pdf_file = _Input2Output($temp_tex_file, "pdf");
	copy($temp_pdf_file, $output_file);
	
	# Remove temporary files
	File::Path::rmtree($temp_folder);
}

sub _Input2Output {
	# Convert the filename given to an output file with new extension
	my $input_file = shift;
	my $file_extension = shift;
	my $output_file = abs_path($input_file);
	
	$output_file =~ s/\.[^\.\\\/]*?$/.$file_extension/;		# strip extension
	
	return $output_file;
}

sub _WhichSmarty {
	my $text = shift;
	my $language = _Language($text);
	
	if ($language =~ /^\s*german\s*$/i) {
		return "SmartyPantsGerman.pl";
	} elsif ($language =~ /^\s*french\s*$/i) {
		return "SmartyPantsFrench.pl";
	} elsif ($language =~ /^\s*swedish|norwegian|finnish|danish\s*$/i) {
		return "SmartyPantsSwedish.pl";
	} elsif ($language =~ /^\s*dutch\s*$/i) {
		return "SmartyPantsDutch.pl";
	}
	
	return "SmartyPants.pl";
}

sub _Language {
	my $text = shift;
	
	my ($inMetaData, $currentKey) = (1,'');
	
	foreach my $line ( split /\n/, $text ) {
		$line =~ /^$/ and $inMetaData = 0 and next;
		if ($inMetaData) {
			if ($line =~ /^([a-zA-Z0-9][0-9a-zA-Z _-]*?):\s*(.*)$/ ) {
				$currentKey = $1;
				$currentKey =~ s/  / /g;
				$g_metadata{$currentKey} = $2;
				if (lc($currentKey) eq "language") {
					return $g_metadata{$currentKey};
				}
			} else {
				if ($currentKey eq "") {
					# No metadata present
					$inMetaData = 0;
					next;
				}
			}
		}
	}
		
	return "";
}

sub _XhtmlXSLT {
	my $text = shift;
	
	my ($inMetaData, $currentKey) = (1,'');
	
	foreach my $line ( split /\n/, $text ) {
		$line =~ /^$/ and $inMetaData = 0 and next;
		if ($inMetaData) {
			if ($line =~ /^([a-zA-Z0-9][0-9a-zA-Z _-]*?):\s*(.*)$/ ) {
				$currentKey = $1;
				my $temp = $2;
				$currentKey =~ s/ //g;
				$g_metadata{$currentKey} = $temp;
				if (lc($currentKey) eq "xhtmlxslt") {
					$g_metadata{$currentKey} =~ s/\s*(\.xslt)?\s*$/.xslt/;
					return $g_metadata{$currentKey};
				}
			} else {
				if ($currentKey eq "") {
					# No metadata present
					$inMetaData = 0;
					next;
				}
			}
		}
	}
		
	return "";
}

sub _LatexXSLT {
	my $text = shift;
	
	my ($inMetaData, $currentKey) = (1,'');
	
	foreach my $line ( split /\n/, $text ) {
		$line =~ /^$/ and $inMetaData = 0 and next;
		if ($inMetaData) {
			if ($line =~ /^([a-zA-Z0-9][0-9a-zA-Z _-]*?):\s*(.*)$/ ) {
				$currentKey = $1;
				my $temp = $2;
				$currentKey =~ s/ //g;
				$g_metadata{$currentKey} = $temp;
				if (lc($currentKey) eq "latexxslt") {
					$g_metadata{$currentKey} =~ s/\s*(\.xslt)?\s*$/.xslt/;
					return $g_metadata{$currentKey};
				}
			} else {
				if ($currentKey eq "") {
					# No metadata present
					$inMetaData = 0;
					next;
				}
			}
		}
	}
	
	return "";
}


sub _RTFXSLT {
	my $text = shift;
	
	my ($inMetaData, $currentKey) = (1,'');
	
	foreach my $line ( split /\n/, $text ) {
		$line =~ /^$/ and $inMetaData = 0 and next;
		if ($inMetaData) {
			if ($line =~ /^([a-zA-Z0-9][0-9a-zA-Z _-]*?):\s*(.*)$/ ) {
				$currentKey = $1;
				my $temp = $2;
				$currentKey =~ s/ //g;
				$g_metadata{$currentKey} = $temp;
				if (lc($currentKey) eq "rtfxslt") {
					$g_metadata{$currentKey} =~ s/\s*(\.xslt)?\s*$/.xslt/;
					return $g_metadata{$currentKey};
				}
			} else {
				if ($currentKey eq "") {
					# No metadata present
					$inMetaData = 0;
					next;
				}
			}
		}
	}
	
	return "";
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
		# Not sure what I can do here
	} else {
		unless (my $return = eval `cat "$file"`) {
			warn "couldn't parse $file: $@" if $@;
			warn "couldn't do $file: $!" unless defined $return;
			warn "couldn't run $file" unless $return;
		}
	}
}


1;
__END__

=head1 NAME

MultiMarkdown::Support - Perl extension to provide support routines to 
MultiMarkdown utility scripts.

=head1 SYNOPSIS

use MultiMarkdown::Support;

=head1 FUNCTIONS

LocateMMD(path/to/script/that/was/running);

=over 4

Returns the path to the MultiMarkdown installation to be used. It first tries
for a "common installation", and then checks the parent of the running script.

Unless the module is properly installed, and loaded first, this routine is not
likely to be needed and should be embedded in the utility script. See
mmd2XHTML for an example.

=back

ProcessMMD2XHTML(Path/to/MultiMarkdown, input_filename, multimarkdown_text);

ProcessMMD2LaTeX(Path/to/MultiMarkdown, input_filename, multimarkdown_text);

ProcessMMD2PDF(Path/to/MultiMarkdown, input_filename, multimarkdown_text);

ProcessMMD2PDFXeLaTeX(Path/to/MultiMarkdown, input_filename, multimarkdown_text);

=over 4

These routines convert the raw MultiMarkdown text into the appropriate format.
If a filename is specified, the output is written to a file with an
appropriate extension. Otherwise, when possible, it is presented on stdout.

=back

=head1 DESCRIPTION

This module contains some of the core code used by the MultiMarkdown utility 
scripts (mmd2XHTML, mmd2LaTeX, etc).  The idea is to try and centralize as 
much of that code as possible to simplify maintaining everything else.


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