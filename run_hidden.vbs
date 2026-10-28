' Hidden launcher for monitor dashboard (port 7890) - no console window.
' wscript exits immediately; node runs as a detached background process.
CreateObject("WScript.Shell").CurrentDirectory = "C:\Users\lu_08\WorkBuddy\monitor_dashboard"
CreateObject("WScript.Shell").Run """C:\Users\lu_08\.workbuddy\binaries\node\versions\22.22.2-6\node.exe"" ""C:\Users\lu_08\WorkBuddy\monitor_dashboard\server.cjs""", 0, False
