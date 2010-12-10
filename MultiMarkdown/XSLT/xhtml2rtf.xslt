<?xml version='1.0' encoding='utf-8'?>

<!-- XHTML-to-RTF converter by Fletcher Penney
	specifically designed for use with MultiMarkdown created XHTML
	
	MultiMarkdown Version 2.0.b6
	
	
	Yes - this is the project I swore I would never do.... 
	You're welcome.  ;)
	
	
	Known Limitations (and opportunities for you to help!):
	
	FIRST AND FOREMOST - RTF is a crappy document format.  It sucks - no two 
	ways about it. This converter is designed to get passable results on basic 
	MMD documents for most situations.  If you have a (mildly!) complicated 
	document, it's probably going to suck.  Go with LaTeX instead.  But if you 
	must use RTF, it might work for you.  
	
	If you absolutely have to use RTF, you should try using Google Docs to 
	upload the HTML version of your document, and then download it as an RTF 
	(or ODT).  Google's RTF converter isn't too bad if you have to use RTF. If 
	you export as XHTML using the xhtml-google-docs XSLT, you can even use 
	footnotes, though I don't think they survive the trip into RTF as 
	footnotes.
	
	If you are going to use this, the following limitations apply:
	
	MathML - there is no suitable MathML -> RTF tool that I'm aware of that
		would really fit into MMD.  Besides - if you are using MathML, you
		REALLY need to be using LaTeX->PDF rather than RTF.
	
	Lists - I welcome submissions on a good approach to converting HTML lists
		into RTF, but for now lists don't really work right - the syntax is 
		needless complex, and I don't relish sorting through it all
	
	Images - I'm not sure what to do here - probably more effort than it's 
		worth
	
	Tables - similar to lists above - just not worth the effort
	
	
	That said, what are the benefits of this version?
	
	* Footnotes work
	* Internal links work for headers
	* It's easy
	* Basic formatting looks pretty good
	* Styles are intact (e.g. default, header1, header2)
	
	NOTE: I strongly recommend avoiding TextEdit like the plague.
	
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
	xmlns:m="http://www.w3.org/1998/Math/MathML"
	xmlns:html="http://www.w3.org/1999/xhtml"
	version="1.0">

	<xsl:import href="clean-text-rtf.xslt"/>

	<xsl:output method='text' encoding='utf-8'/>

	<xsl:strip-space elements="*" />

	<xsl:variable name="plainnewline">
<xsl:text>
</xsl:text>
	</xsl:variable>

	<xsl:variable name="newline">
