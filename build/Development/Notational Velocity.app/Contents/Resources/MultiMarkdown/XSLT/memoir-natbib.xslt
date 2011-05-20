<?xml version='1.0' encoding='utf-8'?>

<!-- XHTML-to-Article converter by Fletcher Penney
	specifically designed for use with MultiMarkdown created XHTML
	
	Adds support for natbib citations to the memoir class.
	
	MultiMarkdown Version 2.0.b6
	
	$Id: memoir-natbib.xslt 517 2008-09-12 19:37:52Z fletcher $
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
	<xsl:import href="natbib-support.xslt"/>

	<xsl:template match="/">
		<xsl:apply-templates select="html:html/html:head"/>
		<xsl:apply-templates select="html:html/html:body"/>
		<xsl:call-template name="latex-footer"/>
	</xsl:template>

	<xsl:template name="latex-document-class">
		<xsl:text>\documentclass[10pt,oneside]{memoir}
\usepackage{layouts}[2001/04/29]
\usepackage[round,sort&amp;compress]{natbib}
\setcitestyle{super,open={},close={},comma}

\makeglossary
\makeindex

\def\mychapterstyle{default}
\def\mypagestyle{headings}
\def\revision{}

</xsl:text>
	</xsl:template>
	
	<xsl:output method='text' encoding='utf-8'/>

	<xsl:strip-space elements="*" />


</xsl:stylesheet>