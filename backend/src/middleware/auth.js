import { auth } from '../config/firebase.js';

export const verifyToken = async (req, res, next) => {
  const authHeader = req.headers.authorization;
  if (!authHeader || !authHeader.startsWith('Bearer ')) {
    return res.status(401).json({ error: 'Missing or malformed Authorization header.' });
  }

  const token = authHeader.split('Bearer ')[1];
  try {
    const decodedToken = await auth.verifyIdToken(token);
    req.user = decodedToken;
    next();
  } catch (err) {
    console.error('Auth middleware verification failed:', err.message);
    return res.status(401).json({ error: 'Invalid or expired Authorization token.' });
  }
};

export const requireRole = (role) => {
  return (req, res, next) => {
    if (!req.user) {
      return res.status(401).json({ error: 'Unauthorized.' });
    }
    const userRole = req.user.role;
    if (userRole !== role && userRole !== 'admin') {
      return res.status(403).json({ error: `Forbidden: requires ${role} role.` });
    }
    next();
  };
};

export const requireAnyRole = (roles) => {
  return (req, res, next) => {
    if (!req.user) {
      return res.status(401).json({ error: 'Unauthorized.' });
    }
    const userRole = req.user.role;
    if (!roles.includes(userRole) && userRole !== 'admin') {
      return res.status(403).json({ error: 'Forbidden: insufficient privileges.' });
    }
    next();
  };
};
