<?xml version='1.0' encoding='utf-8'?>

<!-- XHTML-to-Latex converter by Fletcher Penney
	specifically designed for use with MultiMarkdown created XHTML
	
	MultiMarkdown Version 2.0.b6
	
	$Id: xhtml2latex.xslt 517 2008-09-12 19:37:52Z fletcher $
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
	xmlns:m="http://www.w3.org/1998/Math/MathML"
	xmlns:html="http://www.w3.org/1999/xhtml"
	version="1.0">

	<xsl:import href="../MultiMarkdownXSLTMathML/mmltex.xsl"/>
	<xsl:import href="clean-text.xslt"/>

	<xsl:output method='text' encoding='utf-8'/>

	<xsl:strip-space elements="*" />

	<xsl:variable name="newline">
<xsl:text>
</xsl:text>
	</xsl:variable>

	<xsl:param name="footnoteId"/>

	<xsl:decimal-format name="string" NaN="1"/>

	<xsl:template match="*[local-name() = 'title']">
		<xsl:text>\def\mytitle{</xsl:text>
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
				<xsl:text>\def\myauthor{</xsl:text>
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
		'abcdefghijklmnopqrstuvwxyz') = 'date'">
			<xsl:text>\date{</xsl:text>
			<xsl:call-template name="clean-text">
				<xsl:with-param name="source">
					<xsl:value-of select="@content"/>
				</xsl:with-param>
			</xsl:call-template>		
			<xsl:text>}
\def\mydate{</xsl:text>
			<xsl:call-template name="clean-text">
				<xsl:with-param name="source">
					<xsl:value-of select="@content"/>
				</xsl:with-param>
			</xsl:call-template>
			<xsl:text>}
</xsl:text>
		</xsl:when>
			<xsl:when test="translate(@name,'ABCDEFGHIJKLMNOPQRSTUVWXYZ',
			'abcdefghijklmnopqrstuvwxyz') = 'affiliation'">
				<xsl:text>\def\affiliation{</xsl:text>
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
			'abcdefghijklmnopqrstuvwxyz') = 'revision'">
				<xsl:text>\def\revision{Revision: </xsl:text>
				<xsl:call-template name="clean-text">
					<xsl:with-param name="source">
						<xsl:value-of select="@content"/>
					</xsl:with-param>
				</xsl:call-template>		
				<xsl:text>}
</xsl:text>
			</xsl:when>
			<xsl:when test="translate(@name,'ABCDEFGHIJKLMNOPQRSTUVWXYZ',
			'abcdefghijklmnopqrstuvwxyz') = 'email'">
				<xsl:text>\def\email{ \href{mailto:</xsl:text>
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
				<xsl:text>}{</xsl:text>
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
				<xsl:text>}}
</xsl:text>
			</xsl:when>
			<xsl:when test="translate(@name,'ABCDEFGHIJKLMNOPQRSTUVWXYZ',
			'abcdefghijklmnopqrstuvwxyz') = 'web'">
				<xsl:text>\def\web{\href{</xsl:text>
				<xsl:if test="not(starts-with(@content,'http:'))">
					<xsl:text>http://</xsl:text>
				</xsl:if>
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
				<xsl:text>}{</xsl:text>
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
				<xsl:text>}}
</xsl:text>
			</xsl:when>
			<xsl:when test="translate(@name,'ABCDEFGHIJKLMNOPQRSTUVWXYZ',
			'abcdefghijklmnopqrstuvwxyz') = 'keywords'">
				<xsl:text>\def\mykeywords{</xsl:text>
				<xsl:call-template name="replace-substring">
					<xsl:with-param name="original">
						<xsl:value-of select="@content"/>
					</xsl:with-param>
					<xsl:with-param name="substring">
						<xsl:text>,,</xsl:text>
					</xsl:with-param>
					<xsl:with-param name="replacement">
						<xsl:text>,</xsl:text>
					</xsl:with-param>
				</xsl:call-template>
				<xsl:text>}
</xsl:text>
			</xsl:when>
			<xsl:when test="translate(@name,'ABCDEFGHIJKLMNOPQRSTUVWXYZ',
			'abcdefghijklmnopqrstuvwxyz') = 'xmp'">
				<xsl:text>\usepackage{xmpincl}
