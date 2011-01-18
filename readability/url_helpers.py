import logging
from urlparse import urlparse

def host_for_url(url):
	"""
	>>> host_for_url('http://base/whatever/fdsh')
	'base'
	>>> host_for_url('invalid')
	"""
	host = urlparse(url)[1]
	if not host:
		logging.error("could not extract host from URL: %r" % (url,))
		return None
	return host

def absolute_url(url, base_href):
	"""
	>>> absolute_url('foo', 'http://base/whatever/ooo/fdsh')
	'http://base/whatever/ooo/foo'

	>>> absolute_url('foo/bar/', 'http://base')
	'http://base/foo/bar/'

	>>> absolute_url('/foo/bar', 'http://base/whatever/fdskf')
	'http://base/foo/bar'

	>>> absolute_url('\\n/foo/bar', 'http://base/whatever/fdskf')
	'http://base/foo/bar'

	>>> absolute_url('http://localhost/foo', 'http://base/whatever/fdskf')
	'http://localhost/foo'
	"""
	url = url.strip()
	proto = urlparse(url)[0]
	if proto:
		return url

	base_url_parts = urlparse(base_href)
	base_server = '://'.join(base_url_parts[:2])
	if url.startswith('/'):
		return base_server + url
	else:
		path = base_url_parts[2]
		if '/' in path:
			path = path.rsplit('/', 1)[0] + '/'
		else:
			path = '/'
		return base_server + path + url

if __name__ == '__main__':
	import doctest
	doctest.testmod()