<?xml version='1.0' encoding='utf-8'?>

<!-- XHTML-to-SFFMS converter by Fletcher Penney
	specifically designed for use with MultiMarkdown created XHTML

	Uses the SFFMS class for output:
	
		http://www.mcdemarco.net/sffms/
	
	MultiMarkdown Version 2.0.b6
	
	$Id: sffms.xslt 517 2008-09-12 19:37:52Z fletcher $
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
	
	<xsl:template match="/">
		<xsl:apply-templates select="html:html/html:head"/>
		<xsl:apply-templates select="html:html/html:body"/>
		<xsl:call-template name="latex-footer"/>
	</xsl:template>

	<xsl:template name="latex-footer">
		<xsl:text>\end{document}
</xsl:text>
	</xsl:template>

	<xsl:template name="latex-document-class">
		<xsl:text>\documentclass[courier,novel]{sffms}
</xsl:text>
	</xsl:template>

	<xsl:template name="latex-paper-size">
		<xsl:text></xsl:text>
	</xsl:template>

		<xsl:template name="latex-intro">
			<xsl:text>
\begin{document}

</xsl:text>
		</xsl:template>
		
		<xsl:template name="latex-title">
			<xsl:text></xsl:text>
	</xsl:template>

	<xsl:template name="latex-copyright">
			<xsl:text></xsl:text>
	</xsl:template>

	<xsl:template name="latex-begin-body">
		<xsl:text></xsl:text>
	</xsl:template>

	<xsl:template name="latex-header">
	</xsl:template>

	<!-- Rename Bibliography -->
	<xsl:template name="rename-bibliography">
	</xsl:template>

	<!-- Convert headers into chapters, etc -->
	
	<xsl:template match="html:h1">
		<xsl:text>\chapter*{</xsl:text>
		<xsl:apply-templates select="node()"/>
		<xsl:text>}</xsl:text>
		<xsl:value-of select="$newline"/>
		<xsl:text>\label{</xsl:text>
		<xsl:value-of select="@id"/>
		<xsl:text>}</xsl:text>
		<xsl:value-of select="$newline"/>
		<xsl:value-of select="$newline"/>
	</xsl:template>

	<xsl:template match="html:h2">
		<xsl:text>\chapter{</xsl:text>
		<xsl:apply-templates select="node()"/>
		<xsl:text>}</xsl:text>
		<xsl:value-of select="$newline"/>
		<xsl:text>\label{</xsl:text>
		<xsl:value-of select="@id"/>
		<xsl:text>}</xsl:text>
		<xsl:value-of select="$newline"/>
		<xsl:value-of select="$newline"/>
	</xsl:template>

	<xsl:template match="html:h3">
		<xsl:text>\newscene

</xsl:text>
		
	</xsl:template>

	<xsl:template match="html:h4">
	</xsl:template>

	<xsl:template match="html:h5">
	</xsl:template>

	<xsl:template match="html:h6">
	</xsl:template>


		<!-- code block -->
		<xsl:template match="html:pre/html:code">
			<xsl:text>\begin{verbatim}

	</xsl:text>
			<xsl:value-of select="."/>
			<xsl:text>
	\end{verbatim}

	</xsl:text>
		</xsl:template>

	<xsl:template match="*[local-name() = 'title']">
		<xsl:text>\title{</xsl:text>
			<xsl:call-template name="clean-text">
				<xsl:with-param name="source">
					<xsl:value-of select="."/>
				</xsl:with-param>
			</xsl:call-template>		
		<xsl:text>}
</xsl:text>
	</xsl:template>

	<xsl:template match="html:meta">
		<xsl:choose>
			<xsl:when test="translate(@name,'ABCDEFGHIJKLMNOPQRSTUVWXYZ',
			'abcdefghijklmnopqrstuvwxyz') = 'author'">
				<xsl:text>\author{</xsl:text>
				<xsl:call-template name="clean-text">
					<xsl:with-param name="source">
						<xsl:value-of select="@content"/>
					</xsl:with-param>
				</xsl:call-template>		
				<xsl:text>}
</xsl:text>
			</xsl:when>
			<xsl:when test="translate(@name,'ABCDEFGHIJKLMNOPQRSTUVWXYZ',
			'abcdefghijklmnopqrstuvwxyz') = 'latexauthor'">
				<xsl:text>\def\latexauthor{</xsl:text>
					<xsl:value-of select="@content"/>
				<xsl:text>}
