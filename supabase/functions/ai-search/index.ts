// ============================================================
// AI 搜片助手 — Supabase Edge Function
// 部署: Supabase Dashboard → Edge Functions → New Function → 粘贴此文件 → Deploy
// 密钥: Edge Functions → Secrets → 添加 ANTHROPIC_API_KEY (从 console.anthropic.com 获取)
// 仅管理员可用：用 x-login-token 验 sessions + user_accounts.is_admin
// ============================================================

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const ANTHROPIC_API_KEY = Deno.env.get("ANTHROPIC_API_KEY") || "";
const MODEL = Deno.env.get("AI_MODEL") || "claude-haiku-4-5-20251001";

const SYSTEM_PROMPT = `你是 VideoDB 视频库的 AI 搜片助手，只服务网站管理员。用简体中文回答，简短直接。

你有一个 search_videos 工具可以搜索视频库。用户会用自然语言描述想找的视频，你要理解意图并调用工具：
- "找周星驰的电影" → query="周星驰"
- "最近一周播放量最高的" → sort="views", order="desc", days=7
- "找点搞笑的" → query="搞笑 喜剧"
- "有直链的" → has_mp4=true

调用工具后，根据返回结果给管理员一个简明摘要（标题、作者、播放量），不要编造不存在的视频。
如果搜不到，直说搜不到，建议换关键词。`;

const TOOLS = [
  {
    name: "search_videos",
    description: "在视频库中搜索视频，返回匹配的视频列表",
    input_schema: {
      type: "object",
      properties: {
        query: { type: "string", description: "搜索关键词（标题/作者/标签），多个词用空格分隔" },
        sort: { type: "string", enum: ["latest", "views"], description: "排序：latest=最新，views=播放量" },
        days: { type: "number", description: "只看最近 N 天的视频，不填则不限" },
        has_mp4: { type: "boolean", description: "只要有 MP4 直链可播放的" },
        limit: { type: "number", description: "返回条数，默认 10，最多 20" },
      },
      required: ["query"],
    },
  },
];

async function searchVideos(supabase: any, args: any) {
  const limit = Math.min(Math.max(args.limit || 10, 1), 20);
  let q = supabase
    .from("videos")
    .select("video_id,title,author,thumbnail_url,duration,views,created_at,has_mp4,source_section")
    .eq("removed", false);

  if (args.query) {
    const terms = String(args.query).split(/\s+/).filter(Boolean).slice(0, 5);
    // 多关键词 OR 搜索标题/作者
    const ors = terms
      .map((t: string) => `title.ilike.%${t}%,author.ilike.%${t}%`)
      .join(",");
    q = q.or(ors);
  }
  if (args.has_mp4) q = q.eq("has_mp4", true);
  if (args.days) {
    const since = new Date(Date.now() - args.days * 86400000).toISOString();
    q = q.gte("created_at", since);
  }
  if (args.sort === "views") q = q.order("views", { ascending: false });
  else q = q.order("created_at", { ascending: false });

  q = q.limit(limit);
  const { data, error } = await q;
  if (error) return { error: error.message };
  return { videos: data || [] };
}

async function callClaude(messages: any[], tools: any[]) {
  const resp = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-api-key": ANTHROPIC_API_KEY,
      "anthropic-version": "2023-06-01",
    },
    body: JSON.stringify({
      model: MODEL,
      max_tokens: 1024,
      system: SYSTEM_PROMPT,
      tools,
      messages,
    }),
  });
  if (!resp.ok) {
    const t = await resp.text();
    throw new Error(`Claude API ${resp.status}: ${t.slice(0, 200)}`);
  }
  return await resp.json();
}

serve(async (req: Request) => {
  // CORS
  if (req.method === "OPTIONS") {
    return new Response("ok", {
      headers: {
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
      },
    });
  }

  const cors = {
    "Access-Control-Allow-Origin": "*",
    "Content-Type": "application/json",
  };

  try {
    if (!ANTHROPIC_API_KEY) {
      return new Response(JSON.stringify({ ok: false, message: "服务端未配置 ANTHROPIC_API_KEY" }), { status: 500, headers: cors });
    }

    const body = await req.json();
    const p_token = body.p_token || "";
    const userMessages = body.messages || [];
    if (!p_token || !Array.isArray(userMessages) || !userMessages.length) {
      return new Response(JSON.stringify({ ok: false, message: "参数缺失" }), { status: 400, headers: cors });
    }

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL") || "",
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || ""
    );

    // 管理员鉴权：sessions 有效 token + user_accounts.is_admin 地面真相
    const { data: sess } = await supabase
      .from("sessions")
      .select("username")
      .eq("token", p_token)
      .gt("expires_at", new Date().toISOString())
      .maybeSingle();
    const { data: ua } = sess
      ? await supabase.from("user_accounts").select("is_admin").eq("username", sess.username).maybeSingle()
      : { data: null };
    if (!sess || !ua?.is_admin) {
      return new Response(JSON.stringify({ ok: false, message: "仅管理员可用" }), { status: 403, headers: cors });
    }

    // 只保留最近 10 轮对话，防 token 爆炸
    const messages = userMessages.slice(-20).map((m: any) => ({
      role: m.role === "assistant" ? "assistant" : "user",
      content: String(m.content || "").slice(0, 2000),
    }));

    // 第一轮：Claude 决定是否调工具
    let claudeResp = await callClaude(messages, TOOLS);
    let videos: any[] = [];

    // 处理 tool_use（最多 3 轮）
    for (let round = 0; round < 3; round++) {
      const toolUses = (claudeResp.content || []).filter((b: any) => b.type === "tool_use");
      if (!toolUses.length) break;

      const toolResults = [];
      for (const tu of toolUses) {
        if (tu.name === "search_videos") {
          const r = await searchVideos(supabase, tu.input || {});
          if (r.videos) videos = videos.concat(r.videos);
          toolResults.push({ type: "tool_result", tool_use_id: tu.id, content: JSON.stringify(r).slice(0, 8000) });
        } else {
          toolResults.push({ type: "tool_result", tool_use_id: tu.id, content: JSON.stringify({ error: "未知工具" }) });
        }
      }
      messages.push({ role: "assistant", content: claudeResp.content });
      messages.push({ role: "user", content: toolResults });
      claudeResp = await callClaude(messages, TOOLS);
    }

    const text = (claudeResp.content || [])
      .filter((b: any) => b.type === "text")
      .map((b: any) => b.text)
      .join("\n");

    // 去重视频
    const seen = new Set();
    videos = videos.filter((v) => {
      if (seen.has(v.video_id)) return false;
      seen.add(v.video_id);
      return true;
    }).slice(0, 20);

    return new Response(JSON.stringify({ ok: true, reply: text, videos }), { headers: cors });
  } catch (e) {
    return new Response(JSON.stringify({ ok: false, message: "AI 服务异常: " + (e as Error).message }), { status: 500, headers: cors });
  }
});
