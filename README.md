# Workshop laptop preflight

Checks that your laptop is ready for the workshop. Run it while connected to your company network.

## Steps

1. Download [workshop-preflight.zip](https://github.com/kartik-nighania/av-pfizer-training/raw/main/workshop-preflight.zip).
2. Extract the whole zip into a normal folder. Do not run it from inside the zip.
3. Open the extracted `workshop-preflight` folder and start the check:
   - **Windows:** double-click `preflight_windows.cmd`.
   - **macOS:** open Terminal, type `bash ` (with a space), drag `preflight_mac.sh` into the window, and press Enter.
4. Press Enter to accept the default settings. When asked, confirm that the Langfuse page loads in Google Chrome.
5. When it finishes, send your instructor the `workshop-preflight-report-<date>.txt` file from your home folder.

If a check fails, the script records it and carries on, so please let it finish.

See [workshop-preflight/README.md](workshop-preflight/README.md) for what it checks, what it changes, and what the report contains.