<xsl:text>\
</xsl:text>
	</xsl:variable>

	<xsl:param name="footnoteId"/>

	<xsl:param name="leftIndent" select="750" NaN="0"/>
	<xsl:param name="rightIndent"/>

	<xsl:decimal-format name="string" NaN="1"/>

	<xsl:template match="html:body">
		<xsl:apply-templates select="*|comment()"/>
		<!-- <xsl:apply-templates select="*"/> 		Use this version to ignore text within XHTML comments-->
		<xsl:call-template name="rtf-closing"/>
	</xsl:template>

	<xsl:template match="html:head">
		<!-- Init Latex -->
		<xsl:call-template name="rtf-intro"/>
		<xsl:apply-templates select="*"/>
		<xsl:call-template name="rtf-intro-closing"/>
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

	<xsl:template name="rtf-intro">
		<xsl:text>{\rtf1\ansi\ansicpg1252\cocoartf949\cocoasubrtf460
{\fonttbl{\f0\froman Times;}
{\f1\fmodern Courier;}}
{\stylesheet{\s0\f0\fs24\qj\sb280\sa280 Normal;}
{\s1\fs48\f0\sb280\sa280 Header1;}
{\s2\fs40\f0\sb280\sa280 Header2;}
{\s3\fs32\f0\sb280\sa280 Header3;}
{\s4\fs24\f0\sb280\sa280 Header4;}
{\s5\fs24\f0\sb280\sa280 Header5;}
{\s6\fs24\f0\sb280\sa280 Header6;}
{\s7\f1\fs20 Mono;}
}
{\colortbl;\red255\green255\blue255;}
{\info
</xsl:text>
	</xsl:template>

	<xsl:template name="rtf-intro-closing">
		<xsl:text>}\margl1440\margr1440
\f0\pard\sa280
</xsl:text>
	</xsl:template>
	
	<xsl:template name="rtf-closing">
		<xsl:text>}</xsl:text>
	</xsl:template>

	<xsl:template match="*[local-name() = 'title']">
		<xsl:text>{\title </xsl:text>
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
				<xsl:text>{\author </xsl:text>
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
				<xsl:text>{\*\company </xsl:text>
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
						<xsl:text> </xsl:text>
					</xsl:with-param>
				</xsl:call-template>
				<xsl:text>}
</xsl:text>
			</xsl:when>
			<xsl:when test="translate(@name,'ABCDEFGHIJKLMNOPQRSTUVWXYZ',
			'abcdefghijklmnopqrstuvwxyz') = 'keywords'">
				<xsl:text>{\keywords </xsl:text>
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
			'abcdefghijklmnopqrstuvwxyz') = 'copyright'">
				<xsl:text>{\*\copyright </xsl:text>
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
						<xsl:text> </xsl:text>
					</xsl:with-param>
				</xsl:call-template>
				<xsl:text>}
</xsl:text>
			</xsl:when>
		</xsl:choose>
	</xsl:template>

	<!-- paragraphs -->
	
	<xsl:template match="html:p">
		<xsl:text>\s0\qj </xsl:text>
		<xsl:apply-templates select="node()"/>
		<xsl:text>\
</xsl:text>
	</xsl:template>

	<!-- emphasis -->
	<xsl:template match="html:em">
		<xsl:text>
\i </xsl:text>
			<xsl:apply-templates select="node()"/>
		<xsl:text>
\i0 </xsl:text>
	</xsl:template>

	<!-- strong -->
	<xsl:template match="html:strong">
		<xsl:text>
\b </xsl:text>
			<xsl:apply-templates select="node()"/>
		<xsl:text>
\b0 </xsl:text>
	</xsl:template>

	<!-- headers -->
	
	<xsl:template match="html:h1">
\s1 {\*\bkmkstart <xsl:value-of select="@id"/>}<xsl:apply-templates select="node()"/>{\*\bkmkend <xsl:value-of select="@id"/>}
<xsl:value-of select="$newline"/>
</xsl:template>

	<xsl:template match="html:h2">
\s2 {\*\bkmkstart <xsl:value-of select="@id"/>}<xsl:apply-templates select="node()"/>{\*\bkmkend <xsl:value-of select="@id"/>}
<xsl:value-of select="$newline"/>
</xsl:template>

	<xsl:template match="html:h3">
\s3 <xsl:apply-templates select="node()"/>
<xsl:value-of select="$newline"/>
</xsl:template>

	<xsl:template match="html:h4">
\s4 <xsl:apply-templates select="node()"/>
<xsl:value-of select="$newline"/>
</xsl:template>

	<xsl:template match="html:h5">
\s5 <xsl:apply-templates select="node()"/>
<xsl:value-of select="$newline"/>
</xsl:template>

	<xsl:template match="html:h6">
\s6 <xsl:apply-templates select="node()"/>
<xsl:value-of select="$newline"/>
</xsl:template>
	
	<xsl:template match="html:br">
		<xsl:text>\line</xsl:text>
	</xsl:template>

	<!-- blockquote -->
	<xsl:template match="html:blockquote">
		<xsl:param name="leftIndent"/>
		<xsl:choose>
			<xsl:when test="string(number($leftIndent)) = 'NaN'">
				<xsl:param name="newLeft" select="1"/>
\lin<xsl:value-of select="$newLeft*750"/>\rin750
<xsl:apply-templates select="node()">
					<xsl:with-param name="leftIndent" select="$newLeft"/>
				</xsl:apply-templates>
					<xsl:text>\lin0\rin0
</xsl:text>
			</xsl:when>
			<xsl:otherwise>
				<xsl:param name="newLeft" select="$leftIndent+1" />
\lin<xsl:value-of select="$newLeft*750"/>\rin750
<xsl:apply-templates select="node()">
					<xsl:with-param name="leftIndent" select="$newLeft"/>
				</xsl:apply-templates>
			<xsl:text>\lin0\rin0
</xsl:text>
			</xsl:otherwise>
		</xsl:choose>
	</xsl:template>

	<!-- anchors -->
	<xsl:template match="html:a[@href]">
		<xsl:choose>
			<!-- footnote (my addition)-->
			<xsl:when test="@class = 'footnote'">
				<xsl:text>{\super \chftn{\*\footnote{ </xsl:text>
				<xsl:apply-templates select="/html:html/html:body/html:div[@class]/html:ol/html:li[@id]" mode="footnote">
					<xsl:with-param name="footnoteId" select="@href"/>
				</xsl:apply-templates>
				<xsl:text>}}}</xsl:text>
			</xsl:when>

			<xsl:when test="@class = 'footnote glossary'">
					<xsl:text>{\super \chftn{\*\footnote{ </xsl:text>
					<xsl:apply-templates select="/html:html/html:body/html:div[@class]/html:ol/html:li[@id]" mode="glossary">
						<xsl:with-param name="footnoteId" select="@href"/>
					</xsl:apply-templates>
					<xsl:text>}}}</xsl:text>
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
				<xsl:text>{\field{\*\fldinst{HYPERLINK "</xsl:text>
				<xsl:value-of select="@href"/>
				<xsl:text>"}}{\fldrslt \b \cf0 </xsl:text>
				<xsl:call-template name="clean-text">
					<xsl:with-param name="source">
						<xsl:value-of select="."/>
					</xsl:with-param>
				</xsl:call-template>		
				<xsl:text>}}</xsl:text>
			</xsl:when>
			
			<!-- if href is local anchor, use autoref -->
			<xsl:when test="starts-with(@href,'#')">
				<xsl:text>{\field{\*\fldinst REF </xsl:text>
				<xsl:value-of select="substring-after(@href,'#')"/>
				<xsl:text>}{\fldrslt \b \cf0 </xsl:text>
				<xsl:call-template name="clean-text">
					<xsl:with-param name="source">
						<xsl:value-of select="."/>
					</xsl:with-param>
				</xsl:call-template>		
				<xsl:text>}}</xsl:text>
			</xsl:when>
			
			<!-- otherwise, implement an href and put href in footnote
				for printed version -->
			<xsl:otherwise>
				<xsl:text>{\field{\*\fldinst{HYPERLINK "</xsl:text>
				<xsl:value-of select="@href"/>
				<xsl:text>"}}{\fldrslt \b \cf0 </xsl:text>
				<xsl:call-template name="clean-text">
					<xsl:with-param name="source">
						<xsl:value-of select="."/>
					</xsl:with-param>
				</xsl:call-template>		
				<xsl:text>}}{\super \chftn{\*\footnote{ </xsl:text>
				<xsl:call-template name="clean-text">
					<xsl:with-param name="source">
						<xsl:value-of select="@href"/>
					</xsl:with-param>
				</xsl:call-template>		
				<xsl:text>}}}</xsl:text>
			</xsl:otherwise>
		</xsl:choose>
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

	<!-- footnotes -->
	<xsl:template match="html:div">
		<xsl:if test="not(@class = 'footnotes')">
			<xsl:if test="not(@class = 'bibliography')">
				<xsl:apply-templates select="node()"/>
			</xsl:if>
		</xsl:if>
	</xsl:template>

	<!-- print contents of the matching footnote as a glossary entry-->
	<xsl:template match="html:li" mode="glossary">
		<xsl:param name="footnoteId"/>
		<xsl:if test="parent::html:ol/parent::html:div/@class = 'footnotes'">
			<xsl:if test="concat('#',@id) = $footnoteId">
				<xsl:apply-templates select="html:span" mode="glossary"/>
				<xsl:apply-templates select="html:p" mode="glossary"/>
			</xsl:if>
		</xsl:if>
	</xsl:template>

	<xsl:template match="html:p" mode="glossary">
		<xsl:apply-templates select="node()"/>
		<xsl:if test="position()!= last()">
			<xsl:text>\
</xsl:text>
		</xsl:if>
	</xsl:template>

	<!-- use these when asked for -->
	<xsl:template match="html:span[@class='glossary name']" mode="glossary">
		<xsl:apply-templates select="node()"/>
		<xsl:text>: </xsl:text>
	</xsl:template>
	
	<xsl:template match="html:span[@class='glossary sort']" mode="glossary">
	</xsl:template>

	<!-- Place citations in as footnotes -->

	<xsl:template match="html:span[@class='markdowncitation']">
		<xsl:text>{\super \chftn{\*\footnote{ </xsl:text>
		<xsl:apply-templates select="/html:html/html:body/html:div[@class]/html:div[@id]" mode="markdowncitation">
			<xsl:with-param name="citationID" select="child::html:a/@href"/>
		</xsl:apply-templates>
		<xsl:text>}}}</xsl:text>
	</xsl:template>

	<!-- citation div -->
	<!-- print contents of the matching citation -->
	<xsl:template match="html:div" mode="markdowncitation">
		<xsl:param name="citationID"/>
		<xsl:if test="parent::html:div/@class = 'bibliography'">
			<xsl:if test="concat('#',@id) = $citationID">
				<xsl:apply-templates select="html:p/html:span"/>
			</xsl:if>
		</xsl:if>
	</xsl:template>

	<!-- code span -->
	<xsl:template match="html:code">
		<xsl:text>\f1\fs20 </xsl:text>
		<xsl:apply-templates select="node()"/>
		<xsl:text>\f0\fs24 </xsl:text>
	</xsl:template>

	<xsl:template match="html:pre">
		<xsl:apply-templates select="node()" mode="code"/>
		<xsl:value-of select="$newline"/>
	</xsl:template>

	<xsl:template match="html:code" mode="code">
		<xsl:text>\f1\fs20 </xsl:text>
		<xsl:apply-templates select="node()" mode="code"/>
		<xsl:text>\f0\fs24 </xsl:text>
	</xsl:template>

	<xsl:template match="text()" mode="code">
		<xsl:call-template name="replace-substring">
			<xsl:with-param name="original">
				<xsl:call-template name="clean-text">
					<xsl:with-param name="source">
						<xsl:value-of select="."/>
					</xsl:with-param>
				</xsl:call-template>
			</xsl:with-param>
			<xsl:with-param name="substring">
				<xsl:value-of select="$plainnewline"/>
			</xsl:with-param>
			<xsl:with-param name="replacement">
				<xsl:value-of select="$newline"/>
			</xsl:with-param>
		</xsl:call-template>
	</xsl:template>


	<xsl:template match="text()">
		<xsl:call-template name="clean-text">
			<xsl:with-param name="source">
				<xsl:value-of select="."/>
			</xsl:with-param>
		</xsl:call-template>
	</xsl:template>
	
</xsl:stylesheet>
