#!/usr/bin/env perl
#
# $Id: multimarkdown2RTF.pl 508 2008-07-15 18:52:05Z fletcher $
#
# Required for using MultiMarkdown
#
# Copyright (c) 2006-2008 Fletcher T. Penney
#	<http://fletcherpenney.net/>
#
# MultiMarkdown Version 2.0.b6
#

# Combine all the steps necessary to process MultiMarkdown text into RTF
# Not necessary, but might be easier than stringing the commands together
# manually
#
# Known Limitation: The temporary file is erased to 0 bytes, but not removed.
# I appreciate input on fixing this....


# Add metadata to guarantee we can transform to a complete XHTML
$data = "Format: complete\n";


# Parse stdin (MultiMarkdown file)

undef $/;
$data .= <>;


# Find name of RTF XSLT, if specified
$xslt_file = _RtfXSLT($data);
# $xslt_file = "memoir.xslt" if ($xslt_file eq "");
$xslt = "";

# Decide which flavor of SmartyPants to use
$language = _Language($data);
$SmartyPants = "SmartyPants.pl";

$SmartyPants = "SmartyPantsGerman.pl" if ($language =~ /^\s*german\s*$/i);

$SmartyPants = "SmartyPantsFrench.pl" if ($language =~ /^\s*french\s*$/i);

$SmartyPants = "SmartyPantsSwedish.pl" if ($language =~ /^\s*(swedish|norwegian|finnish|danish)\s*$/i);

$SmartyPants = "SmartyPantsDutch.pl" if ($language =~ /^\s*dutch\s*$/i);


# Create a pipe and process
$me = $0;				# Where am I?


# Am I running in Windoze?
my $os = $^O;

if ($os =~ /MSWin/) {
	$me =~ s/\\([^\\]*?)$/\\/;	# Get just the directory portion
} else {
	$me =~ s/\/([^\/]*?)$/\//;	# Get just the directory portion	
}

# Create a temp file for textutil (doesn't work on stdin)
$temp_file = readpipe("mktemp -t multimarkdownXXXXX");

# Process XHTML and convert to rtf

if ($os =~ /MSWin/) {
	# Of course, there is no textutil, so this doesn't really
	# make any sense under Windows - just output the XHTML
	$xslt = "| xsltproc -nonet -novalid ..\\XSLT\\$xslt_file -" if ($xslt_file ne "");
	open (MultiMarkdown, "| cd \"$me\"& perl .\\MultiMarkdown.pl | perl .\\$SmartyPants $xslt > \"$temp_file\"");
} else {
	$xslt = "| xsltproc -nonet -novalid ../XSLT/$xslt_file -" if ($xslt_file ne "");
	open (MultiMarkdown, "| cd \"$me\"; ./MultiMarkdown.pl | ./$SmartyPants $xslt > \"$temp_file\"; textutil -convert rtf -stdout \"$temp_file\"");
}

print MultiMarkdown $data;

close(MultiMarkdown);

system(" rm \"$temp_file\"");


sub _RtfXSLT {
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
		
	return;
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
		
	return;
}