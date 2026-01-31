# =================================================================
# Simple API - Dockerfile
# =================================================================
# Multi-stage build for minimal production image
# =================================================================

# =================================================================
# Build Stage
# =================================================================
FROM node:20-alpine AS builder

WORKDIR /app

# Copy package files
COPY package*.json ./

# Install dependencies
RUN npm ci --only=production && \
    npm cache clean --force

# =================================================================
# Production Stage
# =================================================================
FROM node:20-alpine

WORKDIR /app

# Create non-root user
RUN addgroup -S nodejs && adduser -S nodejs -G nodejs

# Copy dependencies from builder
COPY --from=builder --chown=nodejs:nodejs /app/node_modules ./node_modules

# Copy application code
COPY --chown=nodejs:nodejs package*.json ./
COPY --chown=nodejs:nodejs src/ ./src/

# Switch to non-root user
USER nodejs

# Expose port
EXPOSE 3000

# Set environment
ENV NODE_ENV=production \
    PORT=3000

# Health check
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD node -e "require('http').get('http://localhost:3000/health', (r) => {process.exit(r.statusCode === 200 ? 0 : 1)})"

# Start application
CMD ["node", "src/server.js"]
