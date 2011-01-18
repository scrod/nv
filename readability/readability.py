#!/usr/bin/env python
from BeautifulSoup import NavigableString
from page_parser import parse, get_title, get_body, Unparseable
import logging
import re

REGEXES = { 'unlikelyCandidatesRe': re.compile('combx|comment|disqus|foot|header|menu|meta|nav|rss|shoutbox|sidebar|sponsor',re.I),
	'okMaybeItsACandidateRe': re.compile('and|article|body|column|main',re.I),
	'positiveRe': re.compile('article|body|content|entry|hentry|page|pagination|post|text',re.I),
	'negativeRe': re.compile('combx|comment|contact|foot|footer|footnote|link|media|meta|promo|related|scroll|shoutbox|sponsor|tags|widget',re.I),
	'divToPElementsRe': re.compile('<(a|blockquote|dl|div|img|ol|p|pre|table|ul)',re.I),
	'replaceBrsRe': re.compile('(<br[^>]*>[ \n\r\t]*){2,}',re.I),
	'replaceFontsRe': re.compile('<(\/?)font[^>]*>',re.I),
	'trimRe': re.compile('^\s+|\s+$/'),
	'normalizeRe': re.compile('\s{2,}/'),
	'killBreaksRe': re.compile('(<br\s*\/?>(\s|&nbsp;?)*){1,}/'),
	'videoRe': re.compile('http:\/\/(www\.)?(youtube|vimeo)\.com', re.I),
}

from collections import defaultdict
def describe(node):
	if not hasattr(node, 'name'):
		return "[text]"
	return "%s#%s.%s" % (
		node.name, node.get('id', ''), node.get('class',''))

def _text(node):
	return " ".join(node.findAll(text=True))

