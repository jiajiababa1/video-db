# monsnode 爬虫定时任务脚本
# 由 Windows 任务计划程序 或 GitHub Actions 自动调用
# 用法: powershell -File run_scraper.ps1

$ErrorActionPreference = "Stop"

$env:SUPABASE_URL = "https://fejspvbckgkbmfyoxiub.supabase.co"
$env:SUPABASE_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImZlanNwdmJja2drYm1meW94aXViIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc4MDQ4NzM3NywiZXhwIjoyMDk2MDYzMzc3fQ.otVwMnsl62GdDs4mGHZXnmFbUqga3eX1eDoOenuiqz8"

$ScriptDir = "C:\Users\yuankuo\Desktop\vide coding"
$LogFile = Join-Path $ScriptDir "scraper_task.log"

try {
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "[$timestamp] 开始爬虫..." | Out-File $LogFile -Append -Encoding UTF8

    Set-Location $ScriptDir

    # 每轮爬取自动包含: 页面抓取 → MP4 解析 → 详情页回退 → 自动修复旧视频
    python scraper/main.py 2>&1 | Tee-Object -FilePath $LogFile -Append

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "[$timestamp] 完成" | Out-File $LogFile -Append -Encoding UTF8
} catch {
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "[$timestamp] 错误: $_" | Out-File $LogFile -Append -Encoding UTF8
}