</xsl:text>
			</xsl:when>
			<xsl:when test="translate(@name,'ABCDEFGHIJKLMNOPQRSTUVWXYZ',
			'abcdefghijklmnopqrstuvwxyz') = 'authorname'">
				<xsl:text>\authorname{</xsl:text>
				<xsl:call-template name="clean-text">
					<xsl:with-param name="source">
						<xsl:value-of select="@content"/>
					</xsl:with-param>
				</xsl:call-template>		
				<xsl:text>}
</xsl:text>
			</xsl:when>
			<xsl:when test="translate(@name,'ABCDEFGHIJKLMNOPQRSTUVWXYZ',
			'abcdefghijklmnopqrstuvwxyz') = 'title'">
				<xsl:text>\title{</xsl:text>
				<xsl:call-template name="replace-substring">
					<!-- put line breaks in -->
					<xsl:with-param name="original">
						<xsl:call-template name="clean-text">
							<xsl:with-param name="source">
								<xsl:value-of select="@content"/>
							</xsl:with-param>
						</xsl:call-template>		
					</xsl:with-param>
					<xsl:with-param name="substring">
						<xsl:text>   </xsl:text>
					</xsl:with-param>
					<xsl:with-param name="replacement">
						<xsl:text> \\ </xsl:text>
					</xsl:with-param>
				</xsl:call-template>
				<xsl:text>}
</xsl:text>
			</xsl:when>
			<xsl:when test="translate(@name,'ABCDEFGHIJKLMNOPQRSTUVWXYZ',
			'abcdefghijklmnopqrstuvwxyz') = 'runningtitle'">
				<xsl:text>\runningtitle{</xsl:text>
				<xsl:call-template name="clean-text">
					<xsl:with-param name="source">
						<xsl:value-of select="@content"/>
					</xsl:with-param>
				</xsl:call-template>		
				<xsl:text>}
</xsl:text>
			</xsl:when>
			<xsl:when test="translate(@name,'ABCDEFGHIJKLMNOPQRSTUVWXYZ',
			'abcdefghijklmnopqrstuvwxyz') = 'surname'">
				<xsl:text>\surname{</xsl:text>
				<xsl:call-template name="clean-text">
					<xsl:with-param name="source">
						<xsl:value-of select="@content"/>
					</xsl:with-param>
				</xsl:call-template>		
				<xsl:text>}
</xsl:text>
			</xsl:when>
			<xsl:when test="translate(@name,'ABCDEFGHIJKLMNOPQRSTUVWXYZ',
			'abcdefghijklmnopqrstuvwxyz') = 'address'">
				<xsl:text>\address{</xsl:text>
				<xsl:call-template name="replace-substring">
					<!-- put line breaks in -->
					<xsl:with-param name="original">
						<xsl:call-template name="clean-text">
							<xsl:with-param name="source">
								<xsl:value-of select="@content"/>
							</xsl:with-param>
						</xsl:call-template>		
					</xsl:with-param>
					<xsl:with-param name="substring">
						<xsl:text>   </xsl:text>
					</xsl:with-param>
					<xsl:with-param name="replacement">
						<xsl:text> \\ </xsl:text>
					</xsl:with-param>
				</xsl:call-template>
				<xsl:text>}
</xsl:text>
			</xsl:when>
			<xsl:when test="translate(@name,'ABCDEFGHIJKLMNOPQRSTUVWXYZ',
			'abcdefghijklmnopqrstuvwxyz') = 'wordcount'">
				<xsl:text>\wordcount{</xsl:text>
				<xsl:call-template name="clean-text">
					<xsl:with-param name="source">
						<xsl:value-of select="@content"/>
					</xsl:with-param>
				</xsl:call-template>		
				<xsl:text>}
</xsl:text>
			</xsl:when>
		</xsl:choose>
	</xsl:template>


	<!-- Changes due to limitations of manuscript format -->
	<xsl:template match="html:a[@href]">
		<xsl:value-of select="."/>
		<xsl:text>(</xsl:text>
		<xsl:call-template name="clean-text">
			<xsl:with-param name="source">
				<xsl:value-of select="@href"/>
			</xsl:with-param>
		</xsl:call-template>		
		<xsl:text>)</xsl:text>
	</xsl:template>

	<!-- emphasis -->
	<xsl:template match="html:em">
		<xsl:text>\underline{</xsl:text>
			<xsl:apply-templates select="node()"/>
		<xsl:text>}</xsl:text>
	</xsl:template>

	<!-- strong -->
	<xsl:template match="html:strong">
		<xsl:text>\textbf{</xsl:text>
			<xsl:apply-templates select="node()"/>
		<xsl:text>}</xsl:text>
	</xsl:template>

</xsl:stylesheet>