\includexmp{</xsl:text>
				<xsl:call-template name="clean-text">
					<xsl:with-param name="source">
						<xsl:value-of select="@content"/>
					</xsl:with-param>
				</xsl:call-template>		
				<xsl:text>}
</xsl:text>
			</xsl:when>
			<xsl:when test="translate(@name,'ABCDEFGHIJKLMNOPQRSTUVWXYZ',
			'abcdefghijklmnopqrstuvwxyz') = 'bibtex'">
				<xsl:text>\def\bibliocommand{\bibliography{</xsl:text>
				<xsl:call-template name="clean-text">
					<xsl:with-param name="source">
						<xsl:value-of select="@content"/>
					</xsl:with-param>
				</xsl:call-template>		
				<xsl:text>}}
</xsl:text>
			</xsl:when>
			<xsl:when test="translate(@name,'ABCDEFGHIJKLMNOPQRSTUVWXYZ',
			'abcdefghijklmnopqrstuvwxyz') = 'bibliographystyle'">
				<xsl:text>\def\mybibliostyle{</xsl:text>
				<xsl:call-template name="clean-text">
					<xsl:with-param name="source">
						<xsl:value-of select="@content"/>
					</xsl:with-param>
				</xsl:call-template>		
				<xsl:text>}
</xsl:text>
			</xsl:when>
			<xsl:when test="translate(@name,'ABCDEFGHIJKLMNOPQRSTUVWXYZ',
			'abcdefghijklmnopqrstuvwxyz') = 'bibliographytitle'">
				<xsl:call-template name="rename-bibliography">
					<xsl:with-param name="source">
						<xsl:value-of select="@content"/>
					</xsl:with-param>
				</xsl:call-template>		
			</xsl:when>
			<xsl:when test="translate(@name,'ABCDEFGHIJKLMNOPQRSTUVWXYZ',
			'abcdefghijklmnopqrstuvwxyz') = 'chapterstyle'">
				<xsl:text>\def\mychapterstyle{</xsl:text>
				<xsl:call-template name="clean-text">
					<xsl:with-param name="source">
						<xsl:value-of select="@content"/>
					</xsl:with-param>
				</xsl:call-template>		
				<xsl:text>}
</xsl:text>
			</xsl:when>
			<xsl:when test="translate(@name,'ABCDEFGHIJKLMNOPQRSTUVWXYZ',
			'abcdefghijklmnopqrstuvwxyz') = 'pagestyle'">
				<xsl:text>\def\mypagestyle{</xsl:text>
				<xsl:call-template name="clean-text">
					<xsl:with-param name="source">
						<xsl:value-of select="@content"/>
					</xsl:with-param>
				</xsl:call-template>		
				<xsl:text>}
