<?xml version='1.0' encoding='utf-8'?>

<!-- XHTML-to-Memoir converter by Fletcher Penney
	specifically designed for use with MultiMarkdown created XHTML

	Uses the LaTeX memoir class for output with the twoside option
	
	Format as 6.0in x 9.0in page size
	
	MultiMarkdown Version 2.0.b6
	
	$Id: 6x9book.xslt 499 2008-03-23 13:03:19Z fletcher $
-->

<!-- 
# Copyright (C) 2005-2008  Fletcher T. Penney <fletcher@fletcherpenney.net>
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the
#    Free Software Foundation, Inc.
#    59 Temple Place, Suite 330
#    Boston, MA 02111-1307 USA
-->

	
<xsl:stylesheet
	xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
	xmlns:html="http://www.w3.org/1999/xhtml"
	version="1.0">

	<xsl:import href="memoir.xslt"/>
	
	<xsl:output method='text' encoding='utf-8'/>

	<xsl:strip-space elements="*" />

	<xsl:template match="/">
		<xsl:apply-templates select="html:html/html:head"/>
		<xsl:apply-templates select="html:html/html:body"/>
		<xsl:call-template name="latex-footer"/>
	</xsl:template>

	<xsl:template name="latex-document-class">
		<xsl:text>\documentclass[10pt,twoside]{memoir}
\usepackage{layouts}[2001/04/29]
\makeglossary
\makeindex

\def\mychapterstyle{companion}
\def\mypagestyle{companion}
\def\revision{}

</xsl:text>
	</xsl:template>

	<!--  Change paper size for 6 x 9 book  -->

	<xsl:template name="latex-paper-size">
		<xsl:text>%%% need more space for ToC page numbers
\setpnumwidth{2.55em}
\setrmarg{3.55em}

%%% need more space for ToC section numbers
\cftsetindents{part}{0em}{3em}
\cftsetindents{chapter}{0em}{3em}
\cftsetindents{section}{3em}{3em}
\cftsetindents{subsection}{4.5em}{3.9em}
\cftsetindents{subsubsection}{8.4em}{4.8em}
\cftsetindents{paragraph}{10.7em}{5.7em}
\cftsetindents{subparagraph}{12.7em}{6.7em}

%%% need more space for LoF numbers
\cftsetindents{figure}{0em}{3.0em}

%%% and do the same for the LoT
\cftsetindents{table}{0em}{3.0em}

%%% set up the page layout
\setstocksize{9in}{6in}
\settrimmedsize{9in}{6in}{*}	% Use entire page
\settrims{0pt}{0pt}

\setlrmarginsandblock{1in}{0.6in}{*}
\setulmarginsandblock{1in}{0.8in}{*}

\setmarginnotes{0.1pt}{0.2in}{\onelineskip}
\setheadfoot{\onelineskip}{2\onelineskip}
\setheaderspaces{*}{2\onelineskip}{*}

%% Fix for the companion style header issue
%% http://www.codecomments.com/message459639.html

\setlength{\headwidth}{\textwidth}
 \addtolength{\headwidth}{\marginparsep}

 \addtolength{\headwidth}{\marginparwidth}
 \makerunningwidth{companion}{\headwidth}
 \makeheadrule{companion}{\headwidth}{\normalrulethickness}
 \makeheadposition{companion}{flushright}{flushleft}{}{}

\checkandfixthelayout

</xsl:text>
	</xsl:template>

</xsl:stylesheet>