<?xml version='1.0' encoding='utf-8'?>

<!-- xhtml2rtf replace-substring utility file by Fletcher Penney
	specifically designed for use with MultiMarkdown created XHTML
	
	Extracted this routine so that it can be changed more easily by users.
	
	This file is responsible for cleaning up special characters into
		an RTF-friendly format.
	
	MultiMarkdown Version 2.0.b6
		
-->

<!-- 
# Copyright (C) 2009  Fletcher T. Penney <fletcher@fletcherpenney.net>
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

	<!-- Pass XHTML Comments through unaltered (useful for including
		raw RTF in your MultiMarkdown document) -->
	<xsl:template match="comment()">
		<xsl:value-of select="."/>
	</xsl:template>
	
	<!-- This is a "pointer" function that can be over-ridden easily
	 	in order to add quick additional changes -->
	<xsl:template name="clean-text">
		<xsl:param name="source"/>
		<xsl:call-template name="clean-text-utility">
			<xsl:with-param name="source">
				<xsl:value-of select="$source"/>
			</xsl:with-param>
		</xsl:call-template>
	</xsl:template>
	
	<!-- This is the "real" function that does the work.  You can also
		override this if you need to make some real changes -->
	<xsl:template name="clean-text-utility">
		<xsl:param name="source" />
		<xsl:call-template name="replace-substring">
			<xsl:with-param name="original">
		<xsl:call-template name="replace-substring">
			<xsl:with-param name="original">
		<xsl:call-template name="replace-substring">
			<xsl:with-param name="original">
		<xsl:call-template name="replace-substring">
			<xsl:with-param name="original">
		<xsl:call-template name="replace-substring">
			<xsl:with-param name="original">
		<xsl:call-template name="replace-substring">
			<xsl:with-param name="original">
		<xsl:call-template name="replace-substring">
			<xsl:with-param name="original">
		<xsl:call-template name="replace-substring">
			<xsl:with-param name="original">
		<xsl:call-template name="replace-substring">
			<xsl:with-param name="original">
		<xsl:call-template name="replace-substring">
			<xsl:with-param name="original">
			<xsl:value-of select="$source"/>
			</xsl:with-param>
			<xsl:with-param name="substring">
				<xsl:text>\</xsl:text>
			</xsl:with-param>
			<xsl:with-param name="replacement">
				<xsl:text>\\</xsl:text>
			</xsl:with-param>
		</xsl:call-template>
			</xsl:with-param>
			<xsl:with-param name="substring">
				<xsl:text>&#8217;</xsl:text>
			</xsl:with-param>
			<xsl:with-param name="replacement">
				<xsl:text>\'92</xsl:text>
			</xsl:with-param>
		</xsl:call-template>
			</xsl:with-param>
			<xsl:with-param name="substring">
				<xsl:text>&#8216;</xsl:text>
			</xsl:with-param>
			<xsl:with-param name="replacement">
				<xsl:text>\'91</xsl:text>
			</xsl:with-param>
		</xsl:call-template>
			</xsl:with-param>
			<xsl:with-param name="substring">
				<xsl:text>&#8220;</xsl:text>
			</xsl:with-param>
			<xsl:with-param name="replacement">
				<xsl:text>\'93</xsl:text>
			</xsl:with-param>
		</xsl:call-template>
			</xsl:with-param>
			<xsl:with-param name="substring">
				<xsl:text>&#8221;</xsl:text>
			</xsl:with-param>
			<xsl:with-param name="replacement">
				<xsl:text>\'94</xsl:text>
			</xsl:with-param>
		</xsl:call-template>
			</xsl:with-param>
			<xsl:with-param name="substring">
				<xsl:text>&#8211;</xsl:text>
			</xsl:with-param>
			<xsl:with-param name="replacement">
				<xsl:text>\endash </xsl:text>
			</xsl:with-param>
		</xsl:call-template>
			</xsl:with-param>
			<xsl:with-param name="substring">
				<xsl:text>&#8212;</xsl:text>
			</xsl:with-param>
			<xsl:with-param name="replacement">
				<xsl:text>\emdash </xsl:text>
			</xsl:with-param>
		</xsl:call-template>
			</xsl:with-param>
			<xsl:with-param name="substring">
				<xsl:text>&#8230;</xsl:text>
			</xsl:with-param>
			<xsl:with-param name="replacement">
				<xsl:text>\'85</xsl:text>
			</xsl:with-param>
		</xsl:call-template>
			</xsl:with-param>
			<xsl:with-param name="substring">
				<xsl:text>{</xsl:text>
			</xsl:with-param>
			<xsl:with-param name="replacement">
				<xsl:text>\{</xsl:text>
			</xsl:with-param>
		</xsl:call-template>
			</xsl:with-param>
			<xsl:with-param name="substring">
				<xsl:text>}</xsl:text>
			</xsl:with-param>
			<xsl:with-param name="replacement">
				<xsl:text>\}</xsl:text>
			</xsl:with-param>
		</xsl:call-template>
	</xsl:template>


	<!-- replace-substring routine by Doug Tidwell - XSLT, O'Reilly Media -->
	<xsl:template name="replace-substring">
		<xsl:param name="original" />
		<xsl:param name="substring" />
		<xsl:param name="replacement" select="''"/>
		<xsl:variable name="first">
			<xsl:choose>
				<xsl:when test="contains($original, $substring)" >
					<xsl:value-of select="substring-before($original, $substring)"/>
				</xsl:when>
				<xsl:otherwise>
					<xsl:value-of select="$original"/>
				</xsl:otherwise>
			</xsl:choose>
		</xsl:variable>
		<xsl:variable name="middle">
			<xsl:choose>
				<xsl:when test="contains($original, $substring)" >
					<xsl:value-of select="$replacement"/>
				</xsl:when>
				<xsl:otherwise>
					<xsl:text></xsl:text>
				</xsl:otherwise>
			</xsl:choose>
		</xsl:variable>
		<xsl:variable name="last">
			<xsl:choose>
				<xsl:when test="contains($original, $substring)">
					<xsl:choose>
						<xsl:when test="contains(substring-after($original, $substring), $substring)">
							<xsl:call-template name="replace-substring">
								<xsl:with-param name="original">
									<xsl:value-of select="substring-after($original, $substring)" />
								</xsl:with-param>
								<xsl:with-param name="substring">
									<xsl:value-of select="$substring" />
								</xsl:with-param>
								<xsl:with-param name="replacement">
									<xsl:value-of select="$replacement" />
								</xsl:with-param>
							</xsl:call-template>
						</xsl:when>	
						<xsl:otherwise>
							<xsl:value-of select="substring-after($original, $substring)"/>
						</xsl:otherwise>
					</xsl:choose>
				</xsl:when>
				<xsl:otherwise>
					<xsl:text></xsl:text>
				</xsl:otherwise>		
			</xsl:choose>				
		</xsl:variable>		
		<xsl:value-of select="concat($first, $middle, $last)"/>
	</xsl:template>
</xsl:stylesheet>