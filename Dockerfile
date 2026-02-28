# Use a lightweight Node image
FROM node:18-alpine

# Set the working directory
WORKDIR /app

# Copy package files and install dependencies
COPY package*.json ./
RUN npm install

# Copy the rest of the backend files (including index.html and .env)
COPY . .

# Expose the API and UI port
EXPOSE 3000

# Start the GenTwin server
CMD ["node", "server.js"]