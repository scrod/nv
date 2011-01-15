<?xml version='1.0' encoding='utf-8'?>

<!-- XHTML-to-LaTeX converter by Fletcher Penney
	specifically designed for use with MultiMarkdown created XHTML

	Strip out all the "header" information - just output the actual content.
	
	Useful when you already have a LaTeX template that you will use.	
	
	MultiMarkdown Version 2.0.b6
	
	$Id: latex-snippet.xslt 499 2008-03-23 13:03:19Z fletcher $
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

	<xsl:import href="xhtml2latex.xslt"/>
	
	<xsl:template match="/">
		<xsl:apply-templates select="html:html/html:head"/>
		<xsl:apply-templates select="html:html/html:body"/>
		<xsl:call-template name="latex-footer"/>
	</xsl:template>

	<xsl:template match="html:meta">
	</xsl:template>

	<xsl:template match="*[local-name() = 'title']">
	</xsl:template>

	<xsl:template name="latex-header">
	</xsl:template>

	<xsl:template name="latex-footer">
	</xsl:template>

	<xsl:template name="latex-intro">
	</xsl:template>

	<xsl:template name="latex-document-class">
	</xsl:template>

	<xsl:template name="latex-paper-size">
	</xsl:template>

	<xsl:template name="latex-title">
	</xsl:template>

	<xsl:template name="latex-copyright">
	</xsl:template>

	<xsl:template name="latex-begin-body">
	</xsl:template>

	<!-- Rename Bibliography -->
	<xsl:template name="rename-bibliography">
	</xsl:template>

	<!-- Convert headers into chapters, etc -->
	
	<xsl:template match="html:h1">
		<xsl:text>\part{</xsl:text>
		<xsl:apply-templates select="node()"/>
		<xsl:text>}</xsl:text>
		<xsl:value-of select="$newline"/>
		<xsl:text>\label{</xsl:text>
		<xsl:value-of select="@id"/>
		<xsl:text>}</xsl:text>
		<xsl:value-of select="$newline"/>
		<xsl:value-of select="$newline"/>
	</xsl:template>

	<xsl:template match="html:h2">
		<xsl:text>\chapter{</xsl:text>
		<xsl:apply-templates select="node()"/>
		<xsl:text>}</xsl:text>
		<xsl:value-of select="$newline"/>
		<xsl:text>\label{</xsl:text>
		<xsl:value-of select="@id"/>
		<xsl:text>}</xsl:text>
		<xsl:value-of select="$newline"/>
		<xsl:value-of select="$newline"/>
	</xsl:template>

	<xsl:template match="html:h3">
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

	<xsl:template match="html:h4">
		<xsl:text>\subsection{</xsl:text>
		<xsl:apply-templates select="node()"/>
		<xsl:text>}</xsl:text>
		<xsl:value-of select="$newline"/>
		<xsl:text>\label{</xsl:text>
		<xsl:value-of select="@id"/>
		<xsl:text>}</xsl:text>
		<xsl:value-of select="$newline"/>
		<xsl:value-of select="$newline"/>
	</xsl:template>

	<xsl:template match="html:h5">
		<xsl:text>\subsubsection{</xsl:text>
		<xsl:apply-templates select="node()"/>
		<xsl:text>}</xsl:text>
		<xsl:value-of select="$newline"/>
		<xsl:text>\label{</xsl:text>
		<xsl:value-of select="@id"/>
		<xsl:text>}</xsl:text>
		<xsl:value-of select="$newline"/>
		<xsl:value-of select="$newline"/>
	</xsl:template>

	<xsl:template match="html:h6">
		<xsl:text>{\itshape </xsl:text>
		<xsl:apply-templates select="node()"/>
		<xsl:text>}</xsl:text>
		<xsl:value-of select="$newline"/>
		<xsl:text>\label{</xsl:text>
		<xsl:value-of select="@id"/>
		<xsl:text>}</xsl:text>
		<xsl:value-of select="$newline"/>
		<xsl:value-of select="$newline"/>
	</xsl:template>

	<!-- support for abstracts -->
	<xsl:template match="html:h2[1][translate(.,'ABCDEFGHIJKLMNOPQRSTUVWXYZ',
	'abcdefghijklmnopqrstuvwxyz') = 'abstract']">
		<xsl:text>\begin{abstract}</xsl:text>
		<xsl:value-of select="$newline"/>
		<xsl:text>\label{</xsl:text>
		<xsl:value-of select="@id"/>
		<xsl:text>}</xsl:text>
		<xsl:value-of select="$newline"/>
		<xsl:text>\addcontentsline{toc}{chapter}{</xsl:text>
		<xsl:apply-templates select="node()"/>
		<xsl:text>}</xsl:text>
		<xsl:value-of select="$newline"/>
		<xsl:value-of select="$newline"/>
	</xsl:template>

	<xsl:template match="html:h2[position() = '2'][preceding-sibling::html:h2[position()='1'][translate(.,'ABCDEFGHIJKLMNOPQRSTUVWXYZ',
		'abcdefghijklmnopqrstuvwxyz') = 'abstract']]">
		<xsl:text>\end{abstract}</xsl:text>
		<xsl:value-of select="$newline"/>
		<xsl:value-of select="$newline"/>
		<xsl:text>\chapter{</xsl:text>
		<xsl:apply-templates select="node()"/>
		<xsl:text>}</xsl:text>
		<xsl:value-of select="$newline"/>
		<xsl:text>\label{</xsl:text>
		<xsl:value-of select="@id"/>
		<xsl:text>}</xsl:text>
		<xsl:value-of select="$newline"/>
		<xsl:value-of select="$newline"/>
	</xsl:template>

	<xsl:template match="html:h3[count(preceding-sibling::html:h2) = '1'][preceding-sibling::html:h2[position()='1'][translate(.,'ABCDEFGHIJKLMNOPQRSTUVWXYZ',
		'abcdefghijklmnopqrstuvwxyz') = 'abstract']]">
		<xsl:text>\section*{</xsl:text>
		<xsl:apply-templates select="node()"/>
		<xsl:text>}</xsl:text>
		<xsl:value-of select="$newline"/>
		<xsl:text>\label{</xsl:text>
		<xsl:value-of select="@id"/>
		<xsl:text>}</xsl:text>
		<xsl:value-of select="$newline"/>
		<xsl:value-of select="$newline"/>
	</xsl:template>

	<xsl:template match="html:h4[count(preceding-sibling::html:h2) = '1'][preceding-sibling::html:h2[position()='1'][translate(.,'ABCDEFGHIJKLMNOPQRSTUVWXYZ',
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
	<xsl:template match="html:pre[child::html:code]">
		<xsl:text>\begin{adjustwidth}{2.5em}{2.5em}
