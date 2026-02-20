#!/bin/bash

# Ensure we are in the script directory
cd "$(dirname "$0")"

echo "Installing dependencies..."
mix deps.get

echo "Setting up database..."
# Check if Postgres is running or if we need to configure connection
mix ecto.setup

echo "Setup complete. Run 'mix phx.server' to start the server."
