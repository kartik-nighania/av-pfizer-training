# Workshop laptop preflight

Run this before the workshop, ideally on the network and VPN you will use on the day.
It takes about 5-15 minutes and ends by writing a report file to send to your instructor.

## Run it

Extract the whole zip into a normal folder first. Do not run it from inside the zip.

- **Windows:** double-click `preflight_windows.cmd`.
- **macOS:** open Terminal, type `bash ` (with a space), drag `preflight_mac.sh` into the window, and press Enter.

You will be asked to:

1. Accept the default settings or change them. Press Enter to accept.
2. Paste any API keys that were not supplied to you. Typing is hidden, and Enter skips a key.
3. Open Langfuse in Google Chrome and confirm that the page loads.

If a check fails, the script records it and carries on, so every check gets a result. Please let it finish.

When it finishes, send the `workshop-preflight-report-<date>.txt` file from your home folder to your instructor.

## What it checks

| Area | Check |
| --- | --- |
| Laptop | RAM, free disk, admin rights |
| Terminal | Commands and scripts run; PowerShell policy on Windows |
| Python | Python 3.10+, pip, virtual environments, the workshop's exact packages from PyPI |
| Jupyter | Notebook execution, JupyterLab and Notebook UIs, Jupyter terminal |
| OpenAI | api.openai.com reachable; key and a very small test chat call per workshop model |
| Langfuse | UI and API reachable; keys accepted; page loads in Chrome |
| Git | Git installed; clones the workshop repo |
| IDE | VS Code or Cursor with the Python and Jupyter extensions |
| Docker | Engine running, Docker Hub pulls, build with pip install, container network |

## What it changes

- Python packages go in a temporary folder that is deleted at the end. pip may keep its normal download cache.
- If Docker works, the Python base image stays on your laptop to save time on the day. The test image is removed.
- The OpenAI test makes one very small chat request per model and one model-list request on the key provided.
- Nothing is sent to your instructor automatically. The report is a local text file.

## What the report contains

It lists check results, tool versions, network and proxy settings, DNS and network adapter details, installed
Python packages, and the names of running VPN and security tools.

API keys, proxy passwords, your username and your computer name are removed. It is plain text, so please read
it before sending it if your company requires that.

If your company requires approval before running scripts, show this file and the scripts to IT first.
