<?xml version='1.0' encoding='utf-8'?>

<!-- Custom Envelope by Fletcher Penney

	Demonstration of how to customize the default envelope template
		in MultiMarkdown with default return address information.

	MultiMarkdown Version 2.0.b6

	$Id: custom-envelope.xslt 525 2009-06-15 18:45:44Z fletcher $
-->

<!-- 
# Copyright (C) 2008-2009  Fletcher T. Penney <fletcher@fletcherpenney.net>
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

	<xsl:import href="envelope.xslt"/>
	
	<xsl:template match="/">
		<xsl:apply-templates select="html:html/html:head"/>
		<xsl:call-template name="latex-footer"/>
	</xsl:template>

	<xsl:template name="return-address-defaults">
		<xsl:text>% Default info for return address
% These should include '\\' where appropriate for line endings

\def\defaultemail{\href{mailto:owner@fletcherpenney.net}{owner@fletcherpenney.net} \\}
\def\defaultposition{}
\def\defaultdepartment{\coverlogo \normalfont \\}
\def\defaultaddress{123 Fake St \\ Charleston, SC 29401 \\}
\def\defaultweb{}

% Define the fl ligature for linux compatibility
\chardef\fl="FB02

% Define Logo or something for upper left corner
\def\coverlogo{
\font\logo="Didot:mapping=tex-text" at 24pt \logo
\href{http://fletcherpenney.net/}{\fl etcherpenney.\color{accent}net\color{black}}
}


% Use my stylesheet
\usepackage{fletcherpenney}

</xsl:text>
	</xsl:template>


	
</xsl:stylesheet>
