<?xml version='1.0' encoding='utf-8'?>

<!-- XHTML-to-Memoir converter by Fletcher Penney
	specifically designed for use with MultiMarkdown created XHTML

	Uses the LaTeX memoir class for output

	The first page can include letterhead graphic elements (e.g. logo)

	It is simplified from the full memoir version, removing items
		not likely to be included in a letter or simple document

	*Requires that you use the mmd-letterhead style package for LaTeX,
		which is available at http://fletcherpenney.net/XSLT_Files*

	MultiMarkdown Version 2.0.b6
	
	$Id: letterhead.xslt 525 2009-06-15 18:45:44Z fletcher $
-->

<!-- 
# Copyright (C) 2007-2009  Fletcher T. Penney <fletcher@fletcherpenney.net>
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

	<!-- rely on the mmd-letterhead style to set up paper size -->
	<xsl:template name="latex-paper-size">
	</xsl:template>
	
	<xsl:template name="latex-document-class">
		<xsl:text>\documentclass[oneside,article]{memoir}
\usepackage{layouts}[2001/04/29]


</xsl:text>
	</xsl:template>

	<xsl:template name="latex-header">
		<xsl:text>\usepackage{fancyvrb}			% Allow \verbatim et al. in footnotes
\usepackage{graphicx}			% To include graphics in pdf's (jpg, gif, png, etc)
\usepackage{booktabs}			% Better tables
\usepackage{tabulary}			% Support longer table cells
\usepackage[utf8]{inputenc}		% For UTF-8 support
\usepackage[T1]{fontenc}		% Use T1 font encoding for accented characters
\usepackage{xcolor}				% Allow for color (annotations)

%\geometry{landscape}			% Activate for rotated page geometry

%\usepackage[parfill]{parskip}	% Activate to begin paragraphs with an empty
								% line rather than an indent


\def\myauthor{Author}			% In case these were not included in metadata
\def\mytitle{Title}
\def\mykeywords{}
\def\mybibliostyle{plain}
\def\bibliocommand{}
\def\myrecipient{}

\VerbatimFootnotes
</xsl:text>
	</xsl:template>

	<xsl:template name="latex-intro">
				<xsl:text>

%
%	PDF Stuff
%

%\ifpdf							% Removed for XeLaTeX compatibility
%  \pdfoutput=1					% Removed for XeLaTeX compatibility
  \usepackage[
  	plainpages=false,
  	pdfpagelabels,
  	pdftitle={\mytitle},
  	pagebackref,
  	pdfauthor={\myauthor},
  	pdfkeywords={\mykeywords}
  	]{hyperref}
  \usepackage{memhfixc}
%\fi							% Removed for XeLaTeX compatibility

\ifx\recipient\undefined
\else
	\addtodef{\myrecipient}{}{\recipient \\}
\fi

\ifx\recipientaddress\undefined
\else
	\addtodef{\myrecipient}{}{\recipientaddress}
\fi

\ifx\mydate\undefined
	\def\mydate{\today}
\fi

</xsl:text>
	</xsl:template>

	<xsl:template name="return-address">
		<xsl:call-template name="return-address-defaults"/>
		<xsl:text>% Create return address
\def\returnaddress{\raggedleft 
\footnotesize
\renewcommand{\baselinestretch}{1.1}

\textbf{\myauthor} \\}

\ifx\position\undefined
\addtodef{\returnaddress}{}{\textit{\defaultposition}}
\else
	\addtodef{\returnaddress}{}{\textit{\position} \\}
\fi

\ifx\email\undefined
\addtodef{\returnaddress}{}{\textit{\defaultemail}

~

}
\else
	\addtodef{\returnaddress}{}{\textit{\email}

~

}
\fi

\ifx\department\undefined
\addtodef{\returnaddress}{}{\textbf{\defaultdepartment}}
\else
	\addtodef{\returnaddress}{}{\textbf{\department} \\}
\fi

\ifx\address\undefined
\addtodef{\returnaddress}{}{\defaultaddress}
\else
	\addtodef{\returnaddress}{}{\address \\}
\fi

\ifx\phone\undefined
\addtodef{\returnaddress}{}{\defaultphone}
\else
	\addtodef{\returnaddress}{}{Tel \phone \\}
\fi


\ifx\fax\undefined
\addtodef{\returnaddress}{}{\defaultfax}
\else
	\addtodef{\returnaddress}{}{Fax \fax \\}
\fi

\ifx\web\undefined
\addtodef{\returnaddress}{}{\defaultweb
}
\else
	\addtodef{\returnaddress}{}{ \web \\
}
\fi
		</xsl:text>
	</xsl:template>
	
	<xsl:template name="return-address-defaults">
		<xsl:text>% Default info for return address
% These should include '\\' where appropriate for line endings

\def\defaultemail{}
\def\defaultposition{}
\def\defaultdepartment{}
\def\defaultaddress{}
\def\defaultphone{}
\def\defaultfax{}
\def\defaultweb{}

% Define height for logo and return address
\def\logoheight{1.5in}

% Define Logo or something for upper left corner
\def\coverlogo{}

% Define signature
\ifx\signature\undefined
	\def\signature{~ \\ Sincerely, \\

\myauthor}
\else
\fi

</xsl:text>
	</xsl:template>

	<xsl:template name="latex-begin-body">
		<xsl:call-template name="return-address"/>
		<xsl:text>\usepackage{mmd-letterhead}
\begin{document}

% Layout settings
\setlength{\parindent}{0pt}

\mainmatter

% Use coverpage style
\thispagestyle{letterhead-cover}

% Insert return address

\begin{figure}[t]
\begin{adjustwidth}{-0.5in}{-0.5in}
\begin{minipage}[l][\logoheight]{4in}
	\coverlogo
	\vspace*{\fill}
\end{minipage} 
\hfill 
\begin{minipage}[r][\logoheight]{2in} 
	{\renewcommand{\baselinestretch}{1.1}
	\color{returnaddress}\returnaddress}
	\vspace*{\fill}
\end{minipage}
\end{adjustwidth}
\end{figure}


\pagestyle{letterhead}
\large
% Return to main settings

\renewcommand{\baselinestretch}{1.2}
\setlength{\parskip}{12pt}

% Insert Recipient
\myrecipient

% Insert date
\mydate

</xsl:text>
</xsl:template>

	<xsl:template name="latex-title">
	</xsl:template>

	<xsl:template name="latex-copyright">
	</xsl:template>

	<xsl:template name="latex-footer">
		<xsl:text>\signature
			
%
% Back Matter
%

\backmatter
%\appendixpage

%	Bibliography
\bibliographystyle{\mybibliostyle}
\bibliocommand

%	Glossary
\printglossary


%	Index
\printindex

\end{document}
</xsl:text>
	</xsl:template>


</xsl:stylesheet>
