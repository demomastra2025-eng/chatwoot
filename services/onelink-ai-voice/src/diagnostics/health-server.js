const { createServer } = require('node:http');

function createHealthServer({ registry = null, port = 8081, handlers = [], upgradeHandlers = [], diagnostics = null } = {}) {
  const server = createServer((req, res) => {
    for (const handler of handlers) {
      if (typeof handler === 'function' && handler(req, res)) return;
    }

    res.setHeader('content-type', 'application/json');
    if (req.url === '/health' || req.url === '/ready') {
      const sessions = registry
        ? (typeof registry.activeCount === 'function' ? registry.activeCount() : registry.sessions.size)
        : 0;
      const details = typeof diagnostics === 'function' ? diagnostics() : {};
      res.end(JSON.stringify({ status: 'ok', sessions, ...details }));
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
    listen: () => new Promise((resolve, reject) => {
      const onError = error => {
        server.off('listening', onListening);
        reject(error);
      };
      const onListening = () => {
        server.off('error', onError);
        resolve(server);
      };
      server.once('error', onError);
      server.once('listening', onListening);
      server.listen(port);
    }),
    close: () => new Promise((resolve, reject) => {
      if (!server.listening) return resolve();
      return server.close(error => (error ? reject(error) : resolve()));
    })
  };
}

module.exports = { createHealthServer };
