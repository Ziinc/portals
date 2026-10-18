# Portals starts this script and appends the socket path as the last argument.
from portals import Worker

Worker(max_concurrency=8, max_streams=4).run()