</xsl:text>
			</xsl:when>
			<xsl:when test="translate(@name,'ABCDEFGHIJKLMNOPQRSTUVWXYZ',
			'abcdefghijklmnopqrstuvwxyz') = 'copyright'">
				<xsl:text>\def\mycopyright{</xsl:text>
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
			'abcdefghijklmnopqrstuvwxyz') = 'closing'">
				<xsl:text>\def\myclosing{</xsl:text>
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
			<xsl:otherwise>
				<xsl:text>\def\</xsl:text>
				<xsl:value-of select="translate(@name,'ABCDEFGHIJKLMNOPQRSTUVWXYZ',
				'abcdefghijklmnopqrstuvwxyz')"/>
				<xsl:text>{</xsl:text>
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
			</xsl:otherwise>
		</xsl:choose>
	</xsl:template>

	<xsl:template match="html:body">
		<xsl:apply-templates select="*|comment()"/>
		<!-- <xsl:apply-templates select="*"/> 		Use this version to ignore text within XHTML comments-->
	</xsl:template>

	<xsl:template match="html:head">
		<!-- Init Latex -->
		<xsl:call-template name="latex-document-class"/>
		<xsl:call-template name="latex-paper-size"/>
		<xsl:call-template name="latex-header"/>
		<xsl:apply-templates select="*"/>
		<xsl:call-template name="latex-intro"/>
		<xsl:call-template name="latex-title"/>
		<xsl:call-template name="latex-copyright"/>
		<xsl:call-template name="latex-begin-body"/>
	</xsl:template>

	<!-- ignore  other information within the header 
		This will need to be expanded upon over time -->

	<xsl:template match="html:head/html:style">
	</xsl:template>

	<xsl:template match="html:head/html:base">
	</xsl:template>

	<xsl:template match="html:head/html:link">
	</xsl:template>

	<xsl:template match="html:head/html:object">
	</xsl:template>
	
	<xsl:template match="html:head/html:script">
	</xsl:template>


	<xsl:template name="latex-title">
		<!-- Set up title -->
		<xsl:text>

% Title Page

\maketitle

</xsl:text>
	</xsl:template>

	<xsl:template name="latex-copyright">
		<!-- Set up copyright -->
		<xsl:text>% Copyright Page
\ifx\mycopyright\undefined
\else
	\textcopyright{} \mycopyright
\fi



</xsl:text>
	</xsl:template>

	<xsl:template name="latex-begin-body">
		<xsl:text>%
% Main Content
%


</xsl:text>
	</xsl:template>
		

	<xsl:template match="text()">
		<xsl:call-template name="clean-text">
			<xsl:with-param name="source">
				<xsl:value-of select="."/>
			</xsl:with-param>
		</xsl:call-template>
	</xsl:template>

	<xsl:template match="m:*/text()">
		<xsl:call-template name="replaceEntities">
			<xsl:with-param name="content" select="normalize-space()"/>
		</xsl:call-template>
	</xsl:template>
	
	<!-- Rename Bibliography -->
	<xsl:template name="rename-bibliography">
		<xsl:param name="source" />
		<xsl:text>\renewcommand\refname{</xsl:text>
		<xsl:value-of select="$source" />
		<xsl:text>}
</xsl:text>
	</xsl:template>


	<!-- paragraphs -->
	
	<xsl:template match="html:p">
		<xsl:apply-templates select="node()"/>
		<xsl:value-of select="$newline"/>
		<xsl:value-of select="$newline"/>
		<xsl:value-of select="$newline"/>
	</xsl:template>

	<!-- last paragraph in a blockquote doesn't need extra newline -->
	<!-- needed for epigraph support -->
	<xsl:template match="html:p[last()][parent::*[local-name() = 'blockquote']]">
		<xsl:apply-templates select="node()"/>
		<xsl:value-of select="$newline"/>
	</xsl:template>
	
	<!-- footnote li -->
	<!-- print contents of the matching footnote -->
	<xsl:template match="html:li" mode="footnote">
		<xsl:param name="footnoteId"/>
		<xsl:if test="parent::html:ol/parent::html:div/@class = 'footnotes'">
			<xsl:if test="concat('#',@id) = $footnoteId">
				<xsl:apply-templates select="node()"/>
			</xsl:if>
		</xsl:if>
	</xsl:template>

	<!-- last paragraph in footnote does not need trailing space -->
	<xsl:template match="html:p[last()][parent::html:li[parent::html:ol[parent::html:div[@class='footnotes']]]]">
		<xsl:param name="footnoteId"/>
		<xsl:apply-templates select="node()"/>
	</xsl:template>

	<!-- print contents of the matching footnote as a glossary entry-->
	<xsl:template match="html:li" mode="glossary">
		<xsl:param name="footnoteId"/>
		<xsl:if test="parent::html:ol/parent::html:div/@class = 'footnotes'">
			<xsl:if test="concat('#',@id) = $footnoteId">
				<xsl:apply-templates select="html:span" mode="glossary"/>
				<xsl:text>description=</xsl:text>
				<xsl:apply-templates select="html:p" mode="glossary"/>
				<xsl:text>}</xsl:text>
			</xsl:if>
		</xsl:if>
	</xsl:template>
	
	<xsl:template match="html:p" mode="glossary">
		<xsl:apply-templates select="node()"/>
		<xsl:if test="position()!= last()">
			<xsl:text>\\
