<?xml version='1.0' encoding='utf-8'?>

<!-- XHTML-to-XHTML converter by Fletcher Penney
	specifically designed for use with MultiMarkdown created XHTML
	
	This converts MMD text into XHTML that is suitable for pasting into 
	Google Docs.  Open a new document, and go to Edit->Edit HTML.  Paste the
	XHTML source in.
	
	This XSLT file converts footnotes into a format that is compatible with
	Google Docs.
	
	Google does a decent job of converting into PDF's, RTF, and Open Office
	documents. (In fact, it does better at RTF than the old Mac OS X only
	textutil approach).
	
	MultiMarkdown Version 2.0.b6
	
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
	xmlns:gdoc="http://docs.google.com/"
	xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
	xmlns:xhtml="http://www.w3.org/1999/xhtml"
	xmlns="http://www.w3.org/1999/xhtml"
  	exclude-result-prefixes="xhtml xsl gdoc"
	version="1.0">

	<xsl:variable name="newline">
<xsl:text>
</xsl:text>
	</xsl:variable>

	<xsl:param name="footnoteId"/>
	
	<xsl:output method='xml' version="1.0" encoding='utf-8' doctype-public="-//W3C//DTD XHTML 1.1 plus MathML 2.0//EN" doctype-system="http://www.w3.org/TR/MathML2/dtd/xhtml-math11-f.dtd" indent="no"/>

	<!-- the identity template, based on http://www.xmlplease.com/xhtmlxhtml -->
	<xsl:template match="@*|node()">
		<xsl:copy>
			<xsl:apply-templates select="@*|node()"/>
		</xsl:copy>
	</xsl:template>

	<!-- Reformat footnotes for compatibility -->

	<xsl:template match="xhtml:div[@class='footnotes']">
	</xsl:template>
	
	<xsl:template match="xhtml:a[@class='reversefootnote']">
	</xsl:template>
	
	<xsl:template match="xhtml:a[@href][@class='footnote']">
		<gdoc:callout callouttype="footnote">
			<xsl:apply-templates select="/xhtml:html/xhtml:body/xhtml:div[@class]/xhtml:ol/xhtml:li[@id]" mode="footnote">
				<xsl:with-param name="footnoteId" select="@href"/>
			</xsl:apply-templates>
		</gdoc:callout>
	</xsl:template>

	<xsl:template match="xhtml:a[@href][@class='footnote glossary']">
		<gdoc:callout callouttype="footnote">
			<xsl:apply-templates select="/xhtml:html/xhtml:body/xhtml:div[@class]/xhtml:ol/xhtml:li[@id]" mode="footnote">
				<xsl:with-param name="footnoteId" select="@href"/>
			</xsl:apply-templates>
		</gdoc:callout>
	</xsl:template>

	<!-- footnote li -->
	<!-- print contents of the matching footnote -->
	<xsl:template match="xhtml:li" mode="footnote">
		<xsl:param name="footnoteID"/>
		<xsl:if test="parent::xhtml:ol/parent::xhtml:div/@class = 'footnotes'">
			<xsl:if test="concat('#',@id) = $footnoteId">
				<xsl:apply-templates select="node()" mode="footnote"/>
			</xsl:if>
		</xsl:if>
	</xsl:template>

	<xsl:template match="xhtml:p" mode="footnote">
		<xsl:apply-templates select="node()"/>
	</xsl:template>

	<!-- Reformat Bibliography -->
	<xsl:template match="xhtml:div[@class='bibliography']">
		<h1>Bibliography</h1>
		<ul>
			<xsl:apply-templates select="xhtml:div" mode="google-bibliography"/>			
		</ul>
	</xsl:template>
	
	<xsl:template match="xhtml:div" mode="google-bibliography">
		<li>
			<xsl:text>[#</xsl:text>
			<xsl:value-of select="@id"/>
			<xsl:text>] </xsl:text>
			<xsl:apply-templates select="descendant::xhtml:span/node()"/>
		</li>
	</xsl:template>
	
	<!-- convert citations to a footnote to the reference? -->
	<xsl:template match="xhtml:span[@class='markdowncitation']">
		<gdoc:callout callouttype="footnote">
			<xsl:value-of select="descendant::xhtml:a/@href"/>
		</gdoc:callout>
	</xsl:template>

	<xsl:template match="xhtml:span[@class='externalcitation']">
		<gdoc:callout callouttype="footnote">
			<xsl:text>#</xsl:text>
			<xsl:value-of select="descendant::xhtml:a/@id"/>
		</gdoc:callout>
	</xsl:template>
	
</xsl:stylesheet>