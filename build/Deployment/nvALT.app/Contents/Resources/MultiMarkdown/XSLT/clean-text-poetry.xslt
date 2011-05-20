<?xml version="1.0" encoding="utf-8"?>

<!-- XHTML2LaTeX replace-substring utility file by Fletcher Penney
	specifically designed for use with MultiMarkdown created XHTML
	
	Extracted this routine so that it can be changed more easily by users.
	
	This file is responsible for cleaning up special characters into
		a LaTeX-friendly format.
	
	Modified to support features needed for poetry.

	MultiMarkdown Version 2.0.b6
		
	$Id: clean-text-poetry.xslt 499 2008-03-23 13:03:19Z fletcher $
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

	<!-- It's still built on the original -->
	<xsl:import href="clean-text.xslt"/>


	<!-- Find the longest line of a poem -->
	<xsl:template name="longest-line">
		<xsl:param name="source"/>
		<xsl:variable name="first">
			<xsl:value-of select="substring-before($source, $newline)"/>
		</xsl:variable>
		<xsl:variable name="rest">
			<xsl:value-of select="substring-after($source, $newline)"/>
		</xsl:variable>
		<xsl:choose>
			<xsl:when test="contains($rest, $newline)">
				<xsl:variable name="second">
					<xsl:call-template name="longest-line">
						<xsl:with-param name="source">
							<xsl:value-of select="$rest"/>
						</xsl:with-param>
					</xsl:call-template>
				</xsl:variable>
				<xsl:choose>
					<xsl:when test="string-length($first) &gt; string-length($second)">
						<xsl:value-of select="$first"/>
					</xsl:when>
					<xsl:otherwise>
						<xsl:value-of select="$second"/>
					</xsl:otherwise>
				</xsl:choose>
			</xsl:when>
			<xsl:otherwise>
				<xsl:value-of select="$rest"/>
			</xsl:otherwise>
		</xsl:choose>
	</xsl:template>


	<!-- This version is for blocks of poetry.  In additional to the usual
		cleanup, it changes the newlines for poetry typesetting, and replaces
		leading spaces or tabs with \vin -->
	<xsl:template name="poetry-text">
		<xsl:param name="source"/>
		<xsl:call-template name="replace-substring">
			<xsl:with-param name="original">
		<xsl:call-template name="replace-substring">
			<xsl:with-param name="original">
		<xsl:call-template name="replace-substring">
			<xsl:with-param name="original">
				<xsl:call-template name="clean-text-utility">
					<xsl:with-param name="source">
						<xsl:value-of select="$source"/>
					</xsl:with-param>
				</xsl:call-template>
			</xsl:with-param>
			<xsl:with-param name="substring">
				<xsl:value-of select="$newline"/>
			</xsl:with-param>
			<xsl:with-param name="replacement">
				<xsl:text> \\</xsl:text>
				<xsl:value-of select="$newline"/>
			</xsl:with-param>
		</xsl:call-template>
			</xsl:with-param>
			<xsl:with-param name="substring">
				<xsl:value-of select="$newline"/>
				<xsl:text> \\</xsl:text>
				<xsl:value-of select="$newline"/>
			</xsl:with-param>
			<xsl:with-param name="replacement">
				<xsl:text>!</xsl:text>
				<xsl:value-of select="$newline"/>
				<xsl:value-of select="$newline"/>
			</xsl:with-param>
		</xsl:call-template>
			</xsl:with-param>
			<xsl:with-param name="substring">
				<xsl:text>    </xsl:text>
			</xsl:with-param>
			<xsl:with-param name="replacement">
				<xsl:text>\vin </xsl:text>
			</xsl:with-param>
		</xsl:call-template>
	</xsl:template>

</xsl:stylesheet>
