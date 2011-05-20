<?xml version='1.0' encoding='utf-8'?>

<!-- XHTML-to-Beamer converter by Fletcher Penney
	specifically designed for use with MultiMarkdown created XHTML

	Uses the LaTeX beamer class to generate a series of PDF "slides"
	
	MultiMarkdown Version 2.0.b6
	
	TODO: Currently only <?-> is recognized as dot-notation, <1-2> is not
-->

<!-- 
# Copyright (C) 2009  Fletcher T. Penney <fletcher@fletcherpenney.net>
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
	xmlns:beamer="http://fletcherpenney.net/mmd/"
  	exclude-result-prefixes="beamer"
	version="1.0">

	<xsl:import href="xhtml2latex.xslt"/>
	
	<xsl:template match="/">
		<xsl:apply-templates select="html:html/html:head"/>
		<xsl:apply-templates select="html:html/html:body"/>
		<xsl:call-template name="latex-footer"/>
	</xsl:template>

	<xsl:template match="html:body">
		<body>
			<xsl:apply-templates select="html:h1|html:h2|html:h3|html:h4|html:h5|html:h6"/>
		</body>
	</xsl:template>

	<xsl:template name="latex-footer">
%		<xsl:text>\begin{frame}[allowframebreaks]
%\frametitle{Bibliography}

%	Bibliography
%\bibliographystyle{\mybibliostyle}
%\bibliocommand
%\end{frame}

\end{document}
</xsl:text>
	</xsl:template>

	<xsl:template name="latex-document-class">
		<xsl:text>\documentclass[ignorenonframetext,11pt]{beamer}
%\documentclass[onesided]{article}
%\usepackage{graphicx}
%\usepackage{beamerarticle}

\usepackage{beamerthemesplit}
\usepackage{patchcmd}
\usepackage{tabulary}		% Support longer table cells
\usepackage{booktabs}		% Support better tables

\usepackage{subfigure}

\let\oldSubtitle\subtitle

</xsl:text>
	</xsl:template>

	<xsl:template name="latex-intro">
				<xsl:text>
\ifx\subtitle\undefined
\else
	\oldSubtitle{\subtitle}
\fi

\ifx\affiliation\undefined
\else
	\institute{\affiliation}
\fi

\ifx\event\undefined
\else
	\date[\mydate]{\mydate~ / \event }
\fi

\ifx\graphic\undefined
\else
	\pgfdeclareimage[height=0.75cm]{university-logo}{\graphic}
	\logo{\pgfuseimage{university-logo}}
\fi

\ifx\theme\undefined
\else
	\usetheme{\theme}
\fi


\AtBeginSubsection[]
{
   \begin{frame}
       \frametitle{Outline}
       \tableofcontents[currentsection,currentsubsection]
   \end{frame}
}

%\title{\mytitle}

% Show "current/total" slide counter in footer
\title[\mytitle\hspace{2em}\insertframenumber/
\inserttotalframenumber]{\mytitle}


\author{\myauthor}
\addtolength{\parskip}{\baselineskip}

\begin{document}
</xsl:text>
	</xsl:template>

	<xsl:template name="latex-paper-size">
		<xsl:text></xsl:text>
	</xsl:template>

	<xsl:template name="latex-copyright">
			<xsl:text></xsl:text>
	</xsl:template>

	<xsl:template name="latex-begin-body">
		<xsl:text></xsl:text>
	</xsl:template>

	<xsl:template name="latex-header">
		<xsl:text>\def\myauthor{Author}			% In case these were not included in metadata
\def\mytitle{Title}
\def\mykeywords{}
\def\mybibliostyle{plain}
\def\bibliocommand{}
</xsl:text>
</xsl:template>

	<xsl:template name="latex-title">
		<xsl:text>\frame{\setlength\parskip{0pt}\titlepage}


</xsl:text>
	</xsl:template>
	
	<!-- Convert headers into chapters, etc -->

	<xsl:template match="html:h1">
		<xsl:text>\part{</xsl:text>
		<xsl:value-of select="."/>
		<xsl:text>}</xsl:text>
		<xsl:value-of select="$newline"/>
		<xsl:text>\label{</xsl:text>
		<xsl:value-of select="@id"/>
		<xsl:text>}</xsl:text>
		<xsl:value-of select="$newline"/>
		<xsl:value-of select="$newline"/>
		<xsl:text>\frame{\partpage}
