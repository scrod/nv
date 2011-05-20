<?xml version='1.0' encoding='utf-8'?>

<!-- OPML-to-text converter by Fletcher Penney


-->

<!-- 
# Copyright (C) 2010  Fletcher T. Penney <fletcher@fletcherpenney.net>
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
	version="1.0">

	<xsl:output method="text" encoding="utf-8"/>

	<xsl:preserve-space elements="*"/>

	<xsl:template match="/opml">
		<xsl:apply-templates select="head/titledisabled"/>
		<xsl:apply-templates select="/opml/body/outline[last()]" mode="meta"/>
		<xsl:apply-templates select="body"/>
	</xsl:template>

	<xsl:template match="title">
		<xsl:text>Title:	</xsl:text>
				<xsl:value-of select="."/>
		<xsl:text>
</xsl:text>
	</xsl:template>

	<xsl:template match="body">
		<xsl:param name="header"/>
		<xsl:text>

</xsl:text>
		<xsl:apply-templates select="outline">
			<xsl:with-param name="header" select="concat($header,'#')"/>
		</xsl:apply-templates>
	</xsl:template>

	<xsl:template match="outline">
		<xsl:param name="header"/>
		<xsl:value-of select="concat($header,' ')"/>
		<xsl:value-of select="@text"/>
		<xsl:value-of select="concat(' ',$header)"/>
		<xsl:text>

</xsl:text>
		<xsl:value-of select="@_note"/>
		<xsl:text>

</xsl:text>
		<xsl:apply-templates select="outline">
			<xsl:with-param name="header" select="concat($header,'#')"/>
		</xsl:apply-templates>
	</xsl:template>
	
	<xsl:template match="/opml/body/outline[last()]">
		<xsl:if test="not(translate(@text,'ABCDEFGHIJKLMNOPQRSTUVWXYZ',
			'abcdefghijklmnopqrstuvwxyz') = 'metadata')">
			<xsl:apply-templates select="outline" mode="metadata"/>
					<xsl:param name="header"/>
					<xsl:value-of select="concat($header,' ')"/>
					<xsl:value-of select="@text"/>
					<xsl:value-of select="concat(' ',$header)"/>
					<xsl:text>

			</xsl:text>
					<xsl:value-of select="@_note"/>
					<xsl:text>

			</xsl:text>
					<xsl:apply-templates select="outline">
						<xsl:with-param name="header" select="concat($header,'#')"/>
					</xsl:apply-templates>
		</xsl:if>
	</xsl:template>

	<xsl:template match="/opml/body/outline[last()]" mode="meta">
		<xsl:if test="(translate(@text,'ABCDEFGHIJKLMNOPQRSTUVWXYZ',
			'abcdefghijklmnopqrstuvwxyz') = 'metadata')">
			<xsl:apply-templates select="outline" mode="metadata"/>
		</xsl:if>
	</xsl:template>
	
	<xsl:template match="outline" mode="metadata">
		<xsl:value-of select="@text"/>
		<xsl:text>:	</xsl:text>
		<xsl:value-of select="@_note"/>
		<xsl:text>
</xsl:text>
	</xsl:template>
	
</xsl:stylesheet>