// ============================================================
// AI 搜片助手 — Supabase Edge Function（Google Gemini 免费版）
// 部署: Supabase Dashboard → Edge Functions → New Function → 粘贴此文件 → Deploy
// 密钥: Edge Functions → Secrets → 添加 GEMINI_API_KEY
//       (去 https://aistudio.google.com 免费获取，不用绑卡)
// 仅管理员可用：用 x-login-token 验 sessions + user_accounts.is_admin
// ============================================================

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const GEMINI_API_KEY = Deno.env.get("GEMINI_API_KEY") || "";
const MODEL = Deno.env.get("AI_MODEL") || "gemini-3.8-flash";

const SYSTEM_PROMPT = `你是视频库搜片助手。用简体中文，简短回答。
你有 search_videos 工具。理解用户意图后调用一次工具，然后用返回结果给 1-2 句摘要。不要编造视频，搜不到就直说。意图示例：
"找周星驰的电影"→query="周星驰"；"最近一周播放量最高"→sort="views",days=7；"找搞笑的"→query="搞笑 喜剧"；"有直链的"→has_mp4=true`;

const FUNCTION_DECL = {
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

async function callGemini(contents: any[]) {
  const url = `https://generativelanguage.googleapis.com/v1beta/models/${MODEL}:generateContent?key=${GEMINI_API_KEY}`;
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), 25000); // 25秒超时，失败就直说
  try {
    const resp = await fetch(url, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        system_instruction: { parts: [{ text: SYSTEM_PROMPT }] },
        tools: [{ function_declarations: [FUNCTION_DECL] }],
        contents,
      }),
      signal: ctrl.signal,
    });
    if (!resp.ok) {
      const t = await resp.text();
      if (resp.status === 503 || resp.status === 429 || /high demand|UNAVAILABLE/i.test(t)) {
        throw new Error("Google 免费版当前过载，请过几分钟再试一次");
      }
      throw new Error(`Gemini API ${resp.status}: ${t.slice(0, 300)}`);
    }
    return await resp.json();
  } finally {
    clearTimeout(timer);
  }
}

function toGeminiContents(messages: any[]) {
  // [{role:'user'|'assistant', content:'...'}] → Gemini contents
  return messages.map((m: any) => ({
    role: m.role === "assistant" ? "model" : "user",
    parts: [{ text: String(m.content || "") }],
  }));
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
    if (!GEMINI_API_KEY) {
      return new Response(JSON.stringify({ ok: false, message: "no_key:服务端未配置 GEMINI_API_KEY" }), { status: 500, headers: cors });
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

    const messages = userMessages.slice(-6).map((m: any) => ({
      role: m.role === "assistant" ? "assistant" : "user",
      content: String(m.content || "").slice(0, 500),
    }));

    let contents = toGeminiContents(messages);
    let videos: any[] = [];
    let replyText = "";

    // 只做一轮工具调用：理解意图→查库→总结，一气呵成
    for (let round = 0; round < 1; round++) {
      const gResp = await callGemini(contents);
      const cand = (gResp.candidates || [])[0];
      const parts = (cand && cand.content && cand.content.parts) || [];

      const fnCalls = parts.filter((p: any) => p.functionCall);
      // 收集纯文本
      for (const p of parts) {
        if (p.text) replyText += p.text;
      }

      if (!fnCalls.length) break;

      // 把模型这轮输出（含 functionCall）追加进 contents
      contents.push({ role: "model", parts });

      const fnRespParts = [];
      for (const p of fnCalls) {
        const fc = p.functionCall;
        let result: any = { error: "未知工具" };
        if (fc.name === "search_videos") {
          result = await searchVideos(supabase, fc.args || {});
          if (result.videos) videos = videos.concat(result.videos);
        }
        fnRespParts.push({
          functionResponse: { name: fc.name, response: { result: JSON.stringify(result).slice(0, 8000) } },
        });
      }
      contents.push({ role: "user", parts: fnRespParts });
      replyText = ""; // 有工具调用时，最终回复以最后一轮文本为准
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
