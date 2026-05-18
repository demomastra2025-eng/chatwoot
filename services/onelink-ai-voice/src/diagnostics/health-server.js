const { createServer } = require('node:http');

function createHealthServer({ registry = null, port = 8081 } = {}) {
  const server = createServer((req, res) => {
    res.setHeader('content-type', 'application/json');
    if (req.url === '/health' || req.url === '/ready') {
      const sessions = registry
        ? (typeof registry.activeCount === 'function' ? registry.activeCount() : registry.sessions.size)
        : 0;
      res.end(JSON.stringify({ status: 'ok', sessions }));
      return;
    }
    res.statusCode = 404;
    res.end(JSON.stringify({ error: 'not_found' }));
  });

  return {
    server,
    listen: () => new Promise((resolve) => server.listen(port, () => resolve(server))),
    close: () => new Promise((resolve) => server.close(resolve))
  };
}

module.exports = { createHealthServer };
