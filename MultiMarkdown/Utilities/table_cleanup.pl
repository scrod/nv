#!/usr/bin/env perl
#
# $Id: table_cleanup.pl 499 2008-03-23 13:03:19Z fletcher $
#
# Cleanup the spacing and alignment of MultiMarkdown tables
#
# Used by my TextMate Bundle, but can be used elsewhere as well
#
# Copyright (c) 2006-2008 Fletcher T. Penney
#	<http://fletcherpenney.net/>
#
# MultiMarkdown Version 2.0.b6
#

local $/;
$text = <>;

my %max_width = ();
my @alignments = ();


# Reusable regexp's to match table
my $less_than_tab = 3;

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
	(?:\n?$table_row)
}mx;

my $table_caption = qr{
	$line_start
	\[.*?\][ \t]*\n
}mx;

my $table_divider = qr{
	$line_start
	[\|\-\+\:\.][ \-\+\|\:\.]*?\|[ \-\+\|\:\.]*
}mx;

my $whole_table = qr{
	($table_caption)?		# Optional caption
	($first_row				# First line must start at beginning
	($table_row)*?)?		# Header Rows
	$table_divider			# Divider/Alignment definitions
	$table_rows+			# Body Rows
	\n?[^\n]*?\|[^\n]*?		# Allow last row not to have a "\n" for cleaning while editing
	($table_caption)?		# Optional caption
}mx;


# Find whole tables, then break them up and process them

