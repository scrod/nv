<?xml version='1.0' encoding='utf-8'?>

<!-- XHTML-to-S5 converted by Fletcher Penney
	specifically designed for use with MultiMarkdown created XHTML
	
	MultiMarkdown Version 2.0.b6
	
	$Id: s5.xslt 499 2008-03-23 13:03:19Z fletcher $
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

<!-- 
	TODO: an option to select what h-level should be slides (for instance, if h2, then each h1 would be a slide, containing list of h2's.  Then h2's converted into slides....
	
	-->
	
<xsl:stylesheet
	xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
	xmlns:xhtml="http://www.w3.org/1999/xhtml"
	xmlns="http://www.w3.org/1999/xhtml"
  	exclude-result-prefixes="xhtml xsl"
	version="1.0">

	<xsl:output method='xml' encoding='utf-8' indent="yes"/>

	<xsl:strip-space elements="*" />

	<xsl:variable name="theme">default</xsl:variable>

	<xsl:param name="match"/>

	<xsl:template match="/">
		<html>
		<xsl:apply-templates select="node()"/>
		</html>
	</xsl:template>

	<xsl:template match="xhtml:head">
		<head>
		<xsl:apply-templates select="xhtml:meta"/>
		<xsl:apply-templates select="node()"/>
		<meta name="version" content="S5 1.1" />
		<meta name="generator" content="MultiMarkdown"/>
		<meta name="controlVis" content="hidden"/>
		<link rel="stylesheet" href="ui/{$theme}/slides.css" type="text/css" media="projection" id="slideProj" />
		<link rel="stylesheet" href="ui/default/outline.css" type="text/css" media="screen" id="outlineStyle" />
		<link rel="stylesheet" href="ui/default/print.css" type="text/css" media="print" id="slidePrint" />
		<link rel="stylesheet" href="ui/default/opera.css" type="text/css" media="projection" id="operaFix" />
		<script src="ui/default/slides.js" type="text/javascript"></script>
		</head>
	</xsl:template>

	<xsl:template match="xhtml:title">
		<title><xsl:value-of select="."/></title>
	</xsl:template>

	<xsl:template match="xhtml:body">
		<body>
		<div class="layout">
			<div id="controls"><xsl:text>&#x0020;</xsl:text></div>
			<div id="currentSlide"><xsl:text>&#x0020;</xsl:text></div>
			<div id="header"><xsl:text>&#x0020;</xsl:text></div>
			<div id="footer">
			<h1><xsl:value-of select="/xhtml:html/xhtml:head/xhtml:title"/></h1>
			<h2>
				<xsl:value-of select="/xhtml:html/xhtml:head/xhtml:meta[translate(@name,'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz') = 'author']/@content"/>
			</h2>
			</div>
		</div>
		<div class="presentation">
		<div class="slide">
		<h1><xsl:value-of select="/xhtml:html/xhtml:head/xhtml:title"/></h1>
		<h2><xsl:value-of select="/xhtml:html/xhtml:head/xhtml:meta[translate(@name,'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz') = 'subtitle']/@content"/></h2>
		<h3>
		<xsl:value-of select="/xhtml:html/xhtml:head/xhtml:meta[translate(@name,'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz') = 'author']/@content"/>
		</h3>
		<xsl:variable name="url">
			<xsl:value-of select="/xhtml:html/xhtml:head/xhtml:meta[translate(@name,'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz') = 'url']/@content"/>
		</xsl:variable>
		<h4><a href="{$url}">
<xsl:value-of select="/xhtml:html/xhtml:head/xhtml:meta[translate(@name,'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz') = 'organization']/@content"/>
		</a></h4>
		<h4>
			<xsl:value-of select="/xhtml:html/xhtml:head/xhtml:meta[translate(@name,'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz') = 'date']/@content"/>
		</h4>				
		</div>
		
		<xsl:apply-templates select="xhtml:h1"/>
		</div>
		</body>
	</xsl:template>


	<xsl:template match="xhtml:h1">
		<div class="slide">
			<h1><xsl:value-of select="."/></h1>	
			<xsl:variable name="items" select="count(following-sibling::*) - count(following-sibling::xhtml:h1[1]/following-sibling::*) - count(following-sibling::xhtml:h1[1])"/>
			<xsl:apply-templates select="following-sibling::*[position() &lt;= $items]" mode="slide"/>
		</div>		
	</xsl:template>

	<xsl:template match="xhtml:h1[last()]">
		<div class="slide">
		<h1><xsl:value-of select="."/></h1>
		<xsl:variable name="items" select="count(following-sibling::*) - count(following-sibling::h1/following-sibling::*)"/>
		<xsl:apply-templates select="following-sibling::*[position() &lt;= $items]" mode="slide"/>
		</div>
	</xsl:template>

	<xsl:template match="xhtml:p" mode="slide">
		<xsl:copy-of select="."/>
	</xsl:template>

	<xsl:template match="xhtml:p[1]" mode="slide">
		<xsl:copy-of select="."/>
	</xsl:template>

	<xsl:template match="xhtml:li" mode="slide">
		<li>
		<xsl:apply-templates select="node()" mode="slide"/>
		</li>
	</xsl:template>

	<xsl:template match="xhtml:ol" mode="slide">
<!--		<ol class="incremental show-first"> -->
		<ol>
			<xsl:apply-templates select="node()" mode="slide"/>
		</ol>
	</xsl:template>

	<xsl:template match="xhtml:ul" mode="slide">
		<ul>
			<xsl:apply-templates select="node()" mode="slide"/>
		</ul>
	</xsl:template>
</xsl:stylesheet>


