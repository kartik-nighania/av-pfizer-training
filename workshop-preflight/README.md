# Workshop laptop preflight

Run this before the workshop while connected to your company network. It takes about 10-20 minutes.

## Run it

1. Extract the whole zip into a normal folder. Do not run it from inside the zip.
2. In VS Code or Cursor, choose **File > Open Folder** and open the extracted `workshop-preflight` folder.
3. Open **Terminal > New Terminal** and run:
   - **Windows:** `python preflight.py` (if that fails, `py preflight.py`)
   - **macOS:** `python3 preflight.py`
4. Press Enter to accept the default settings. The API keys are already included in `keys.env`, so there is nothing to paste.
5. When asked, open Langfuse in Google Chrome and confirm that the page loads. No sign-in is needed.
6. Send your instructor the `workshop-preflight-report-<date>.txt` file that appears in this folder.

If a check fails, the script records it and carries on, so please let it finish. If the command says Python is not found, send your instructor a screenshot.

## What it checks

| Area | Check |
| --- | --- |
| Laptop | RAM, free disk, admin rights |
| Terminal | Running in the IDE terminal; commands run; PowerShell policy on Windows |
| Python | Python 3.10+, pip, virtual environments, workshop packages from PyPI |
| Jupyter | Notebook execution, JupyterLab and Notebook UIs, Jupyter terminal |
| OpenAI | api.openai.com reachable; key and a very small test chat call per workshop model |
| Langfuse | UI and API reachable; keys accepted; page loads in Chrome |
| Git | Git installed; clones this test repo from GitHub |
| IDE | VS Code or Cursor with the Python and Jupyter extensions |
| Docker | Engine running, Docker Hub pulls, build with pip install, container network |

## What it changes

- Python packages go in a temporary folder that is deleted at the end. pip may keep its normal download cache.
- If Docker works, the Python base image stays on your laptop to save time on the day. The test image is removed.
- The OpenAI test makes one very small chat request per model and one model-list request.
- Nothing is sent to your instructor automatically. The report is a local text file.

## What the report contains

It lists check results, tool versions, network and proxy settings, DNS and network adapter details, installed Python packages, and the names of running VPN and security tools.

API keys, proxy passwords, your username and your computer name are removed. It is plain text, so please read it before sending it if your company requires that.

If your company requires approval before running scripts, show this file and `preflight.py` to IT first.
