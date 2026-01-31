#!/usr/bin/env node

const express = require('express');
const app = express();

// Configuration
const PORT = process.env.PORT || 3000;
const NODE_ENV = process.env.NODE_ENV || 'development';
const APP_NAME = process.env.APP_NAME || 'simple-api';
const ENVIRONMENT = process.env.ENVIRONMENT || 'unknown';

// Middleware
app.use(express.json());

// Request logging
app.use((req, res, next) => {
  const timestamp = new Date().toISOString();
  console.log(`[${timestamp}] ${req.method} ${req.path}`);
  next();
});

// =================================================================
// Routes
// =================================================================

// Health check endpoint (required)
app.get('/health', (req, res) => {
  res.status(200).json({
    status: 'healthy',
    timestamp: new Date().toISOString(),
    uptime: process.uptime()
  });
});

// Root endpoint
app.get('/', (req, res) => {
  res.json({
    message: 'Welcome to Simple API',
    app: APP_NAME,
    environment: ENVIRONMENT,
    nodeEnv: NODE_ENV,
    version: '1.0.0',
    timestamp: new Date().toISOString()
  });
});

// API info endpoint
app.get('/api/info', (req, res) => {
  res.json({
    app: {
      name: APP_NAME,
      version: '1.0.0',
      environment: ENVIRONMENT
    },
    system: {
      nodeVersion: process.version,
      platform: process.platform,
      arch: process.arch,
      uptime: Math.floor(process.uptime()),
      memory: {
        rss: `${Math.round(process.memoryUsage().rss / 1024 / 1024)}MB`,
        heapTotal: `${Math.round(process.memoryUsage().heapTotal / 1024 / 1024)}MB`,
        heapUsed: `${Math.round(process.memoryUsage().heapUsed / 1024 / 1024)}MB`
      }
    },
    timestamp: new Date().toISOString()
  });
});

// Environment variables endpoint (example - remove in production!)
app.get('/api/env', (req, res) => {
  res.json({
    NODE_ENV,
    ENVIRONMENT,
    APP_NAME,
    PORT,
    // Only expose safe variables, never secrets!
    timestamp: new Date().toISOString()
  });
});

// Echo endpoint (for testing)
app.post('/api/echo', (req, res) => {
  res.json({
    message: 'Echo successful',
    received: req.body,
    timestamp: new Date().toISOString()
  });
});

// 404 handler
app.use((req, res) => {
  res.status(404).json({
    error: 'Not Found',
    path: req.path,
    message: 'The requested endpoint does not exist',
    timestamp: new Date().toISOString()
  });
});

// Error handler
app.use((err, req, res, next) => {
  console.error('[ERROR]', err);
  res.status(500).json({
    error: 'Internal Server Error',
    message: NODE_ENV === 'production' ? 'An error occurred' : err.message,
    timestamp: new Date().toISOString()
  });
});

// =================================================================
// Start Server
// =================================================================

app.listen(PORT, '0.0.0.0', () => {
  console.log('='.repeat(60));
  console.log(`🚀 Simple API started successfully`);
  console.log(`📌 Environment: ${ENVIRONMENT}`);
  console.log(`🌍 Node Environment: ${NODE_ENV}`);
  console.log(`🔗 Port: ${PORT}`);
  console.log(`⏰ Started: ${new Date().toISOString()}`);
  console.log('='.repeat(60));
  console.log('\nAvailable endpoints:');
  console.log('  GET  /              - Welcome message');
  console.log('  GET  /health        - Health check');
  console.log('  GET  /api/info      - Application info');
  console.log('  GET  /api/env       - Environment variables');
  console.log('  POST /api/echo      - Echo request body');
  console.log('='.repeat(60));
});

// Graceful shutdown
process.on('SIGTERM', () => {
  console.log('\n⚠️  SIGTERM received, shutting down gracefully...');
  process.exit(0);
});

process.on('SIGINT', () => {
  console.log('\n⚠️  SIGINT received, shutting down gracefully...');
  process.exit(0);
});
