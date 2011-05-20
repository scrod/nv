#!/usr/bin/env perl
#
# $Id: align_elastic_tabstops.pl 525 2009-06-15 18:45:44Z fletcher $
#
# Adds support for a modified implementation of "elastic tabstops":
#	<http://nickgravgaard.com/elastictabstops/>
#
# Also formats for the new MMD table syntax
#
# Copyright (c) 2009 Fletcher T. Penney
#	<http://fletcherpenney.net/>
#
# MultiMarkdown Version 2.0.b6
#
# TODO: no padding if only 1 line in group
#

$cur_indent = 0;	# Number of leading tabs
$cur_columns = 0;	# Number of columns
@bits = ();			# Store previous lines
$output = "";
$minimum_width = 3;
$padding = 1;
$g_is_final_newline = 0;
$g_empty_line = 0;

# Iteratively work through text:
#	Does line match number of opening tabs?
#	Does line match number of total tabs?
#	As long as yes, process, and move to next line

while ($line = <>) {
	if ($line =~ /\n$/) {
		# Require two blank lines to reset
		if ($g_empty_line == 1) {
			$g_is_final_newline = 1;
		} else {
			$g_empty_line = 1;
			$g_is_final_newline = 0;
		}
	} else {
		$g_empty_line = 0;
		$g_is_final_newline = 0;
	}
	chomp $line;
	
	# Trim spaces before and after tabs
	$line =~ s/  +\t/\t/g;
	$line =~ s/\t +/\t/g;
	
	# Add space to end of line to prevent deleting lines with only tabs
	$line .= " ";
	
	$line =~ /^(\t*)/;
#	if (length($1) == $cur_indent) {
#	This check was disabled to simplify things - may need to add it back
	if ($cur_indent == $cur_indent) {
		# We're at the same level of indentation
		# Do we have the same number of columns?
		$columns = ($line =~ tr/\t/\t/);
		if ($columns == $cur_columns) {
			# yup
			push @bits, [split (/\t/, $line)];
		} else {
			# Nope - new block
			$output .= alignbits(@bits);
			$line =~ /^(\t*)/;
			$cur_indent = length($1);
			$cur_columns = ($line =~ tr/\t/\t/);
			@bits = ();
			push @bits, [split (/\t/, $line)];
		}
	} else {
		# New indent, so it's a new block

		$output .= alignbits(@bits);
		$line =~ /^(\t*)/;
		$cur_indent = length($1);
		$cur_columns = ($line =~ tr/\t/\t/);
		@bits = ();
		push @bits, [split (/\t/, $line)];
	}
}

$output .= alignbits(@bits);


print $output;

sub alignbits{
	my(@bits) = @_;
	my $output = "";
	my @width = ();
	
	# Remove space that was added to end of lines
	for $i (0 .. $#bits) {
		$bits[$i][$#{$bits[$i]}] =~ s/ $//;
	}
	
	for $i (0 .. $#bits) {
		for $j (0 .. $#{$bits[$i]}) {
			if ($bits[$i][$j] =~ /^\s*\-+\s*$/) {
				# Special case for table headers
				$bits[$i][$j] = "-";
			}
			if (length($bits[$i][$j]) + $padding > $width[$j]) {
				$width[$j] = length($bits[$i][$j]) + $padding;
			}
		}
	}

	for $i (0 .. $#bits) {
		for $j (0 .. $#{$bits[$i]} ) {
			if ($bits[$i][$j] =~ /^\s*\-+\s*$/) {
				# Special case for table headers
				$bits[$i][$j] = "-" x ($width[$j]);
			}
			if ($bits[$i][$j] =~ /^[\d\$\-\.,]*\d[,\d\$\-\.]*$/) {
				# Numeric field
				$output .= ( $width[$j] > $minimum_width || $bits[$i][$j] =~ /\S/ )? sprintf "%*s", $width[$j], $bits[$i][$j] : "";
				#	$output .= " " x $padding if ($j != $#{$bits[$i]});
			} else {
				# Non-numeric field
				if ($j == $#{$bits[$i]}) {
					$output .= $bits[$i][$j];
				} else {
					$output .= ($width[$j] > $minimum_width || $bits[$i][$j] =~ /\S/ )? sprintf "%-*s", $width[$j], $bits[$i][$j] : "";
				}
			}
			if ($j == $#{$bits[$i]}) {
				$output .= "\n";				
			} else {
				$output .= "\t";
			}
		}
	}
	
	if (! $g_is_final_newline) {
		$output =~ s/\n$//s;
	}
	return $output;
}