</xsl:text>
		<xsl:variable name="children" select="count(following-sibling::*) - count(following-sibling::*[local-name() = 'h1' or local-name() = 'h2' or local-name() = 'h3' or local-name() = 'h4' or local-name() = 'h5' or local-name() = 'h6'][1]/following-sibling::*) - count(following-sibling::*[local-name() = 'h1' or local-name() = 'h2' or local-name() = 'h3' or local-name() = 'h4' or local-name() = 'h5' or local-name() = 'h6'][1])"/>

		<xsl:apply-templates select="following-sibling::*[position() &lt;= $children]"/>
	</xsl:template>
	
	<xsl:template match="html:h2">
		<xsl:choose>
			<xsl:when test="substring(node(), (string-length(node()) - string-length('*')) + 1) = '*'">
				<xsl:text>\section*{}</xsl:text>
			</xsl:when>
			<xsl:otherwise>
				<xsl:text>\section{</xsl:text>
				<xsl:apply-templates select="node()"/>
				<xsl:text>}</xsl:text>
			</xsl:otherwise>
		</xsl:choose>
		<xsl:value-of select="$newline"/>
		<xsl:text>\label{</xsl:text>
		<xsl:value-of select="@id"/>
		<xsl:text>}</xsl:text>
		<xsl:value-of select="$newline"/>
		<xsl:value-of select="$newline"/>

		<xsl:variable name="children" select="count(following-sibling::*) - count(following-sibling::*[local-name() = 'h1' or local-name() = 'h2' or local-name() = 'h3' or local-name() = 'h4' or local-name() = 'h5' or local-name() = 'h6'][1]/following-sibling::*) - count(following-sibling::*[local-name() = 'h1' or local-name() = 'h2' or local-name() = 'h3' or local-name() = 'h4' or local-name() = 'h5' or local-name() = 'h6'][1])"/>

		<xsl:apply-templates select="following-sibling::*[position() &lt;= $children]"/>
	</xsl:template>

	<xsl:template match="html:h3">
		<xsl:choose>
			<xsl:when test="substring(node(), (string-length(node()) - string-length('*')) + 1) = '*'">
				<xsl:text>\subsection*{}</xsl:text>
			</xsl:when>
			<xsl:otherwise>
				<xsl:text>\subsection{</xsl:text>
				<xsl:apply-templates select="node()"/>
				<xsl:text>}</xsl:text>
			</xsl:otherwise>
		</xsl:choose>
		<xsl:value-of select="$newline"/>
		<xsl:text>\label{</xsl:text>
		<xsl:value-of select="@id"/>
		<xsl:text>}</xsl:text>
		<xsl:value-of select="$newline"/>
		<xsl:value-of select="$newline"/>

		<xsl:variable name="children" select="count(following-sibling::*) - count(following-sibling::*[local-name() = 'h1' or local-name() = 'h2' or local-name() = 'h3' or local-name() = 'h4' or local-name() = 'h5' or local-name() = 'h6'][1]/following-sibling::*) - count(following-sibling::*[local-name() = 'h1' or local-name() = 'h2' or local-name() = 'h3' or local-name() = 'h4' or local-name() = 'h5' or local-name() = 'h6'][1])"/>

		<xsl:apply-templates select="following-sibling::*[position() &lt;= $children]"/>
	</xsl:template>

	<xsl:template match="html:h4">
		<xsl:text>\begin{frame}</xsl:text>
		<xsl:variable name="children" select="count(following-sibling::*) - count(following-sibling::*[local-name() = 'h1' or local-name() = 'h2' or local-name() = 'h3' or local-name() = 'h4' or local-name() = 'h5' or local-name() = 'h6'][1]/following-sibling::*) - count(following-sibling::*[local-name() = 'h1' or local-name() = 'h2' or local-name() = 'h3' or local-name() = 'h4' or local-name() = 'h5' or local-name() = 'h6'][1])"/>
		<xsl:if test="count(following-sibling::*[position() &lt;= $children][local-name() = 'pre']) &gt; 0">
			<xsl:text>[fragile]</xsl:text>
		</xsl:if>
		<xsl:text>
\frametitle{</xsl:text>
		<xsl:apply-templates select="node()"/>
		<xsl:text>}</xsl:text>
		<xsl:value-of select="$newline"/>
		<xsl:text>\label{</xsl:text>
		<xsl:value-of select="@id"/>
		<xsl:text>}</xsl:text>
		<xsl:value-of select="$newline"/>
		<xsl:value-of select="$newline"/>

		<xsl:apply-templates select="following-sibling::*[position() &lt;= $children]"/>
		<xsl:text>
\end{frame}
		</xsl:text>
		<xsl:value-of select="$newline"/>
		<xsl:value-of select="$newline"/>
	</xsl:template>

		<xsl:template match="html:h5">
			<xsl:text disable-output-escaping="yes">