$text =~ s{
	^($whole_table)			# Whole table in $1
	(\n|\Z)					# End of file or 2 blank lines
}{
	my $table = $1 . "\n";	
	my $table_original = $table;
	$result = "";
	@alignments = ();
	%max_width = ();
	
	# Strip Caption and Summary
	$table =~ s/^$line_start\[\s*(.*?)\s*\](\[\s*(.*?)\s*\])?[ \t]*$//m;
	$table =~ s/\n$line_start\[\s*(.*?)\s*\][ \t]*\n/\n/s;
	
	$table = "\n" . $table;	
	# Need to be greedy
	$table =~ s/\n($table_divider)\n($table_rows+)//s;
	my $alignment_string = $1;
	my $body = $2;
	my $header = $table;

	# Process column alignment
	while ($alignment_string =~ /\|?\s*(.+?)\s*(\||\Z)/gs) {
		my $cell = $1;
		if ($cell =~ /\:$/) {
			if ($cell =~ /^\:/) {
				push(@alignments,"center");
			} else {
				push(@alignments,"right");
			}
		} else {
			if ($cell =~ /^\:/) {
				push(@alignments,"left");
			} else {
				if (($cell =~ /^\./) || ($cell =~ /\.$/)) {
					push(@alignments,"char");
				} else {
					push(@alignments,"");
				}
			}
		}
	}

	$table = $header . "\n" . $body;
	
	# First pass - find widest cell in each column (for single column cells only)
	foreach my $line (split(/\n/, $table)) {
		my $count = 0;
		while ($line =~ /(\|?\s*[^\|]+?\s*(\|+|\Z))/gs) {
			my $cell = $1;		# Width of actual text in cell
			my $ending = $2;	# Is there a trailing `|`?
			
			if ($ending =~ /\|\|/) {
				# For first pass, do single cells only
				$count += (length($ending));
				next;
			}

			setWidth($count, $cell);			
			$count++
		}
	}
	
	# Second pass - handle cells that span multiple rows
	foreach my $line (split(/\n/, $table)) {
		my $count = 0;
		while ($line =~ /(\|?\s*[^\|]+?\s*(\|+|\Z))/gs) {
			my $cell = $1;		# Width of actual text in cell
			my $ending = $2;	# Is there a trailing `|`?
			
			if ($ending =~ /\|\|/) {
				setWidth($count, $cell);			
				$count += (length($ending));
				next;
			}
			$count++
		}
	}
	
	# Fix length of alignment definitions
	
	$table_original =~ s{
		\n($table_divider)\n
	}{
		my $divider = $1;
		my $count = 0;
		$divider =~ s{
			(\|?)\s*([^\|]+?)\s*(\|+|\Z)
		}{
			my $opening = $1;
			my $cell = $2;
			my $ending = $3;
			my $result = "";

			my $goal_length = $max_width{$count} -3;
			if ($count == 0) {
				if ($opening eq ""){
					$goal_length++;
				} else {
					$goal_length--;
				}
			}
			if ($cell =~ /^\:/) {
				$goal_length--;
				$result = ":";
			}
			if ($cell =~ /\:$/) {
				$goal_length--;
			}
			for (my $i=0;$i < $goal_length;$i++){
				$result.="-";
			}
			if ($cell =~ /\:$/) {
				$result .=":";
			}
			
			$count++;
			$opening . "$result" . $ending;
		}xsge;
		"\n$divider\n";
	}sxe;

	# Second pass - reformat table cells to appropriate width

	$table_original =~ s{
		# match each line
		(.*)
	}{
		$line = $1;
		my $result = "";
		my $count = 0;
		
		# Now process them
		
		if (($line =~ /^\[/) && ($line !~ /\|/)){
			$result .= $line;
		} else {
		while ($line =~ /(\|?)\s*([^\|]+?)\s*(\|+|\Z)/gs) {
			my $opening = $1;
			my $cell = $2;
			my $ending = $3;
			my $lead = 0;
			my $pad_lead = 0;
			my $pad_trail = 0;
			my $len = length($2);		# Length of actual contents
			
			# Not all first column cells have a leading `|`
			if ($count > 0) {
				$pad_lead = 1;
			} elsif (length($opening) > 0) {
				$pad_lead = 1;
			}

			# Buffer before trailing `|`
			if (length($ending) > 0) {
				$pad_trail = 1;
			}

			# How much space to fill? (account for multiple columns)
			my $width = 0;
			if ($ending =~ /\|/) {
				$width = maxWidth($count,length($ending));
			} else {
				$width = maxWidth($count, 1);
			}
			
			if ($alignments[$count] =~ /^(left)?$/) {
				$lead = $len + $pad_lead;
				$trail = $width - $lead  - length($opening);
			}

			if ($alignments[$count] =~ /^right$/) {
				if ($count == 0) {
					if ($opening eq "") {
						$opening = "|";
						$pad_lead = 1;
						$width++;
					}
				}
				$trail = $pad_trail+length($ending);
				$lead = $width - $trail - length($opening);
			}
			
			if ($alignments[$count] =~ /^center$/) {
				if ($count == 0) {
					if ($opening eq "") {
						$opening = "|";
						$pad_lead = 1;
						$width++;
					}
				}
				# Divide padding space
				my $pad_total =  $width - $len;
				$pad_lead = int($pad_total/2)+1;
				$pad_trail = $pad_total - $pad_lead;
				$trail = $pad_trail+length($ending);
				$lead = $width - $trail - length($opening);
			}

			$result .= $opening . sprintf("%*s", $lead, $cell) . sprintf("%*s", $trail, $ending);
		
			if ($ending =~ /\|\|/) {
				$count += (length($ending));
			} else {
				$count++;
			}
		}
		}
		
		$result;
	}xmge;
	
	$table_original;
}xsge;


print $text;


sub maxWidth {
	# Return the total width for a range of columns
	my ($start_col, $cols) = @_;
	my $total = 0;
	
	for (my $i = $start_col;$i < ($start_col + $cols);$i++) {
		$total += $max_width{$i};
	}
	
	return $total;
}

sub setWidth {
	# Set widths for column(s) based on cell contents
	my ($start_col, $cell) = @_;

	$cell =~ /(\|?)\s*([^\|]+?)\s*(\|+|\Z)/;
	my $opening = 	$1;
	my $contents =	$2;
	my $closing =	$3;
	
	my $padding =	0;

	$padding++ if (length($opening) > 0);	# For first cell
	$padding++ if ($start_col > 0);			# All cells except first definitely have an opening `|`
	$padding++ if (length($closing) > 0);
				
	$contents =~ s/&\s*(.*?)\s*$/$1/;	# I don't remember what this does
	
	my $cell_length = length($contents) + $padding + length($opening)  + length($closing);
	
	if ($closing =~ /\|\|/) {
		# This cell spans multiple columns
		my @current_max = ();
		my $cols = length($closing);
		my $current_total = 0;
		
		for (my $i = $start_col;$i < ($start_col + $cols);$i++) {
			$current_total += $max_width{$i};
		}

		if ($current_total < $cell_length) {
			my %columns = ();
			# Proportionally divide extra space
			for (my $i = $start_col; $i < ($start_col + $cols);$i++) {
				$max_width{$i} = int($max_width{$i} * ($cell_length/$current_total));
				$columns{$i} = $max_width{$i};
			}
			$current_total = 0;
			for (my $i = $start_col;$i < ($start_col + $cols);$i++) {
				$current_total += $max_width{$i};
			}
			my $missing = $cell_length - $current_total;

			# Now find the amount lost from fractions, and add back to largest columns
			foreach my $a_col (sort { $max_width{$b} <=> $max_width{$a} }keys %columns) {
				if ($missing > 0) {
					$max_width{$a_col}++;
					$missing--;
				}
			}
		}
		
	} else {
		if ($max_width{$start_col}< $cell_length) {
			$max_width{$start_col} = $cell_length;
		}	
	}
	
}