\begin{verbatim}


</xsl:text>
		<xsl:value-of select="./html:code"/>
		<xsl:text>
\end{verbatim}
\end{adjustwidth}

</xsl:text>
	</xsl:template>

	<!-- no code, so treat as poetry -->
	<xsl:template match="html:pre">
		<xsl:text>\begin{adjustwidth}{4em}{4em}
\setverbatimfont{\normalfont}
\begin{verbatim}


</xsl:text>
		<xsl:value-of select="."/>
		<xsl:text>
\end{verbatim}
\end{adjustwidth}

</xsl:text>
	</xsl:template>

	
	<!-- epigraph (a blockquote immediately following a header 1-3) -->
	<xsl:template match="html:blockquote[preceding-sibling::*[1][local-name() = 'h1' or local-name() = 'h2' or local-name() = 'h2' or local-name() = 'h3' ]]">
		<xsl:text>\epigraph{</xsl:text>
		<xsl:apply-templates select="node()"/>
		<xsl:text>}

</xsl:text>
	</xsl:template>

	<!-- epigraph author (a blockquote within blockquote) -->
	<xsl:template match="html:blockquote[last()][parent::*[preceding-sibling::*[1][local-name() = 'h1' or local-name() = 'h2' or local-name() = 'h2' or local-name() = 'h3']]] ">
		<xsl:text>}{</xsl:text>
		<xsl:apply-templates select="node()"/>
	</xsl:template>


</xsl:stylesheet>