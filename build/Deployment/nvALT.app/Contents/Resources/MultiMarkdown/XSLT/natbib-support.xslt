<?xml version='1.0' encoding='utf-8'?>

<!-- XHTML-to-Article converter by Fletcher Penney
	specifically designed for use with MultiMarkdown created XHTML
	
	Adds support for natbib citations.
	
	Requires that the following command (or equivalent) be included
	in the header:
	
		\usepackage[round]{natbib}
	
	
	MultiMarkdown Version 2.0.b6
	
	$Id: natbib-support.xslt 499 2008-03-23 13:03:19Z fletcher $
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
	
	<xsl:output method='text' encoding='utf-8'/>

	<xsl:strip-space elements="*" />

	<!-- use \citep by default -->
	<xsl:template match="html:span[@class='externalcitation']">
		<xsl:text>\citep</xsl:text>
		<xsl:apply-templates select="html:span" mode="citation"/>
		<xsl:apply-templates select="html:a" mode="citation"/>
		<xsl:text>}</xsl:text>
	</xsl:template>

	<xsl:template match="html:span[@class='markdowncitation']">
		<xsl:text>~\citep</xsl:text>
		<xsl:apply-templates select="html:span" mode="citation"/>
		<xsl:apply-templates select="html:a" mode="markdowncitation"/>
		<xsl:text>}</xsl:text>
	</xsl:template>

	<!-- use \citet when indicated -->
	<xsl:template match="html:span[@class='externalcitation'][child::html:span[position()='1'][@class='textual citation']]">
		<xsl:text>\citet</xsl:text>
		<xsl:apply-templates select="html:span" mode="citation"/>
		<xsl:apply-templates select="html:a" mode="citation"/>
		<xsl:text>}</xsl:text>
	</xsl:template>

	<xsl:template match="html:span[@class='markdowncitation'][child::html:span[position()='1'][@class='textual citation']]">
		<xsl:text>~\citet</xsl:text>
		<xsl:apply-templates select="html:span" mode="citation"/>
		<xsl:apply-templates select="html:a" mode="markdowncitation"/>
		<xsl:text>}</xsl:text>
	</xsl:template>

	<!-- Disable the text (not used for LaTeX output) -->
	<xsl:template match="html:span[@class='textual citation']" mode="citation">
		<xsl:text></xsl:text>
	</xsl:template>

</xsl:stylesheet>