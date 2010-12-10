<?xml version='1.0' encoding='utf-8'?>

<!-- XHTML-to-Manuscript converter by Fletcher Penney
	specifically designed for use with MultiMarkdown created XHTML

	Uses my manuscript class for output	
	
	MultiMarkdown Version 2.0.b6
	
	$Id: manuscript-novel.xslt 499 2008-03-23 13:03:19Z fletcher $
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

	<xsl:template name="latex-footer">
		<xsl:text>%
% Back Matter
%

\backmatter
%\appendixpage

%	Bibliography
\bibliographystyle{\mybibliostyle}
\bibliocommand

%	Glossary
% \printglossary


%	Index
% \printindex

\end{document}
</xsl:text>
	</xsl:template>

	<xsl:template name="latex-document-class">
		<xsl:text>\documentclass[10pt,oneside]{memoir}
\usepackage{layouts}[2001/04/29]
\usepackage{manuscript}
\makeglossary
\makeindex

\def\revision{}


</xsl:text>
	</xsl:template>

	<xsl:template name="latex-paper-size">
		<xsl:text>
</xsl:text>
	</xsl:template>

	<xsl:template name="latex-intro">
		<xsl:text>

	%
	%	PDF Stuff
	%

%	\ifpdf							% Removed for XeLaTeX compatibility
%	  \pdfoutput=1					% Removed for XeLaTeX compatibility
	  \usepackage[
	  	plainpages=false,
	  	pdfpagelabels,
	  	pdftitle={\mytitle},
	  	pagebackref,
	  	pdfauthor={\myauthor},
	  	pdfkeywords={\mykeywords}
	  	]{hyperref}
	  \usepackage{memhfixc}
%	\fi								% Removed for XeLaTeX compatibility


	\title{\mytitle}
	\author{\myauthor}

	\begin{document}
	</xsl:text>
		</xsl:template>	<xsl:template name="latex-title">
			<xsl:text>

% Title Page
\begin{titlingpage} 
\aliaspagestyle{titlingpage}{title} 
\setlength{\droptitle}{30pt} 

\manuscript\noindent\myauthor \\
\address
\vskip 12pt
\noindent\agent

\vfill
\renewcommand{\baselinestretch}{2}
\normalsize\manuscript\centering\MakeUppercase\mytitle

by \myauthor
\vskip 4in

\end{titlingpage} 


</xsl:text>
	</xsl:template>

	<xsl:template name="latex-copyright">
			<xsl:text></xsl:text>
	</xsl:template>

	<xsl:template name="latex-begin-body">
		<xsl:text>%
% Main Content
%

% Manuscript settings
\renewcommand{\baselinestretch}{2}
\raggedright\normalsize
\font\body="Courier New" at 12pt\body

% Layout settings
\setlength{\parindent}{0.5in}

\mainmatter
</xsl:text>
	</xsl:template>

	<!-- Rename Bibliography -->
	<xsl:template name="rename-bibliography">
		<xsl:param name="source" />
		<xsl:text>\renewcommand\bibname{</xsl:text>
		<xsl:value-of select="$source" />
		<xsl:text>}
</xsl:text>
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
		<xsl:text>\begin{center}
\#
\end{center}

</xsl:text>
		
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


	<!-- code block -->
	<xsl:template match="html:pre/html:code">
		<xsl:text>\begin{adjustwidth}{2.5em}{2.5em}
\begin{verbatim}

</xsl:text>
		<xsl:value-of select="."/>
		<xsl:text>
\end{verbatim}
\end{adjustwidth}

</xsl:text>
	</xsl:template>
	
	<!-- Changes due to limitations of manuscript format -->
	<xsl:template match="html:a[@href]">
		<xsl:value-of select="."/>
		<xsl:text>(</xsl:text>
		<xsl:value-of select="@href"/>
		<xsl:text>)</xsl:text>
	</xsl:template>

	<!-- emphasis -->
	<xsl:template match="html:em">
		<xsl:text>\underline{</xsl:text>
			<xsl:apply-templates select="node()"/>
		<xsl:text>}</xsl:text>
	</xsl:template>

	<!-- strong -->
	<xsl:template match="html:strong">
		<xsl:text>\textbf{</xsl:text>
			<xsl:apply-templates select="node()"/>
		<xsl:text>}</xsl:text>
	</xsl:template>

</xsl:stylesheet>