const wsClients = new Map(); // wsInstance -> decodedToken

export const registerClient = (ws, decodedToken) => {
  wsClients.set(ws, decodedToken);
};

export const unregisterClient = (ws) => {
  wsClients.delete(ws);
};

export const getClientsCount = () => wsClients.size;

export const broadcast = (message) => {
  const payload = JSON.stringify(message);
  wsClients.forEach((user, client) => {
    if (client.readyState === 1) { // OPEN
      client.send(payload);
    }
  });
};

export const broadcastToUser = (userId, message) => {
  const payload = JSON.stringify(message);
  wsClients.forEach((user, client) => {
    if (client.readyState === 1 && user.uid === userId) {
      client.send(payload);
    }
  });
};

export const broadcastToRole = (role, message) => {
  const payload = JSON.stringify(message);
  wsClients.forEach((user, client) => {
    if (client.readyState === 1 && (user.role === role || user.role === 'admin')) {
      client.send(payload);
    }
  });
};
