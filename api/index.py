import os, sys

# Ensure backend package can be imported by adding project root to sys.path
root_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if root_dir not in sys.path:
    sys.path.insert(0, root_dir)

from backend.app import app, init_db

# Attempt to initialize database tables on cold start
try:
    init_db()
except Exception as err:
    app.logger.warning("Database initialization deferred: %s", err)
