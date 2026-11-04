# Workshop laptop preflight

Checks that your laptop is ready for the workshop. Run it while connected to your company network. It takes about 10-20 minutes.

You need Python and either VS Code or Cursor. If the command says Python is not found, send your instructor a screenshot.

## Steps

1. Download [workshop-preflight.zip](https://github.com/kartik-nighania/av-pfizer-training/raw/main/workshop-preflight.zip) and extract it into a normal folder.
2. In VS Code or Cursor, choose **File > Open Folder** and open the extracted `workshop-preflight` folder.
3. Open **Terminal > New Terminal** and run:
   - **Windows:** `python preflight.py` (if that fails, `py preflight.py`)
   - **macOS:** `python3 preflight.py`
4. Press Enter to accept the default settings. The API keys are already included, so there is nothing to paste. When asked, confirm that the Langfuse page loads in Google Chrome.
5. When it finishes, send your instructor the `workshop-preflight-report-<date>.txt` file that appears in that folder.

If a check fails, the script records it and carries on, so please let it finish.

See [workshop-preflight/README.md](workshop-preflight/README.md) for what it checks, what it changes, and what the report contains.
