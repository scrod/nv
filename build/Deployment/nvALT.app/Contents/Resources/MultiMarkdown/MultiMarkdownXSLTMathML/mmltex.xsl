<?xml version='1.0' encoding="UTF-8"?>
<xsl:stylesheet xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
		xmlns:m="http://www.w3.org/1998/Math/MathML"
        xmlns:html="http://www.w3.org/1999/xhtml"
        version='1.0'>
                
<xsl:output method="text" indent="no" encoding="UTF-8"/>

<!-- ====================================================================== -->
<!-- $Id: mmltex.xsl 441 2007-09-16 23:21:16Z fletcher $
     This file is part of the XSLT MathML Library distribution.
     See ./README or http://www.raleigh.ru/MathML/mmltex for
     copyright and other information
     Modified by Fletcher T. Penney for MultiMarkdown Version 2.0.a   		-->
<!-- ====================================================================== -->

<!-- modified by Fletcher T. Penney to handle equation labels -->

<xsl:include href="tokens.xsl"/>
<xsl:include href="glayout.xsl"/>
<xsl:include href="scripts.xsl"/>
<xsl:include href="tables.xsl"/>
<xsl:include href="entities.xsl"/>
<xsl:include href="cmarkup.xsl"/>

<xsl:strip-space elements="m:*"/>

<xsl:template match="m:math[not(@mode) or @mode='inline'][not(@display)] | m:math[@display='inline']">
	<xsl:text>&#x00024; </xsl:text>
	<xsl:apply-templates/>
	<xsl:text>&#x00024;</xsl:text>
</xsl:template>

<xsl:template match="m:math[@display='block'] | m:math[@mode='display'][not(@display)]">
	<xsl:text>&#xA;\[&#xA;&#x9;</xsl:text>
	<xsl:apply-templates/>
	<xsl:text>&#xA;\]</xsl:text>
</xsl:template>

<xsl:template match="m:math[last()=1]">
	<xsl:choose>
		<xsl:when test="not(parent::html:p/text() or parent::html:li or parent::html:th or parent::html:td)">
			<xsl:value-of select="parent::html:p/text()"/>
			<xsl:text>\begin{equation}
</xsl:text>
		<xsl:if test="@id">
			<xsl:text>\label{</xsl:text>
			<xsl:value-of select="@id"/>
			<xsl:text>}
</xsl:text>
		</xsl:if>
			<xsl:apply-templates/>
			<xsl:text>
\end{equation}</xsl:text>
		</xsl:when>
		<xsl:otherwise>
			<xsl:text>&#x00024;</xsl:text>
			<xsl:apply-templates/>
			<xsl:text>&#x00024;</xsl:text>
		</xsl:otherwise>
	</xsl:choose>
</xsl:template>

</xsl:stylesheet>