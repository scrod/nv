<?xml version='1.0' encoding='utf-8'?>

<!-- XHTML-to-XHTML converter by Fletcher Penney
	specifically designed for use with MultiMarkdown created XHTML
	
	This utility converts the output of MMD from a full XHTML
	document into a "snippet", as if the "Format:complete" metadata
	was not present.

	This tool would be useful in situations where one is forced to
	generate a complete XHTML document, but really you just want a
	snippet.

	Unfortunately, I can't seem to get rid of the xmlns
	declarations in the output... If anyone has any suggestions on
	this one, I would appreciate it. The closest I came was to wrap
	the output in a div, then the div is assigned an xsmlns, but
	the child elements are not.

	MultiMarkdown Version 2.0.b6
	
	$Id: article.xslt 386 2007-05-14 21:53:09Z fletcher $
-->

<!-- 
# Copyright (C) 2007-2008  Fletcher T. Penney <fletcher@fletcherpenney.net>
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
	xmlns:xhtml="http://www.w3.org/1999/xhtml"
  	exclude-result-prefixes="xhtml xsl"
	version="1.0">

	<xsl:variable name="newline">
<xsl:text>
</xsl:text>
	</xsl:variable>
	
	<xsl:output method='html' indent="no" omit-xml-declaration="yes"/>

	<!-- the identity template, based on http://www.xmlplease.com/xhtmlxhtml -->
	<xsl:template match="@*|node()">
		<xsl:copy>
			<xsl:apply-templates select="@*|node()"/>
		</xsl:copy>
	</xsl:template>

	<xsl:template match="xhtml:html">
		<xsl:apply-templates select="@*|node()"/>
	</xsl:template>

	<xsl:template match="xhtml:body">
		<xsl:apply-templates select="@*|node()"/>
	</xsl:template>

	<xsl:template match="xhtml:head"></xsl:template>
	
	
</xsl:stylesheet>