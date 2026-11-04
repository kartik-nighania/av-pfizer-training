import sys

import requests

failed = False
for url in sys.argv[1:]:
    try:
        response = requests.get(url, timeout=15)
        print("OK", url, response.status_code)
    except Exception as exc:
        failed = True
        print("FAIL", url, type(exc).__name__, str(exc)[:300])
sys.exit(1 if failed else 0)