<![CDATA[\mode<article>{]]></xsl:text>
			<xsl:variable name="children" select="count(following-sibling::*) - count(following-sibling::*[local-name() = 'h1' or local-name() = 'h2' or local-name() = 'h3' or local-name() = 'h4' or local-name() = 'h5' or local-name() = 'h6'][1]/following-sibling::*) - count(following-sibling::*[local-name() = 'h1' or local-name() = 'h2' or local-name() = 'h3' or local-name() = 'h4' or local-name() = 'h5' or local-name() = 'h6'][1])"/>
			<xsl:value-of select="$newline"/>
			<xsl:value-of select="$newline"/>

			<xsl:apply-templates select="following-sibling::*[position() &lt;= $children]"/>
			<xsl:text>}
</xsl:text>
			<xsl:value-of select="$newline"/>
			<xsl:value-of select="$newline"/>
		</xsl:template>

	<xsl:template match="html:h6">
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


	<!-- code block -->
	<xsl:template match="html:pre[child::html:code]">
		<xsl:text>\begin{semiverbatim}
</xsl:text>
		<xsl:value-of select="./html:code"/>
		<xsl:text>
\end{semiverbatim}

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

		<!-- images -->
		<xsl:template match="html:img">
			<xsl:text>\begin{figure}
	</xsl:text>
			<xsl:if test="@id">
				<xsl:text>\label{</xsl:text>
				<xsl:value-of select="@id"/>
				<xsl:text>}
	</xsl:text>
			</xsl:if>
			<xsl:text>\begin{center}
	</xsl:text>
			<xsl:text>\includegraphics[keepaspectratio,width=\textwidth, height=.75\textheight]{</xsl:text>
			<xsl:value-of select="@src"/>
			<xsl:text>}
	\end{center}
	</xsl:text>
			<xsl:if test="@title">
				<xsl:if test="not(@title = '')">
					<xsl:text>\caption{</xsl:text>
					<xsl:apply-templates select="@title"/>
					<xsl:text>}
		</xsl:text>
				</xsl:if>
			</xsl:if>
		<xsl:text>\end{figure}
	</xsl:text>
		</xsl:template>

	<xsl:template match="html:img" mode="images">
		<xsl:if test="@id">
			<xsl:text>\label{</xsl:text>
			<xsl:value-of select="@id"/>
			<xsl:text>}
</xsl:text>
		</xsl:if>
	<xsl:text>\subfigure</xsl:text>
		<xsl:if test="@title">
			<xsl:if test="not(@title = '')">
				<xsl:text>[</xsl:text>
				<xsl:apply-templates select="@title"/>
				<xsl:text>]</xsl:text>
			</xsl:if>
		</xsl:if>
		<xsl:text>{\includegraphics[keepaspectratio,width=\textwidth, height=.75\textheight]{</xsl:text>
		<xsl:value-of select="@src"/>
		<xsl:text>}}\quad
</xsl:text>
	</xsl:template>

	<!-- paragraph with multiple images -->
	<xsl:template match="html:p[count(child::html:img) > '1']">
		<xsl:text>\begin{figure}
\begin{center}
</xsl:text>
		
		<xsl:apply-templates select="node()" mode="images"/>
		<xsl:text>\end{center}
\end{figure}
</xsl:text>
		<xsl:value-of select="$newline"/>
		<xsl:value-of select="$newline"/>
		<xsl:value-of select="$newline"/>
	</xsl:template>

	<xsl:template match="html:div[@class='bibliography']">
		<!-- close the preceding frame first - we want to be our own slide(s) -->
		<xsl:text>\end{frame}

\part{Bibliography}
\begin{frame}[allowframebreaks]
\frametitle{Bibliography}
\begin{thebibliography}{</xsl:text>
		<xsl:value-of select="count(div[@id])"/>
		<xsl:text>}
</xsl:text>
		<xsl:apply-templates select="html:div"/>
		<xsl:text>

\end{thebibliography}

</xsl:text>
	</xsl:template>

	<!-- list item -->
	<xsl:template match="html:li">
		<xsl:text>
\item</xsl:text>
		<xsl:choose>
			<xsl:when test="substring(node(), (string-length(node()) - 1)) = '->'">
				<xsl:value-of select="substring(node(), (string-length(node()) - 3))"/>
				<xsl:text> </xsl:text>
					<xsl:value-of select="substring(node(),1,(string-length(node()) - 4))"/>
			</xsl:when>
			<xsl:otherwise>
				<xsl:text> </xsl:text>
					<xsl:apply-templates select="node()"/>
			</xsl:otherwise>
		</xsl:choose>
		<xsl:value-of select="$newline"/>
	</xsl:template>

</xsl:stylesheet>