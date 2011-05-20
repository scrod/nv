<?xml version="1.0" encoding="ISO-8859-1"?>
<!--	XHTML to MultiMarkdown converter by Fletcher Penney
	
	modified from:
	
	 XHTML-to-Markdown converter by Andrew Green, Article Seven, 	
		http://www.article7.co.uk/

	TODO: support for citations
	TODO: support for footnotes
	TODO: support for tables
	TODO: support for definition lists
	TODO: support for glossary entries
	TODO: support for link/image attributes (and use a reference style link?)
	TODO: support for MathML->ASCIIMathML???

-->

<!-- This work is licensed under the Creative Commons Attribution-ShareAlike License. To view a copy of this license, visit http://creativecommons.org/licenses/by-sa/2.0/ or send a letter to Creative Commons, 559 Nathan Abbott Way, Stanford, California 94305, USA. -->
<xsl:stylesheet version="1.0" xmlns:h="http://www.w3.org/1999/xhtml" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">

   <xsl:output method="text" encoding="utf-8"/>
   
   <xsl:strip-space elements="*"/>
   
   <xsl:variable name="newline">
<xsl:text>
</xsl:text>
   </xsl:variable>
   
   <xsl:variable name="tab">
      <xsl:text>	</xsl:text>
   </xsl:variable>
   
   <xsl:template match="/">
	<xsl:apply-templates select="h:html/h:head"/>
      <xsl:apply-templates select="h:html/h:body/node()">
         <xsl:with-param name="context" select="markdown"/>
      </xsl:apply-templates>
   </xsl:template>

   <xsl:template match="@*">
      <xsl:text> </xsl:text>
      <xsl:value-of select="local-name()"/>
      <xsl:text>="</xsl:text>
      <xsl:value-of select="."/>
      <xsl:text>"</xsl:text>
   </xsl:template>
   
   <xsl:template match="text()">
      <!-- it might be possible to use replace-substring to backslash special characters, but that's not implemented yet -->
      <xsl:if test="normalize-space(.)">
         <xsl:value-of select="."/>
      </xsl:if>  
   </xsl:template>
   
   <xsl:template match="text()[parent::h:code[parent::h:pre]]">
      <xsl:call-template name="replace-substring">
         <xsl:with-param name="original">
            <xsl:value-of select="."/>
         </xsl:with-param>
         <xsl:with-param name="substring">
            <xsl:value-of select="$newline"/>
         </xsl:with-param>
         <xsl:with-param name="replacement">
            <xsl:value-of select="$newline"/>
            <xsl:value-of select="$tab"/>
         </xsl:with-param>
      </xsl:call-template>
   </xsl:template>
   
   <xsl:template name="newblock">
      <xsl:param name="context"/>
      <xsl:if test="not(not(preceding-sibling::*) and (parent::h:body or parent::h:li))">
         <xsl:value-of select="$newline"/>
         <xsl:if test="not(self::h:li) or (self::h:li and h:p)">
             <xsl:value-of select="$newline"/>
         </xsl:if>
         <xsl:if test="parent::h:blockquote[parent::h:li and preceding-sibling::*] or (parent::h:li and preceding-sibling::*)">
            <xsl:text>    </xsl:text>
         </xsl:if>
         <xsl:if test="not($context = 'html') and parent::h:blockquote">
            <xsl:text>&gt; </xsl:text>
         </xsl:if>
      </xsl:if>
   </xsl:template>
   
   <!-- if an element isn't templated elsewhere, we move into html context and stay there for any descendent nodes -->
   <xsl:template match="h:*">
      <xsl:if test="self::h:h1 or self::h:h2 or self::h:h3 or self::h:h4 or self::h:h5 or self::h:h6 or self::h:p or self::h:pre or self::h:table or self::h:form or self::h:ul or self::h:ol or self::h:address or self::h:blockquote or self::h:dl or self::h:fieldset or self::h:hr or self::h:noscript">
         <xsl:call-template name="newblock">
            <xsl:with-param name="context" select="'html'"/>
         </xsl:call-template>
      </xsl:if>
      <xsl:call-template name="element"/>
   </xsl:template>
   
   <xsl:template name="element">
      <xsl:text>&lt;</xsl:text>
      <xsl:value-of select="local-name()"/>
      <xsl:apply-templates select="@*"/>
      <xsl:text>&gt;</xsl:text>
      <xsl:apply-templates select="node()">
         <xsl:with-param name="context" select="'html'"/>
      </xsl:apply-templates>
      <xsl:text>&lt;/</xsl:text>
      <xsl:value-of select="local-name()"/>
      <xsl:text>&gt;</xsl:text>
   </xsl:template>
   
   <xsl:template match="h:div">
      <xsl:apply-templates select="node()"/>
   </xsl:template>
   
   <xsl:template match="h:p">
      <xsl:param name="context"/>
      <xsl:choose>
         <xsl:when test="$context = 'html'">
            <xsl:call-template name="element"/>
         </xsl:when>
         <xsl:otherwise>
            <xsl:call-template name="newblock"/>
            <xsl:apply-templates select="node()"/>
         </xsl:otherwise>
      </xsl:choose>
   </xsl:template>
   
   <xsl:template match="h:h1">
      <xsl:param name="context"/>
      <xsl:choose>
         <xsl:when test="$context = 'html'">
            <xsl:call-template name="element"/>
         </xsl:when>
         <xsl:otherwise>
            <xsl:call-template name="newblock"/>
            <xsl:text># </xsl:text>
            <xsl:apply-templates select="node()"/>
            <xsl:text> #</xsl:text>
         </xsl:otherwise>
      </xsl:choose>
   </xsl:template>
   
   <xsl:template match="h:h2">
      <xsl:param name="context"/>
      <xsl:choose>
         <xsl:when test="$context = 'html'">
            <xsl:call-template name="element"/>
         </xsl:when>
         <xsl:otherwise>
            <xsl:call-template name="newblock"/>
            <xsl:text>## </xsl:text>
            <xsl:apply-templates select="node()"/>
            <xsl:text> ##</xsl:text>
         </xsl:otherwise>
      </xsl:choose>
   </xsl:template>
   
   <xsl:template match="h:h3">
      <xsl:param name="context"/>
      <xsl:choose>
         <xsl:when test="$context = 'html'">
            <xsl:call-template name="element"/>
         </xsl:when>
         <xsl:otherwise>
            <xsl:call-template name="newblock"/>
            <xsl:text>### </xsl:text>
            <xsl:apply-templates select="node()"/>
            <xsl:text> ###</xsl:text>
         </xsl:otherwise>
      </xsl:choose>
   </xsl:template>
   
   <xsl:template match="h:h4">
      <xsl:param name="context"/>
      <xsl:choose>
         <xsl:when test="$context = 'html'">
            <xsl:call-template name="element"/>
         </xsl:when>
         <xsl:otherwise>
            <xsl:call-template name="newblock"/>
            <xsl:text>#### </xsl:text>
            <xsl:apply-templates select="node()"/>
            <xsl:text> ####</xsl:text>
         </xsl:otherwise>
      </xsl:choose>
   </xsl:template>
   
   <xsl:template match="h:h5">
      <xsl:param name="context"/>
      <xsl:choose>
         <xsl:when test="$context = 'html'">
            <xsl:call-template name="element"/>
         </xsl:when>
         <xsl:otherwise>
            <xsl:call-template name="newblock"/>
            <xsl:text>##### </xsl:text>
            <xsl:apply-templates select="node()"/>
            <xsl:text> #####</xsl:text>
         </xsl:otherwise>
      </xsl:choose>
   </xsl:template>
   
   <xsl:template match="h:h6">
      <xsl:param name="context"/>
      <xsl:choose>
         <xsl:when test="$context = 'html'">
            <xsl:call-template name="element"/>
         </xsl:when>
         <xsl:otherwise>
            <xsl:call-template name="newblock"/>
            <xsl:text>###### </xsl:text>
            <xsl:apply-templates select="node()"/>
            <xsl:text> ######</xsl:text>
         </xsl:otherwise>
      </xsl:choose>
   </xsl:template>
   
   <xsl:template match="h:br">
      <xsl:param name="context"/>
      <xsl:choose>
         <xsl:when test="$context = 'html'">
            <xsl:call-template name="element"/>
         </xsl:when>
         <xsl:otherwise>
            <xsl:text>  </xsl:text>
            <xsl:value-of select="$newline"/>
         </xsl:otherwise>
      </xsl:choose>
   </xsl:template>
   
   <xsl:template match="h:blockquote">
      <xsl:param name="context"/>
      <xsl:choose>
         <xsl:when test="$context = 'html'">
            <xsl:call-template name="element"/>
         </xsl:when>
         <xsl:otherwise>
            <xsl:if test="node()[1] = text()">
               <xsl:call-template name="newblock"/>
               <xsl:text>&gt; </xsl:text>
            </xsl:if>
            <xsl:apply-templates select="node()"/>
         </xsl:otherwise>
      </xsl:choose>
   </xsl:template>
   
   <!-- this transformation won't backslash the period of a genuine textual newline-number-period combo -->
   
   <xsl:template match="h:ul | h:ol">
      <xsl:param name="context"/>
      <xsl:choose>
         <xsl:when test="$context = 'html'">
            <xsl:call-template name="element"/>
         </xsl:when>
         <xsl:otherwise>
            <xsl:apply-templates select="node()"/>
         </xsl:otherwise>
      </xsl:choose>
   </xsl:template>
   
   <xsl:template match="h:li">
      <xsl:param name="context"/>
      <xsl:choose>
         <xsl:when test="$context = 'html'">
            <xsl:call-template name="element"/>
         </xsl:when>
         <xsl:when test="parent::h:ul">
            <xsl:call-template name="newblock"/>
            <xsl:text>* </xsl:text>
            <xsl:apply-templates select="node()"/>
         </xsl:when>
         <xsl:when test="parent::h:ol">
            <xsl:call-template name="newblock"/>
	    	<xsl:value-of select="position()"/>
            <xsl:text>. </xsl:text>
            <xsl:apply-templates select="node()"/>
         </xsl:when>
      </xsl:choose>
   </xsl:template>
   
   <xsl:template match="h:pre[h:code]">
      <xsl:param name="context"/>
      <xsl:choose>
         <xsl:when test="$context = 'html'">
            <xsl:call-template name="element"/>
         </xsl:when>
         <xsl:otherwise>
            <xsl:call-template name="newblock"/>
            <xsl:value-of select="$tab"/>
            <xsl:apply-templates select="h:code/node()"/>
         </xsl:otherwise>
      </xsl:choose>
   </xsl:template>
   
   <xsl:template match="h:hr">
      <xsl:param name="context"/>
      <xsl:choose>
         <xsl:when test="$context = 'html'">
            <xsl:call-template name="element"/>
         </xsl:when>
         <xsl:otherwise>
            <xsl:call-template name="newblock"/>
            <xsl:text>- - - - - -</xsl:text>
         </xsl:otherwise>
      </xsl:choose>
   </xsl:template>
   
   <xsl:template match="h:a[@href]">
      <xsl:param name="context"/>
      <xsl:choose>
         <xsl:when test="$context = 'html'">
            <xsl:call-template name="element"/>
         </xsl:when>
         <xsl:otherwise>
            <xsl:text>[</xsl:text>
            <xsl:apply-templates select="text()"/>
            <xsl:text>](</xsl:text>
            <xsl:value-of select="@href"/>
            <xsl:if test="@title">
               <xsl:text> "</xsl:text>
               <xsl:value-of select="@title"/>
               <xsl:text>"</xsl:text>
            </xsl:if>
            <xsl:text>)</xsl:text>
         </xsl:otherwise>
      </xsl:choose>
   </xsl:template>
   
   <!-- this transformation won't backslash literal asterisks or underscores in text -->
   
   <xsl:template match="h:em">
      <xsl:param name="context"/>
      <xsl:choose>
         <xsl:when test="$context = 'html'">
            <xsl:call-template name="element"/>
         </xsl:when>
         <xsl:otherwise>
            <xsl:text>*</xsl:text>
            <xsl:apply-templates select="text()"/>
            <xsl:text>*</xsl:text>
         </xsl:otherwise>
      </xsl:choose>
   </xsl:template>
   
   <xsl:template match="h:strong">
      <xsl:param name="context"/>
      <xsl:choose>
         <xsl:when test="$context = 'html'">
            <xsl:call-template name="element"/>
         </xsl:when>
         <xsl:otherwise>
            <xsl:text>**</xsl:text>
            <xsl:apply-templates select="text()"/>
            <xsl:text>**</xsl:text>
         </xsl:otherwise>
      </xsl:choose>
   </xsl:template>
   
   <!-- this transformation won't backslash literal backticks in text -->
   
   <xsl:template match="h:code">
      <xsl:param name="context"/>
      <xsl:choose>
         <xsl:when test="$context = 'html'">
            <xsl:call-template name="element"/>
         </xsl:when>
         <xsl:otherwise>
            <xsl:text>`</xsl:text>
            <xsl:apply-templates select="text()"/>
            <xsl:text>`</xsl:text>
         </xsl:otherwise>
      </xsl:choose>
   </xsl:template>
   
   <xsl:template match="h:img[not(@width | @height)]">
      <xsl:param name="context"/>
      <xsl:choose>
         <xsl:when test="$context = 'html'">
            <xsl:call-template name="element"/>
         </xsl:when>
         <xsl:otherwise>
            <xsl:text>![</xsl:text>
            <xsl:value-of select="@alt"/>
            <xsl:text>](</xsl:text>
            <xsl:value-of select="@src"/>
            <xsl:if test="@title">
               <xsl:text> "</xsl:text>
               <xsl:value-of select="@title"/>
               <xsl:text>"</xsl:text>
            </xsl:if>
            <xsl:text>)</xsl:text>
         </xsl:otherwise>
      </xsl:choose>
   </xsl:template>

	<xsl:template match="h:head">
		<xsl:apply-templates match="h:meta"/>
		<xsl:text>

