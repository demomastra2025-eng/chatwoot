const { createServer } = require('node:http');

function createHealthServer({ registry = null, port = 8081, handlers = [], upgradeHandlers = [] } = {}) {
  const server = createServer((req, res) => {
    for (const handler of handlers) {
      if (typeof handler === 'function' && handler(req, res)) return;
    }

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
  server.on('upgrade', (req, socket, head) => {
    for (const handler of upgradeHandlers) {
      if (typeof handler === 'function' && handler(req, socket, head)) return;
    }
    socket.write('HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n');
    socket.destroy();
  });

  return {
    server,
    listen: () => new Promise((resolve) => server.listen(port, () => resolve(server))),
    close: () => new Promise((resolve) => server.close(resolve))
  };
}

module.exports = { createHealthServer };