\\
</xsl:text>
		</xsl:if>
	</xsl:template>

	<xsl:template match="html:p[last()]" mode="glossary">
		<xsl:apply-templates select="node()"/>
	</xsl:template>
	
	<!-- use these when asked for -->
	<xsl:template match="html:span[@class='glossary name']" mode="glossary">
		<xsl:text>{name=</xsl:text>
		<xsl:apply-templates select="node()"/>
		<xsl:text>,</xsl:text>
	</xsl:template>
	
	<xsl:template match="html:span[@class='glossary sort']" mode="glossary">
		<xsl:text>sort=</xsl:text>
		<xsl:apply-templates select="node()"/>
		<xsl:text>,</xsl:text>
	</xsl:template>

	<!-- otherwise, ignore them -->
	<xsl:template match="html:span[@class='glossary name']">
	</xsl:template>
	
	<xsl:template match="html:span[@class='glossary sort']">
	</xsl:template>

	<!-- anchors -->
	<xsl:template match="html:a[@href]">
		<xsl:param name="footnoteId"/>
		<xsl:choose>
			<!-- footnote (my addition)-->
			<xsl:when test="@class = 'footnote'">
				<xsl:text>\footnote{</xsl:text>
				<xsl:apply-templates select="/html:html/html:body/html:div[@class]/html:ol/html:li[@id]" mode="footnote">
					<xsl:with-param name="footnoteId" select="@href"/>
				</xsl:apply-templates>
				<xsl:text>}</xsl:text>
			</xsl:when>

			<xsl:when test="@class = 'footnote glossary'">
				<xsl:text>\glossary</xsl:text>
				<xsl:apply-templates select="/html:html/html:body/html:div[@class]/html:ol/html:li[@id]" mode="glossary">
					<xsl:with-param name="footnoteId" select="@href"/>
				</xsl:apply-templates>
				<xsl:text></xsl:text>
			</xsl:when>

			<xsl:when test="@class = 'reversefootnote'">
			</xsl:when>

			<!-- if href is same as the anchor text, then use \href{} 
				but no footnote -->
			<!-- let's try \url{} again for line break reasons -->
			<xsl:when test="@href = .">
				<xsl:text>\url{</xsl:text>
				<xsl:call-template name="clean-text">
					<xsl:with-param name="source">
						<xsl:value-of select="@href"/>
					</xsl:with-param>
				</xsl:call-template>		
				<xsl:text>}</xsl:text>
			</xsl:when>

			<!-- if href is mailto, use \href{} -->
			<xsl:when test="starts-with(@href,'mailto:')">
				<xsl:text>\href{</xsl:text>
				<xsl:value-of select="@href"/>
				<xsl:text>}{</xsl:text>
				<xsl:call-template name="clean-text">
					<xsl:with-param name="source">
						<xsl:value-of select="substring-after(@href,'mailto:')"/>
					</xsl:with-param>
				</xsl:call-template>		
				<xsl:text>}</xsl:text>
			</xsl:when>
			
			<!-- if href is local anchor, use autoref -->
			<xsl:when test="starts-with(@href,'#')">
				<xsl:choose>
					<xsl:when test=". = ''">
						<xsl:text>\autoref{</xsl:text>
						<xsl:value-of select="substring-after(@href,'#')"/>
						<xsl:text>}</xsl:text>
					</xsl:when>
					<xsl:otherwise>
						<xsl:value-of select="."/>
						<xsl:text> (\autoref{</xsl:text>
						<xsl:value-of select="substring-after(@href,'#')"/>
						<xsl:text>})</xsl:text>
					</xsl:otherwise>
				</xsl:choose>
			</xsl:when>
			
			<!-- otherwise, implement an href and put href in footnote
				for printed version -->
			<xsl:otherwise>
				<xsl:text>\href{</xsl:text>
				<xsl:value-of select="@href"/>
				<xsl:text>}{</xsl:text>
				<xsl:call-template name="clean-text">
					<xsl:with-param name="source">
						<xsl:value-of select="."/>
					</xsl:with-param>
				</xsl:call-template>		
				<xsl:text>}\footnote{\href{</xsl:text>
				<xsl:value-of select="@href"/>
				<xsl:text>}{</xsl:text>
				<xsl:call-template name="clean-text">
					<xsl:with-param name="source">
						<xsl:value-of select="@href"/>
					</xsl:with-param>
				</xsl:call-template>		
				<xsl:text>}}</xsl:text>
			</xsl:otherwise>
		</xsl:choose>
	</xsl:template>

	<!-- ordered list -->
	<xsl:template match="html:ol">
		<xsl:text>\begin{enumerate}</xsl:text>
		<xsl:value-of select="$newline"/>
		<xsl:value-of select="$newline"/>
		<xsl:apply-templates select="*"/>
		<xsl:text>\end{enumerate}</xsl:text>
		<xsl:value-of select="$newline"/>
		<xsl:value-of select="$newline"/>
	</xsl:template>

	<!-- unordered list -->
	<xsl:template match="html:ul">
		<xsl:text>\begin{itemize}</xsl:text>
		<xsl:value-of select="$newline"/>
		<xsl:value-of select="$newline"/>
		<xsl:apply-templates select="*"/>
		<xsl:text>\end{itemize}</xsl:text>
		<xsl:value-of select="$newline"/>
		<xsl:value-of select="$newline"/>
	</xsl:template>
	
	<!-- list item -->
	<xsl:template match="html:li">
		<xsl:text>
\item </xsl:text>
		<xsl:apply-templates select="node()"/>
		<xsl:value-of select="$newline"/>
	</xsl:template>
		
	<!-- definition list - fake it for compatibility with XHTML version -->
    <xsl:template match="html:dl">\begin{description}
        <xsl:apply-templates select="node()"/>
        <xsl:text>\end{description}
            </xsl:text>
    </xsl:template>

    <xsl:template match="html:dt">
        <xsl:text>\item[</xsl:text>
        <xsl:apply-templates select="node()"/>
        <xsl:text>]</xsl:text>
    </xsl:template>

    <xsl:template match="html:dd">
        <xsl:text> </xsl:text>
        <xsl:apply-templates select="node()"/>
        <xsl:text></xsl:text>
    </xsl:template>

	<!-- code span -->
	<xsl:template match="html:code">
		<xsl:text>\texttt{</xsl:text>
		<xsl:apply-templates select="node()"/>
		<xsl:text>}</xsl:text>
	</xsl:template>

	<!-- line ending -->
	<xsl:template match="html:br">
		<xsl:text>\\</xsl:text>
	</xsl:template>

	<!-- blockquote -->
	<xsl:template match="html:blockquote">
		<xsl:text>\begin{quotation}
</xsl:text>
		<xsl:apply-templates select="node()"/>
		<xsl:text>\end{quotation}

</xsl:text>
	</xsl:template>

	<!-- emphasis -->
	<xsl:template match="html:em">
		<xsl:text>{\itshape </xsl:text>
			<xsl:apply-templates select="node()"/>
		<xsl:text>}</xsl:text>
	</xsl:template>

	<!-- strong -->
	<xsl:template match="html:strong">
		<xsl:text>\textbf{</xsl:text>
			<xsl:apply-templates select="node()"/>
		<xsl:text>}</xsl:text>
	</xsl:template>
	
	<!-- horizontal rule -->
	<xsl:template match="html:hr">
		<xsl:text>\vskip 2em
\hrule height 0.4pt
\vskip 2em

</xsl:text>
	</xsl:template>

	<!-- images -->
	<xsl:template match="html:img">
		<xsl:text>\begin{figure}
</xsl:text>
		<xsl:text>\begin{center}
</xsl:text>
		<xsl:if test="@width|@height">
			<!-- there are dimensions, so use them -->
			<!-- Basically, we allow any units covered by LaTeX, even
				if they are not allowed in XHTML.  px is converted to pt.
				If no units, then assume pt.
			-->
			<xsl:text>\resizebox{</xsl:text>
			<xsl:choose>
				<xsl:when test="@width">
					<xsl:call-template name="replace-substring">
						<xsl:with-param name="original">
							<xsl:value-of select="@width"/>
						</xsl:with-param>
						<xsl:with-param name="substring">
							<xsl:text>px</xsl:text>
						</xsl:with-param>
						<xsl:with-param name="replacement">
							<xsl:text>pt</xsl:text>
						</xsl:with-param>
					</xsl:call-template>
					<xsl:if test="translate(@width, 
	'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ01234567890.'
	,'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ') = '' ">
						<!-- no units specified -->
						<xsl:text>pt</xsl:text>
					</xsl:if>
				</xsl:when> 
				<xsl:otherwise>
					<xsl:text>!</xsl:text>
				</xsl:otherwise>
			</xsl:choose>
			<xsl:text>}{</xsl:text>
			<xsl:choose>
				<xsl:when test="@height">
					<xsl:call-template name="replace-substring">
						<xsl:with-param name="original">
							<xsl:value-of select="@height"/>
						</xsl:with-param>
						<xsl:with-param name="substring">
							<xsl:text>px</xsl:text>
						</xsl:with-param>
						<xsl:with-param name="replacement">
							<xsl:text>pt</xsl:text>
						</xsl:with-param>
					</xsl:call-template>
					<xsl:if test="translate(@height, 
	'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ01234567890.'
	,'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ') = '' ">
						<!-- no units specified -->
						<xsl:text>pt</xsl:text>
					</xsl:if>
				</xsl:when> 
				<xsl:otherwise>
					<xsl:text>!</xsl:text>
				</xsl:otherwise>
			</xsl:choose>
			<xsl:text>}{</xsl:text>
		</xsl:if>
		<xsl:if test="not(@width|@height)">
			<!-- if no dimensions, then ensure it fits on page
				(of course, this also goes to "max zoom"...)
			 -->
			 <xsl:text>\resizebox{1\linewidth}{!}{</xsl:text>
		</xsl:if>
		<xsl:text>\includegraphics{</xsl:text>
		<xsl:value-of select="@src"/>
		<xsl:text>}}
\end{center}
</xsl:text>
		<xsl:if test="@title">
			<xsl:if test="not(@title = '')">
				<xsl:text>\caption{</xsl:text>
				<xsl:apply-templates select="@title"/>
				<xsl:text>}
	</xsl:text>
			</xsl:if>
		</xsl:if>
		<xsl:if test="@id">
			<xsl:text>\label{</xsl:text>
			<xsl:value-of select="@id"/>
			<xsl:text>}
</xsl:text>
		</xsl:if>
	<xsl:text>\end{figure}
</xsl:text>
	</xsl:template>
	
	<!-- footnotes -->
	<xsl:template match="html:div">
		<xsl:if test="not(@class = 'footnotes')">
			<xsl:apply-templates select="node()"/>
		</xsl:if>
	</xsl:template>

	<!-- pull-quotes (a table with no header, and a single column) -->
	<!-- this is experimental, and I am open to suggestions -->
	<xsl:template match="html:table[@class='pull-quote']">
		<xsl:text>\begin{table}[htbp]
\begin{minipage}{\linewidth}
\centering
</xsl:text>
		<xsl:apply-templates select="html:caption"/>
		<xsl:text>\begin{tabular}{@{}p{0.5\linewidth}@{}} \\ \toprule </xsl:text>
		<xsl:apply-templates select="html:thead"/>
		<xsl:apply-templates select="html:tbody"/>
		<xsl:apply-templates select="html:tr"/>
		<xsl:text>\end{tabular}
\end{minipage}
\end{table}

</xsl:text>
	</xsl:template>

	<!-- tables -->
	<xsl:template match="html:table">
		<xsl:text>\begin{table}[htbp]
\begin{minipage}{\linewidth}
\setlength{\tymax}{0.5\linewidth}
\centering
\small
</xsl:text>
		<xsl:apply-templates select="html:caption"/>
		<xsl:text>\begin{tabulary}{\linewidth}{@{}</xsl:text>
		<xsl:apply-templates select="html:col"/>
		<xsl:text>@{}} \\ \toprule </xsl:text>
		<xsl:apply-templates select="html:thead"/>
		<xsl:apply-templates select="html:tbody"/>
		<xsl:apply-templates select="html:tr"/>
		<xsl:text>\end{tabulary}
\end{minipage}
\end{table}

</xsl:text>
	</xsl:template>
	
	<xsl:template match="html:tbody">
		<xsl:apply-templates select="html:tr"/>
		\bottomrule
	</xsl:template>

	<xsl:template match="html:col">
		<xsl:choose>
			<xsl:when test="@align='center'">
				<xsl:choose>
					<xsl:when test="@class='extended'">
						<xsl:text>C</xsl:text>
					</xsl:when>
					<xsl:otherwise>
						<xsl:text>c</xsl:text>
					</xsl:otherwise>
				</xsl:choose>
			</xsl:when>
			<xsl:when test="@align='right'">
				<xsl:choose>
					<xsl:when test="@class='extended'">
						<xsl:text>R</xsl:text>
					</xsl:when>
					<xsl:otherwise>
						<xsl:text>r</xsl:text>
					</xsl:otherwise>
				</xsl:choose>
			</xsl:when>
			<xsl:otherwise>
				<xsl:choose>
					<xsl:when test="@class='extended'">
						<xsl:text>J</xsl:text>
					</xsl:when>
					<xsl:otherwise>
						<xsl:text>l</xsl:text>
					</xsl:otherwise>
				</xsl:choose>
			</xsl:otherwise>
		</xsl:choose>
	</xsl:template>

	<xsl:template match="html:thead">
		<xsl:apply-templates select="html:tr" mode="header"/>
		<xsl:text>\midrule
</xsl:text>
	</xsl:template>
	
	<xsl:template match="html:caption">
		<xsl:text>\caption{</xsl:text>
			<xsl:apply-templates select="node()"/>
		<xsl:text>}
</xsl:text>
		<xsl:if test="@id">
			<xsl:text>\label{</xsl:text>
			<xsl:value-of select="@id"/>
			<xsl:text>}
</xsl:text>
		</xsl:if>
	</xsl:template>
	
	<xsl:template match="html:tr" mode="header">
		<xsl:text>
</xsl:text>
		<xsl:apply-templates select="html:td|html:th"/>
		<xsl:text> \\ </xsl:text>
		<!-- figure out a way to count columns for \cmidrule{x-y} -->
		<xsl:apply-templates select="html:td[1]|html:th[1]" mode="cmidrule">
			<xsl:with-param name="col" select="1"/>
		</xsl:apply-templates>
	</xsl:template>

	<xsl:template match="html:td|html:th" mode="cmidrule">
		<xsl:param name="col"/>
		<xsl:param name="end" select="$col+format-number(@colspan,'#','string')-1"/>
		<xsl:if test="not(. = '')">
			<xsl:text> \cmidrule{</xsl:text>
			<xsl:value-of select="$col"/>
			<xsl:text>-</xsl:text>
			<xsl:value-of select="$end"/>
			<xsl:text>}</xsl:text>
		</xsl:if>
		<xsl:apply-templates select="following-sibling::*[1]" mode="cmidrule">
			<xsl:with-param name="col" select="$end+1"/>
		</xsl:apply-templates>
	</xsl:template>
	
	<xsl:template match="html:tr[last()]" mode="header">
		<xsl:text>
</xsl:text>
		<xsl:apply-templates select="html:td|html:th"/>
		<xsl:text> \\</xsl:text>
	</xsl:template>

	<xsl:template match="html:tr">
		<xsl:apply-templates select="html:td|html:th"/>
		<xsl:text> \\
</xsl:text>
	</xsl:template>

	<xsl:template match="html:th|html:td">
		<xsl:if test="@colspan">
			<xsl:text>\multicolumn{</xsl:text>
			<xsl:value-of select="@colspan"/>
		</xsl:if>
		<xsl:if test="@colspan">
			<xsl:text>}{c}{</xsl:text>
		</xsl:if>
		<xsl:apply-templates select="node()"/>
		<xsl:if test="@colspan">
			<xsl:text>}</xsl:text>
		</xsl:if>
		<xsl:if test="position()!=last()">
    		<xsl:text>&amp;</xsl:text>
		</xsl:if>
	</xsl:template>
	
	<!-- Support for Bibliography to BibTeX conversion -->
	
	<xsl:template match="html:span[@class='externalcitation']">
		<xsl:text>\cite</xsl:text>
		<xsl:apply-templates select="html:span" mode="citation"/>
		<xsl:apply-templates select="html:a" mode="citation"/>
		<xsl:text>}</xsl:text>
	</xsl:template>

	<xsl:template match="html:span[@class='markdowncitation']">
		<xsl:text>~\cite</xsl:text>
		<xsl:apply-templates select="html:span" mode="citation"/>
		<xsl:apply-templates select="html:a" mode="markdowncitation"/>
		<xsl:text>}</xsl:text>
	</xsl:template>
	
	<xsl:template match="html:span[@class='notcited']">
		<xsl:text>~\nocite{</xsl:text>
		<xsl:value-of select="@id"/>
		<xsl:text>}</xsl:text>
	</xsl:template>

	<xsl:template match="html:a[@id]" mode="citation">
		<xsl:text>{</xsl:text>
		<xsl:value-of select="@id"/>
	</xsl:template>

	<xsl:template match="html:a[@href]" mode="markdowncitation">
		<xsl:text>{</xsl:text>
		<xsl:value-of select="substring-after(@href,'#')"/>
	</xsl:template>

	<xsl:template match="html:span[@class='locator']" mode="citation">
		<xsl:text>[</xsl:text>
		<xsl:value-of select="."/>
		<xsl:text>]</xsl:text>
	</xsl:template>

	<!-- Disabled unless natbib is implemented -->
	<xsl:template match="html:span[@class='textual citation']" mode="citation">
		<xsl:text></xsl:text>
	</xsl:template>
	
	<xsl:template match="html:div[@class='bibliography']">
		<xsl:text>\begin{thebibliography}{</xsl:text>
		<xsl:value-of select="count(div[@id])"/>
		<xsl:text>}
</xsl:text>
		<xsl:apply-templates select="html:div"/>
		<xsl:text>
		
\end{thebibliography}
		
</xsl:text>
	</xsl:template>
				
	<xsl:template match="html:div[@class='bibliography']/html:div[@id]">
		<xsl:text>

\bibitem{</xsl:text>
		<xsl:value-of select="@id"/>
		<xsl:text>}
</xsl:text>
		<xsl:apply-templates select="html:p/html:span[@class='item']" mode="citation"/>
	</xsl:template>	

	<xsl:template match="html:span[@class='item']" mode="citation">
		<xsl:apply-templates select="."/>
	</xsl:template>
	
		
	<!-- Default LaTeX code to add -->
	
	<xsl:template name="latex-header">
		<xsl:text>\usepackage{fancyvrb}			% Allow \verbatim et al. in footnotes
\usepackage{graphicx}			% To include graphics in pdf's (jpg, gif, png, etc)
\usepackage{booktabs}			% Better tables
\usepackage{tabulary}			% Support longer table cells
\usepackage[utf8]{inputenc}		% For UTF-8 support
\usepackage[T1]{fontenc}		% Use T1 font encoding for accented characters
\usepackage{xcolor}				% Allow for color (annotations)

%\geometry{landscape}			% Activate for rotated page geometry

%\usepackage[parfill]{parskip}	% Activate to begin paragraphs with an empty
								% line rather than an indent


\def\myauthor{Author}			% In case these were not included in metadata
\def\mytitle{Title}
\def\mykeywords{}
\def\mybibliostyle{plain}
\def\bibliocommand{}

\VerbatimFootnotes
</xsl:text>
	</xsl:template>
	
	<xsl:template name="latex-intro">
				<xsl:text>

%
%	PDF Stuff
%

%\ifpdf							% Removed for XeLaTeX compatibility
%  \pdfoutput=1					% Removed for XeLaTeX compatibility
  \usepackage[
  	plainpages=false,
  	pdfpagelabels,
  	pdftitle={\mytitle},
  	pagebackref,
  	pdfauthor={\myauthor},
  	pdfkeywords={\mykeywords}
  	]{hyperref}
  \usepackage{memhfixc}
%\fi							% Removed for XeLaTeX compatibility


%
% Title Information
%


\ifx\latexauthor\undefined
\else
	\def\myauthor{\latexauthor}
\fi

\ifx\subtitle\undefined
\else
	\addtodef{\mytitle}{}{ \\ \subtitle}
\fi

\ifx\affiliation\undefined
\else
	\addtodef{\myauthor}{}{ \\ \affiliation}
\fi

\ifx\address\undefined
\else
	\addtodef{\myauthor}{}{ \\ \address}
\fi

\ifx\phone\undefined
\else
	\addtodef{\myauthor}{}{ \\ \phone}
\fi

\ifx\email\undefined
\else
	\addtodef{\myauthor}{}{ \\ \email}
\fi

\ifx\web\undefined
	\else
		\addtodef{\myauthor}{}{ \\ \web}
\fi

\title{\mytitle}
\author{\myauthor}

\begin{document}
</xsl:text>
	</xsl:template>

	<xsl:template name="latex-paper-size">
	</xsl:template>

	<xsl:template name="latex-footer">
		<xsl:text>% Bibliography
\bibliographystyle{\mybibliostyle}
\bibliocommand

\end{document}
</xsl:text>
	</xsl:template>


	<!-- Allow for spans to set a color 
		Specifically, this is useful with Scrivener -->
	<xsl:template match="html:span[starts-with(@style,'color:')]">
		<xsl:text>{\color[HTML]{</xsl:text>
		<xsl:call-template name="replace-substring">
			<xsl:with-param name="original">
				<xsl:value-of select="@style"/>
			</xsl:with-param>
			<xsl:with-param name="substring">
				<xsl:text>color:#</xsl:text>
			</xsl:with-param>
			<xsl:with-param name="replacement">
				<xsl:text></xsl:text>
			</xsl:with-param>
		</xsl:call-template>
		<xsl:text>} </xsl:text>
		<xsl:apply-templates select="node()"/>
		<xsl:text>}</xsl:text>
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
