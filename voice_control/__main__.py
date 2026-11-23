import sys
from .app import main

role = sys.argv.pop(1) if len(sys.argv) > 1 and sys.argv[1] in ("controller", "client") else "controller"
main(role)
