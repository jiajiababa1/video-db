// ============================================================
// AI 搜片助手 — Supabase Edge Function（Groq 免费版）
// 部署: Supabase Dashboard → Edge Functions → 粘贴此文件 → Deploy
// 密钥: Secrets → 添加 GROQ_API_KEY
//       (去 https://console.groq.com 免费获取，不用绑卡)
// 仅管理员可用：验 sessions token + user_accounts.is_admin
// ============================================================

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const GROQ_API_KEY = Deno.env.get("GROQ_API_KEY") || "";
// 优先用的模型（按顺序），实际可用性看 key 的权限，函数会先查 /models 自动挑
const MODEL_PREFS = (Deno.env.get("AI_MODEL") || "openai/gpt-oss-20b,openai/gpt-oss-120b,qwen/qwen3.8-27b").split(",").map(s => s.trim()).filter(Boolean);

async function pickModel(): Promise<string> {
  try {
    const r = await fetch("https://api.groq.com/openai/v1/models", {
      headers: { "authorization": "Bearer " + GROQ_API_KEY },
    });
    if (!r.ok) return MODEL_PREFS[0];
    const j = await r.json();
    const ids: string[] = (j.data || []).map((m: any) => m.id).filter((id: string) =>
      !/whisper|tts|guard|compound/i.test(id));
    for (const pref of MODEL_PREFS) {
      if (ids.includes(pref)) return pref;
    }
    // 兜底：随便找个能对话的
    if (ids.length) return ids[0];
  } catch (e) { /* 忽略，用默认 */ }
  return MODEL_PREFS[0];
}

const SYSTEM_PROMPT = `你是视频库搜片助手。用简体中文，简短回答。
你有 search_videos 工具。理解用户意图后调用一次工具，然后用返回结果给 1-2 句摘要。不要编造视频，搜不到就直说。意图示例：
"找周星驰的电影"→query="周星驰"；"最近一周播放量最高"→sort="views",days=7；"找搞笑的"→query="搞笑 喜剧"；"有直链的"→has_mp4=true`;

const TOOL_DEF = {
  type: "function",
  function: {
    name: "search_videos",
    description: "在视频库中搜索视频，返回匹配的视频列表",
    parameters: {
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
};

async function searchVideos(supabase: any, args: any) {
  const limit = Math.min(Math.max(args.limit || 10, 1), 20);
  let q = supabase
    .from("videos")
    .select("video_id,title,author,thumbnail_url,duration,views,created_at,has_mp4,source_section")
    .eq("removed", false);

  if (args.query) {
    const terms = String(args.query).split(/\s+/).filter(Boolean).slice(0, 5);
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

async function callGroq(messages: any[], model: string) {
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), 25000);
  try {
    const resp = await fetch("https://api.groq.com/openai/v1/chat/completions", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "authorization": "Bearer " + GROQ_API_KEY,
      },
      body: JSON.stringify({
        model,
        messages: [{ role: "system", content: SYSTEM_PROMPT }, ...messages],
        tools: [TOOL_DEF],
        tool_choice: "auto",
        temperature: 0.3,
        max_tokens: 800,
      }),
      signal: ctrl.signal,
    });
    if (!resp.ok) {
      const t = await resp.text();
      if (resp.status === 429 || /rate_limit|capacity|overloaded/i.test(t)) {
        throw new Error("Groq 当前限流/过载，请稍后再试一次");
      }
      if (resp.status === 404 || /model_not_found|does not exist/i.test(t)) {
        throw new Error(`模型 ${model} 在你的 Groq 账号上不可用，去 console.groq.com 确认可用模型，或设 AI_MODEL 环境变量指定`);
      }
      throw new Error(`Groq API ${resp.status}: ${t.slice(0, 300)}`);
    }
    return await resp.json();
  } finally {
    clearTimeout(timer);
  }
}

serve(async (req: Request) => {
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
    if (!GROQ_API_KEY) {
      return new Response(JSON.stringify({ ok: false, message: "no_key:服务端未配置 GROQ_API_KEY" }), { status: 500, headers: cors });
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

    // 管理员鉴权
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

    // 只取最近 3 轮，保持快
    const messages = userMessages.slice(-6).map((m: any) => ({
      role: m.role === "assistant" ? "assistant" : "user",
      content: String(m.content || "").slice(0, 500),
    }));

    let videos: any[] = [];
    let replyText = "";

    // 先查这个 key 能用哪些模型，自动挑一个
    const model = await pickModel();

    // 第一轮：理解意图，可能带工具调用
    const gResp = await callGroq(messages, model);
    const msg = (gResp.choices || [])[0]?.message || {};
    const toolCalls = msg.tool_calls || [];
    if (msg.content) replyText += msg.content;

    // 第二轮：如果调了工具，执行并把结果喂回去拿总结
    if (toolCalls.length) {
      const followMsgs = [...messages, { role: "assistant", content: msg.content || "", tool_calls: toolCalls }];
      for (const tc of toolCalls.slice(0, 2)) {
        let result: any = { error: "未知工具" };
        if (tc.function?.name === "search_videos") {
          try {
            const args = JSON.parse(tc.function.arguments || "{}");
            result = await searchVideos(supabase, args);
          } catch (e) { result = { error: "参数解析失败" }; }
          if (result.videos) videos = videos.concat(result.videos);
        }
        followMsgs.push({
          role: "tool",
          tool_call_id: tc.id,
          content: JSON.stringify(result).slice(0, 6000),
        });
      }
      const gResp2 = await callGroq(followMsgs, model);
      const msg2 = (gResp2.choices || [])[0]?.message || {};
      if (msg2.content) replyText = msg2.content;
    }

    const seen = new Set();
    videos = videos.filter((v) => {
      if (seen.has(v.video_id)) return false;
      seen.add(v.video_id);
      return true;
    }).slice(0, 20);

    return new Response(JSON.stringify({ ok: true, reply: replyText, videos }), { headers: cors });
  } catch (e) {
    return new Response(JSON.stringify({ ok: false, message: "AI 服务异常: " + (e as Error).message }), { status: 500, headers: cors });
  }
});
