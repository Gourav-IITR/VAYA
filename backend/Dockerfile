# Use official Node.js lightweight Alpine image
FROM node:20-alpine

# Set working directory inside container
WORKDIR /usr/src/app

# Copy package descriptors first to cache npm installs
COPY package*.json ./

# Install only production dependencies
RUN npm ci --only=production

# Copy server source code files
COPY . .

# Expose server listener port
EXPOSE 8080

# Start Express server script
CMD [ "node", "server.js" ]