class Document:
	TEXT_LENGTH_THRESHOLD = 25
	RETRY_LENGTH = 250

	def __init__(self, input, notify=None, **options):
		self.input = input
		self.options = defaultdict(lambda: None)
		for k, v in options.items():
			self.options[k] = v
		self.notify = notify or logging.info
		self.html = None

	def _html(self, force=False):
		if force or self.html is None:
			self.html = parse(self.input, self.options['url'], notify=self.notify)
		return self.html
	
	def content(self):
		return get_body(self._html())
	
	def title(self):
		return get_title(self._html())

	def summary(self):
		try:
			ruthless = True
			while True:
				self._html(True)
				[i.extract() for i in self.tags(self.html, 'script', 'style')]

				if ruthless: self.remove_unlikely_candidates()
				self.transform_misused_divs_into_paragraphs()
				candidates = self.score_paragraphs(self.options.get('min_text_length', self.TEXT_LENGTH_THRESHOLD))
				best_candidate = self.select_best_candidate(candidates)
				if best_candidate:
					article = self.get_article(candidates, best_candidate)
				else:
					if ruthless:
						ruthless = False
						self.debug("ended up stripping too much - going for a safer parse")
						# try again
						continue
					else:
						article = self.html.find('body') or self.html

				cleaned_article = self.sanitize(article, candidates)
				of_acceptable_length = len(cleaned_article or '') >= (self.options['retry_length'] or self.RETRY_LENGTH)
				if ruthless and not of_acceptable_length:
					ruthless = False
					continue # try again
				else:
					return cleaned_article
		except StandardError, e:
			logging.exception('error getting summary:')
			raise Unparseable(str(e))

	def get_article(self, candidates, best_candidate):
		# Now that we have the top candidate, look through its siblings for content that might also be related.
		# Things like preambles, content split by ads that we removed, etc.

		sibling_score_threshold = max([10, best_candidate['content_score'] * 0.2])
		output = parse("<div/>")
		for sibling in best_candidate['elem'].parent.contents:
			if isinstance(sibling, NavigableString): continue
			append = False
			if sibling is best_candidate['elem']:
				append = True
			sibling_key = HashableElement(sibling)
			if sibling_key in candidates and candidates[sibling_key]['content_score'] >= sibling_score_threshold:
				append = True

			if sibling.name == "p":
				link_density = self.get_link_density(sibling)
				node_content = sibling.string or ""
				node_length = len(node_content)

				if node_length > 80 and link_density < 0.25:
					append = True
				elif node_length < 80 and link_density == 0 and re.search('\.( |$)', node_content):
					append = True

			if append:
				output.append(sibling)

		if not output: output.append(best_candidate)
		return output

	def select_best_candidate(self, candidates):
		sorted_candidates = sorted(candidates.values(), key=lambda x: x['content_score'], reverse=True)
		self.debug("Top 5 candidates:")
		for candidate in sorted_candidates[:5]:
			elem = candidate['elem']
			self.debug("Candidate %s with score %s" % (describe(elem), candidate['content_score']))

		if len(sorted_candidates) == 0:
			return None
		best_candidate = sorted_candidates[0]
		self.debug("Best candidate %s with score %s" % (describe(best_candidate['elem']), best_candidate['content_score']))
		return best_candidate

	def get_link_density(self, elem):
		link_length = len("".join([i.text or "" for i in elem.findAll("a")]))
		text_length = len(_text(elem))
		return float(link_length) / max(text_length, 1)

	def score_paragraphs(self, min_text_length):
		candidates = {}
		elems = self.tags(self.html, "p","td")

		for elem in elems:
			parent_node = elem.parent
			grand_parent_node = parent_node.parent
			parent_key = HashableElement(parent_node)
			grand_parent_key = HashableElement(grand_parent_node)

			inner_text = _text(elem)

			# If this paragraph is less than 25 characters, don't even count it.
			if (not inner_text) or len(inner_text) < min_text_length:
				continue

			if parent_key not in candidates:
				candidates[parent_key] = self.score_node(parent_node)
			if grand_parent_node and grand_parent_key not in candidates:
				candidates[grand_parent_key] = self.score_node(grand_parent_node)

			content_score = 1
			content_score += len(inner_text.split(','))
			content_score += min([(len(inner_text) / 100), 3])

			candidates[parent_key]['content_score'] += content_score
			if grand_parent_node:
				candidates[grand_parent_key]['content_score'] += content_score / 2.0

		# Scale the final candidates score based on link density. Good content should have a
		# relatively small link density (5% or less) and be mostly unaffected by this operation.
		for elem, candidate in candidates.items():
			candidate['content_score'] *= (1 - self.get_link_density(elem))
			self.debug("candidate %s scored %s" % (describe(elem), candidate['content_score']))

		return candidates

	def class_weight(self, e):
		weight = 0
		if e.get('class', None):
			if REGEXES['negativeRe'].search(e['class']):
				weight -= 25

			if REGEXES['positiveRe'].search(e['class']):
				weight += 25

		if e.get('id', None):
			if REGEXES['negativeRe'].search(e['id']):
				weight -= 25

			if REGEXES['positiveRe'].search(e['id']):
				weight += 25

		return weight

	def score_node(self, elem):
		content_score = self.class_weight(elem)
		name = elem.name.lower()
		if name == "div":
			content_score += 5
		elif name == "blockquote":
			content_score += 3
		elif name == "form":
			content_score -= 3
		elif name == "th":
			content_score -= 5
		return { 'content_score': content_score, 'elem': elem }

	def debug(self, *a):
		if self.options['debug']:
			logging.debug(*a)

	def remove_unlikely_candidates(self):
		for elem in self.html.findAll():
			s = "%s%s" % (elem.get('class', ''), elem.get('id', ''))
			if REGEXES['unlikelyCandidatesRe'].search(s) and (not REGEXES['okMaybeItsACandidateRe'].search(s)) and elem.name != 'body':
				self.debug("Removing unlikely candidate - %s" % (s,))
				elem.extract()

	def transform_misused_divs_into_paragraphs(self):
		for elem in self.html.findAll():
			if elem.name.lower() == "div":
				# transform <div>s that do not contain other block elements into <p>s
				if REGEXES['divToPElementsRe'].search(''.join(map(unicode, elem.contents))):
					self.debug("Altering div(#%s.%s) to p" % (elem.get('id', ''), elem.get('class', '')))
					elem.name = "p"

	def tags(self, node, *tag_names):
		for tag_name in tag_names:
			for e in node.findAll(tag_name):
				yield e

	def sanitize(self, node, candidates):
		for header in self.tags(node, "h1", "h2", "h3", "h4", "h5", "h6"):
			if self.class_weight(header) < 0 or self.get_link_density(header) > 0.33: header.extract()

		for elem in self.tags(node, "form", "iframe"):
			elem.extract()

		# Conditionally clean <table>s, <ul>s, and <div>s
		for el in self.tags(node, "table", "ul", "div"):
			weight = self.class_weight(el)
			el_key = HashableElement(el)
			if el_key in candidates:
				content_score = candidates[el_key]['content_score']
			else:
				content_score = 0
			name = el.name

			if weight + content_score < 0:
				el.extract()
				self.debug("Conditionally cleaned %s with weight %s and content score %s because score + content score was less than zero." %
					(describe(el), weight, content_score))
			elif len(_text(el).split(",")) < 10:
				counts = {}
				for kind in ['p', 'img', 'li', 'a', 'embed', 'input']:
					counts[kind] = len(el.findAll(kind))
				counts["li"] -= 100

				content_length = len(_text(el)) # Count the text length excluding any surrounding whitespace
				link_density = self.get_link_density(el)
				to_remove = False
				reason = ""

				if counts["img"] > counts["p"]:
					reason = "too many images"
					to_remove = True
				elif counts["li"] > counts["p"] and name != "ul" and name != "ol":
					reason = "more <li>s than <p>s"
					to_remove = True
				elif counts["input"] > (counts["p"] / 3):
					reason = "less than 3x <p>s than <input>s"
					to_remove = True
				elif content_length < (self.options.get('min_text_length', self.TEXT_LENGTH_THRESHOLD)) and (counts["img"] == 0 or counts["img"] > 2):
					reason = "too short a content length without a single image"
					to_remove = True
				elif weight < 25 and link_density > 0.2:
					reason = "too many links for its weight (#{weight})"
					to_remove = True
				elif weight >= 25 and link_density > 0.5:
					reason = "too many links for its weight (#{weight})"
					to_remove = True
				elif (counts["embed"] == 1 and content_length < 75) or counts["embed"] > 1:
					reason = "<embed>s with too short a content length, or too many <embed>s"
					to_remove = True

				if to_remove:
					self.debug("Conditionally cleaned %s#%s.%s with weight %s and content score %s because it has %s." %
						(el.name, el.get('id',''), el.get('class', ''), weight, content_score, reason))
					el.extract()

		for el in ([node] + node.findAll()):
			if not (self.options['attributes']):
				el.attrMap = {}

		return unicode(node)

class HashableElement():
	def __init__(self, node):
		self.node = node
		self._path = None

	def _get_path(self):
		if self._path is None:
			reverse_path = []
			node = self.node
			while node:
				node_id = (node.name, tuple(node.attrs), node.string)
				reverse_path.append(node_id)
				node = node.parent
			self._path = tuple(reverse_path)
		return self._path
	path = property(_get_path)

	def __hash__(self):
		return hash(self.path)

	def __eq__(self, other):
		return self.path == other.path

	def __getattr__(self, name):
		return getattr(self.node, name)

def main():
	import sys
	from optparse import OptionParser
	parser = OptionParser(usage="%prog: [options] [file]")
	parser.add_option('-v', '--verbose', action='store_true')
	parser.add_option('-u', '--url', help="use URL instead of a local file")
	(options, args) = parser.parse_args()
	
	if not (len(args) == 1 or options.url):
		parser.print_help()
		sys.exit(1)
	logging.basicConfig(level=logging.DEBUG)

	file = None
	if options.url:
		import urllib
		file = urllib.urlopen(options.url)
	else:
		file = open(args[0])
	try:
		print Document(file.read(), debug=options.verbose).summary().encode('ascii','ignore')
	finally:
		file.close()

if __name__ == '__main__':
	main()
