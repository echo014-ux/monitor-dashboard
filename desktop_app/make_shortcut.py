# 一次性工具：创建桌面快捷方式 主机环境监控.lnk
import os
import win32com.client

ws = win32com.client.Dispatch('WScript.Shell')
path = r'C:\Users\lu_08\Desktop\主机环境监控.lnk'
lnk = ws.CreateShortcut(path)
lnk.TargetPath = r'C:\Users\lu_08\.workbuddy\binaries\python\envs\default\Scripts\pythonw.exe'
lnk.Arguments = r'"C:\Users\lu_08\WorkBuddy\monitor_dashboard\desktop_app\host_monitor_app.py"'
lnk.WorkingDirectory = r'C:\Users\lu_08\WorkBuddy\monitor_dashboard\desktop_app'
lnk.IconLocation = r'C:\Windows\System32\shell32.dll,13'
lnk.Description = '主机环境监控 (127.0.0.1:7890)'
lnk.Save()
print('EXISTS=' + str(os.path.exists(path)))
