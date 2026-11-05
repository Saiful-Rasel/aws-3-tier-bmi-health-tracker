require('dotenv').config();
const express=require('express');
const bodyParser=require('body-parser');
const cors=require('cors');
const routes=require('./routes');

const app=express();
const PORT = process.env.PORT || 3000;
const NODE_ENV = process.env.NODE_ENV || 'development';

// In production, FRONTEND_URL must be explicitly set — no silent fallback
if (NODE_ENV === 'production' && !process.env.FRONTEND_URL) {
  throw new Error('FRONTEND_URL environment variable is required in production.');
}

// CORS configuration
const corsOptions = {
  origin: NODE_ENV === 'production'
    ? process.env.FRONTEND_URL
    : ['http://localhost:5173', 'http://localhost:3000'],
  credentials: true,
  optionsSuccessStatus: 200
};

app.use(cors(corsOptions));
app.use(bodyParser.json());

// Health check endpoint — do not expose NODE_ENV in production
app.get('/health', (req, res) => {
  const payload = { status: 'ok' };
  if (NODE_ENV !== 'production') payload.environment = NODE_ENV;
  res.json(payload);
});

// API routes
app.use('/api', routes);

// 404 handler
app.use((req, res) => {
  res.status(404).json({ error: 'Route not found' });
});

// Error handler
app.use((err, req, res, next) => {
  console.error('Server error:', err);
  res.status(500).json({ error: 'Internal server error' });
});

// Start server
const server = app.listen(PORT, () => {
  console.log(`Server running on port ${PORT}`);
  console.log(`Environment: ${NODE_ENV}`);
  console.log(`API: http://localhost:${PORT}/api`);
});

// Graceful shutdown — drain in-flight requests and close DB pool before exiting
const { pool } = require('./db');
process.on('SIGTERM', () => {
  console.log('SIGTERM received. Shutting down gracefully...');
  server.close(() => {
    pool.end(() => {
      console.log('Database pool closed. Exiting.');
      process.exit(0);
    });
  });
});