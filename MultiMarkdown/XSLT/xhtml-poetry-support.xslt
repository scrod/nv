<?xml version='1.0' encoding='utf-8'?>

<!-- XHTML-to-XHTML converter by Fletcher Penney
	specifically designed for use with MultiMarkdown created XHTML
	
	Looks for code blocks that start with `[poetry]`.  If matched,
	strip the poetry tag, apply the poetry class to the <pre> element,
	and strip out the <code> wrapper.
	
	Another example of what can be done with a post-processing XSLT.
	
	MultiMarkdown Version 2.0.b6
	
	$Id: xhtml-poetry-support.xslt 499 2008-03-23 13:03:19Z fletcher $
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
	xmlns="http://www.w3.org/1999/xhtml"
  	exclude-result-prefixes="xhtml xsl"
	version="1.0">

	<xsl:variable name="newline">
<xsl:text>
</xsl:text>
	</xsl:variable>
	
	<xsl:output method='xml' version="1.0" encoding='utf-8' doctype-public="-//W3C//DTD XHTML 1.1 plus MathML 2.0//EN" doctype-system="http://www.w3.org/TR/MathML2/dtd/xhtml-math11-f.dtd" indent="no"/>

	<!-- the identity template, based on http://www.xmlplease.com/xhtmlxhtml -->
	<xsl:template match="@*|node()">
		<xsl:copy>
			<xsl:apply-templates select="@*|node()"/>
		</xsl:copy>
	</xsl:template>

	<xsl:template match="xhtml:pre">
		<xsl:choose>
			<xsl:when test="starts-with(child::xhtml:code,'[poetry]')">
				<pre class="poetry">
					<xsl:apply-templates select="@*|node()" mode="poetry"/>
				</pre>
			</xsl:when>
			<xsl:otherwise>
				<xsl:copy>
					<xsl:apply-templates select="@*|node()"/>
				</xsl:copy>
			</xsl:otherwise>
		</xsl:choose>
	</xsl:template>

	<xsl:template match="xhtml:code" mode="poetry">
		<xsl:value-of select="substring-after(.,'[poetry]')"/>
	</xsl:template>	

</xsl:stylesheet>