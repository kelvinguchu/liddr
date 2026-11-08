#!/bin/sh
set -eu

echo "Running migrations..."
/app/bin/liddr eval "Liddr.Release.migrate"

echo "Starting Liddr API..."
exec /app/bin/liddr start
