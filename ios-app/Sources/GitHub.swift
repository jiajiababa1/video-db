import Foundation

/// GitHub Actions 触发与真实字节进度 (与网站 ghDispatch / ghPoll 同原理)
enum GitHub {
    static let owner = "jiajiababa1"
    static let repo = "video-db"
    static let workflow = "scraper.yml"

    static func dispatch(mode: String, token: String) async -> Bool {
        await dispatchWorkflow(workflow, inputs: ["mode": mode], token: token)
    }

    /// 通用 workflow_dispatch (作者抓 / 补文案 / 补MP4 等都走这里)
    static func dispatchWorkflow(_ file: String, inputs: [String: String], token: String) async -> Bool {
        let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/actions/workflows/\(file)/dispatches")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["ref": "main", "inputs": inputs])
        guard let (_, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse else { return false }
        return http.statusCode == 204
    }

    struct RunState {
        var status: String          // queued / in_progress / completed / unknown
        var conclusion: String?
        var progress: Double?       // 0...1 真实字节进度, 拿不到为 nil
    }

    /// 查最新一次运行状态与字节进度
    static func latestRunState(token: String) async -> RunState? {
        guard let run = await latestRun(token: token, completed: false) else { return nil }
        let status = (run["status"] as? String) ?? "unknown"
        let conclusion = run["conclusion"] as? String
        if status == "completed" { return RunState(status: status, conclusion: conclusion, progress: 1) }
        // 字节进度: 本次主作业日志 ÷ 上次完成运行主作业日志
        var progress: Double? = nil
        if let jobId = await mainJobId(run: run, token: token),
           let cur = await logSize(jobId: jobId, token: token),
           let prevRun = await latestRun(token: token, completed: true, excluding: (run["id"] as? Int) ?? -1),
           let prevJob = await mainJobId(run: prevRun, token: token),
           let base = await logSize(jobId: prevJob, token: token), base > 0 {
            progress = min(Double(cur) / Double(base), 0.97)
        }
        return RunState(status: status, conclusion: conclusion, progress: progress)
    }

    private static func apiGET(_ urlStr: String, token: String) async -> [String: Any]? {
        guard let url = URL(string: urlStr) else { return nil }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        guard let (data, _) = try? await URLSession.shared.data(for: req) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func latestRun(token: String, completed: Bool, excluding: Int = -1) async -> [String: Any]? {
        var url = "https://api.github.com/repos/\(owner)/\(repo)/actions/workflows/\(workflow)/runs?per_page=5"
        if completed { url += "&status=completed" }
        guard let obj = await apiGET(url, token: token),
              let runs = obj["workflow_runs"] as? [[String: Any]] else { return nil }
        return runs.first { (($0["id"] as? Int) ?? -2) != excluding }
    }

    private static func mainJobId(run: [String: Any], token: String) async -> Int? {
        guard let jobsUrl = run["jobs_url"] as? String,
              let obj = await apiGET(jobsUrl, token: token),
              let jobs = obj["jobs"] as? [[String: Any]] else { return nil }
        let mains = jobs.filter { !(($0["name"] as? String) ?? "").contains("notify") }
        let job = mains.first { ($0["status"] as? String) == "in_progress" } ?? mains.first
        return job?["id"] as? Int
    }

    private static func logSize(jobId: Int, token: String) async -> Int? {
        let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/actions/jobs/\(jobId)/logs")!
        var req = URLRequest(url: url)
        req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        guard let (data, _) = try? await URLSession.shared.data(for: req) else { return nil }
        return data.count
    }
}
