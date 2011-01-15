<?xml version='1.0' encoding='utf-8'?>

<!-- XHTML-to-Science converter by Fletcher Penney
	specifically designed for use with MultiMarkdown created XHTML
	
	Uses the LaTeX article class for output
	
	MultiMarkdown Version 2.0.b6
	
	$Id: science.xslt 499 2008-03-23 13:03:19Z fletcher $
	
	TODO: The multicolumn layout broke
	TODO: Top margin is short, bottom margin is long
	TODO: Still needs work
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

	<xsl:import href="article.xslt"/>

	<xsl:output method='text' encoding='utf-8'/>

	<xsl:strip-space elements="*" />

	<xsl:template match="/">
		<xsl:apply-templates select="html:html/html:head"/>
		<xsl:apply-templates select="html:html/html:body"/>
		<xsl:call-template name="latex-footer"/>
	</xsl:template>

	<xsl:template name="latex-document-class">
		<xsl:text>\documentclass[oneside,article,9pt]{memoir}
\usepackage{layouts}[2001/04/29]
\usepackage{science}
\usepackage{xmpincl}	% Seems to be required to get the pdf to generate??

\def\revision{}
</xsl:text>
	</xsl:template>

	<!-- Science allows for an abstract -->

	<!-- support for abstracts -->
	<xsl:template match="html:h1[1]">
		<xsl:choose>
			<!-- abstract -->
			<xsl:when test="translate(.,'ABCDEFGHIJKLMNOPQRSTUVWXYZ',
				'abcdefghijklmnopqrstuvwxyz') = 'abstract'">
				<xsl:text>\begin{abstract}</xsl:text>
				<xsl:value-of select="$newline"/>
				<xsl:text>\addcontentsline{toc}{section}{</xsl:text>
				<xsl:apply-templates select="node()"/>
				<xsl:text>}</xsl:text>
			</xsl:when>
			<xsl:otherwise>
<xsl:text>\begin{body}

% Layout settings
\setlength{\parindent}{1em}

\section{</xsl:text>
				<xsl:apply-templates select="node()"/>
				<xsl:text>}</xsl:text>
			</xsl:otherwise>
		</xsl:choose>
		<xsl:text>\label{</xsl:text>
		<xsl:value-of select="@id"/>
		<xsl:text>}</xsl:text>
		<xsl:value-of select="$newline"/>
		<xsl:value-of select="$newline"/>
		<xsl:value-of select="$newline"/>
	</xsl:template>

	<xsl:template match="html:h1[position() = '2'][preceding-sibling::html:h1[position()='1'][translate(.,'ABCDEFGHIJKLMNOPQRSTUVWXYZ',
		'abcdefghijklmnopqrstuvwxyz') = 'abstract']]">
		<xsl:text>\end{abstract}

\begin{body}

% Layout settings
\setlength{\parindent}{1em}</xsl:text>
		<xsl:value-of select="$newline"/>
		<xsl:value-of select="$newline"/>
		<xsl:text>\section{</xsl:text>
		<xsl:apply-templates select="node()"/>
		<xsl:text>}</xsl:text>
		<xsl:value-of select="$newline"/>
		<xsl:text>\label{</xsl:text>
		<xsl:value-of select="@id"/>
		<xsl:text>}</xsl:text>
		<xsl:value-of select="$newline"/>
		<xsl:value-of select="$newline"/>
	</xsl:template>

	<xsl:template match="html:h2[count(preceding-sibling::html:h1) = '1'][preceding-sibling::html:h1[position()='1'][translate(.,'ABCDEFGHIJKLMNOPQRSTUVWXYZ',
		'abcdefghijklmnopqrstuvwxyz') = 'abstract']]">
		<xsl:text>\subsection*{</xsl:text>
		<xsl:apply-templates select="node()"/>
		<xsl:text>}</xsl:text>
		<xsl:value-of select="$newline"/>
		<xsl:text>\label{</xsl:text>
		<xsl:value-of select="@id"/>
		<xsl:text>}</xsl:text>
		<xsl:value-of select="$newline"/>
		<xsl:value-of select="$newline"/>
	</xsl:template>

	<!-- code block -->
	<xsl:template match="html:pre/html:code">
		<xsl:text>\begin{verbatim}

</xsl:text>
		<xsl:value-of select="."/>
		<xsl:text>
\end{verbatim}

</xsl:text>
	</xsl:template>

</xsl:stylesheet>