</xsl:text>
</xsl:template>

	<xsl:template match="h:head/h:link">
		<xsl:text>css:	</xsl:text>
		<xsl:value-of select="@href"/>
		<xsl:text>
</xsl:text>
	</xsl:template>

	<xsl:template match="h:meta">
		<xsl:value-of select="@name"/>
		<xsl:text>:	</xsl:text>
		<xsl:value-of select="@content"/>
		<xsl:text>
</xsl:text>
	</xsl:template>

	<xsl:template match="h:title">
		<xsl:text>Title:	</xsl:text>
		<xsl:value-of select="."/>
		<xsl:text>
</xsl:text>
	</xsl:template>


	<!-- The following template is taken from the book "XSLT" by Doug Tidwell (O'Reilly and Associates, August 2001, ISBN 0-596-00053-7) -->
	<xsl:template name="replace-substring">
		<xsl:param name="original"/>
		<xsl:param name="substring"/>
		<xsl:param name="replacement" select="''"/>
		<xsl:variable name="first">
			<xsl:choose>
				<xsl:when test="contains($original, $substring)">
					<xsl:value-of select="substring-before($original, $substring)"/>
				</xsl:when>
				<xsl:otherwise>
					<xsl:value-of select="$original"/>
				</xsl:otherwise>
			</xsl:choose>
		</xsl:variable>
		<xsl:variable name="middle">
			<xsl:choose>
				<xsl:when test="contains($original, $substring)">
					<xsl:value-of select="$replacement"/>
				</xsl:when>
				<xsl:otherwise>
					<xsl:text/>
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
									<xsl:value-of select="substring-after($original, $substring)"/>
								</xsl:with-param>
								<xsl:with-param name="substring">
									<xsl:value-of select="$substring"/>
								</xsl:with-param>
								<xsl:with-param name="replacement">
									<xsl:value-of select="$replacement"/>
								</xsl:with-param>
							</xsl:call-template>
						</xsl:when>	
						<xsl:otherwise>
							<xsl:value-of select="substring-after($original, $substring)"/>
						</xsl:otherwise>
					</xsl:choose>
				</xsl:when>
				<xsl:otherwise>
					<xsl:text/>
				</xsl:otherwise>		
			</xsl:choose>				
		</xsl:variable>		
		<xsl:value-of select="concat($first, $middle, $last)"/>
	</xsl:template>

</xsl:stylesheet>