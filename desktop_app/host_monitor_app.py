# 主机环境监控 - 桌面应用
# 用系统 WebView2(Edge) 渲染 http://127.0.0.1:7890/ ，并在未运行时自动拉起 server.cjs。
# 双击 start_host_monitor.bat 即可启动（无黑框、常驻窗口）。
import os
import sys
import time
import subprocess
import urllib.request

NODE   = r'C:\Users\lu_08\.workbuddy\binaries\node\versions\22.22.2-6\node.exe'
SERVER = r'C:\Users\lu_08\WorkBuddy\monitor_dashboard\server.cjs'
WD     = r'C:\Users\lu_08\WorkBuddy\monitor_dashboard'
URL    = 'http://127.0.0.1:7890/'

# 子进程以 DETACHED 启动，关窗口也不连坐；app 退出时也不强杀，便于网页端同时可用
DETACH = getattr(subprocess, 'DETACHED_PROCESS', 0) | getattr(subprocess, 'CREATE_NEW_PROCESS_GROUP', 0)

_proc = None


def is_up():
    try:
        urllib.request.urlopen(URL, timeout=1)
        return True
    except Exception:
        return False


def ensure_server():
    """7890 已在听就直接复用；否则用正确 node 路径后台拉起 server.cjs。"""
    global _proc
    if is_up():
        return True
    if not os.path.exists(NODE):
        sys.stderr.write(f'[ERR] node 不存在: {NODE}\n')
        return False
    if not os.path.exists(SERVER):
        sys.stderr.write(f'[ERR] server.cjs 不存在: {SERVER}\n')
        return False
    try:
        _proc = subprocess.Popen(
            [NODE, SERVER], cwd=WD,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            creationflags=DETACH,
        )
    except Exception as e:
        sys.stderr.write(f'[ERR] 启动 server.cjs 失败: {e}\n')
        return False
    for _ in range(75):  # 最多等 15s
        if is_up():
            return True
        time.sleep(0.2)
    return False


def main():
    ok = ensure_server()
    import webview  # 延迟导入，确保失败信息先打印
    if not ok:
        # 仍开窗口，让用户看到 502/错误页，而不是静默退出
        webview.create_window(
            '主机环境监控', URL, width=1280, height=800,
            resizable=True, min_size=(800, 600),
        )
        webview.start()
        return
    webview.create_window(
        '主机环境监控', URL, width=1280, height=800,
        resizable=True, min_size=(800, 600),
    )
    webview.start()
    # 不主动 terminate：让 7890 继续可用（网页端/其他进程可共用）
    if _proc and _proc.poll() is None:
        pass


if __name__ == '__main__':
    main()
