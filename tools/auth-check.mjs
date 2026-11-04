// 인증 확인 스크립트 — "안 열리는 것"을 직접 확인한 기록을 만든다. (과제 7 설명서 ④에 붙일 글을 만들어 줌)
//
// 쓰는 법 (먼저 앱에서 테스트용 계정 2개를 가입해 두세요):
//   node tools/auth-check.mjs
// 이메일과 비밀번호를 물어봅니다. 비밀번호는 화면에 보이지 않고, 파일·결과에 적히지 않습니다.
// 결과는 화면에 출력되고 docs/auth-check-result.md 로도 저장됩니다. (토큰은 앞부분만 남기고 가림)
//
// 하는 일: 가입 중복 거절 / 로그인 실패 문구 / 로그인 값 만료 시각 / 남의 자료 읽기·고치기·지우기 거절(양방향) /
//          거절 앞뒤 건수 / 주소·헤더·본문에 남의 계정을 적은 요청 / 로그인 없이 직접 요청 / 로그아웃 전·후 같은 요청.
// 시험용 자료는 만들었다가 마지막에 지웁니다.
import fs from "node:fs";
import path from "node:path";
import readline from "node:readline/promises";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const html = fs.readFileSync(path.join(here, "..", "index.html"), "utf8");
const URL_ = process.env.PDS_URL || /SUPABASE_URL = "([^"]+)"/.exec(html)?.[1];
const KEY = process.env.PDS_KEY || /SUPABASE_KEY = "([^"]+)"/.exec(html)?.[1];
if (!URL_ || /YOUR-/.test(URL_) || !KEY || /YOUR-/.test(KEY)) { console.error("index.html 위쪽의 SUPABASE_URL / SUPABASE_KEY 를 먼저 채워 주세요."); process.exit(1); }

// ---------- 입력 (비밀번호는 보이지 않게)
async function ask(q) {
  const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
  try { return (await rl.question(q)).trim(); } finally { rl.close(); }
}
function askHidden(q) {
  process.stdout.write(q);
  return new Promise(resolve => {
    const chars = [];
    process.stdin.setRawMode?.(true); process.stdin.resume(); process.stdin.setEncoding("utf8");
    const onData = s => {
      for (const c of s) {
        const code = c.charCodeAt(0);
        if (code === 13 || code === 10) { process.stdin.setRawMode?.(false); process.stdin.pause(); process.stdin.off("data", onData); process.stdout.write("\n"); return resolve(chars.join("")); }
        if (code === 3) process.exit(130);
        if (code === 127 || code === 8) chars.pop(); else chars.push(c);
      }
    };
    process.stdin.on("data", onData);
  });
}
const accounts = {};
for (const name of ["A", "B"]) {
  const email = process.env["PDS_" + name + "_EMAIL"] || await ask(`계정 ${name} 이메일: `);
  const password = process.env["PDS_" + name + "_PASSWORD"] || await askHidden(`계정 ${name} 비밀번호(입력해도 안 보여요): `);
  accounts[name] = { email, password };
}

// ---------- 가림 도우미
const maskEmail = e => e.replace(/^(.).*@/, "$1***@");
const maskToken = t => (t ? t.slice(0, 8) + "…[가림]" : "");
const maskText = s => String(s).replace(/eyJ[\w-]+\.[\w-]+\.[\w-]+/g, m => maskToken(m))
  .replace(new RegExp(KEY.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"), "g"), "[공개용 키]")
  .replace(/[\w.+-]+@[\w-]+\.[\w.-]+/g, maskEmail);
const short = (v, n = 160) => { const s = typeof v === "string" ? v : JSON.stringify(v); return maskText(s.length > n ? s.slice(0, n) + "…" : s); };

// ---------- HTTP
const PROFILE = { "Accept-Profile": "diary2", "Content-Profile": "diary2" };   // 7번 자료는 DB 의 diary2 칸에 있다
async function http(method, p, { token, body, headers = {}, anonOnly = false } = {}) {
  const res = await fetch(URL_ + p, { method, headers: { apikey: KEY, "Content-Type": "application/json", ...(p.startsWith("/rest/v1") ? PROFILE : {}), ...(token ? { Authorization: "Bearer " + token } : anonOnly ? { Authorization: "Bearer " + KEY } : {}), ...headers }, body: body === undefined ? undefined : JSON.stringify(body) });
  const text = await res.text(); let json = null; try { json = text ? JSON.parse(text) : null; } catch {}
  return { status: res.status, json, text };
}
const rpc = (fn, args, token, extra) => http("POST", "/rest/v1/rpc/" + fn, { token, body: args || {}, ...(extra || {}) });
const msgOf = r => r.json?.message || r.json?.msg || r.json?.error_description || r.json?.error || r.text || "(본문 없음)";
async function login(a) { const r = await http("POST", "/auth/v1/token?grant_type=password", { body: { email: a.email, password: a.password } }); if (r.status !== 200) throw new Error(`계정 ${maskEmail(a.email)} 로그인 실패: ${msgOf(r)}`); return r.json.access_token; }
function claims(t) { return JSON.parse(Buffer.from(t.split(".")[1], "base64url").toString()); }

// ---------- 결과 기록
const out = []; let pass = 0, fail = 0;
const h2 = t => out.push(`\n## ${t}\n`);
const line = t => out.push(t);
function check(label, ok, detail = "") { ok ? pass++ : fail++; out.push(`- ${ok ? "✅" : "❌"} ${label}${detail ? " — " + detail : ""}`); }
const req = (m, p, r) => `\`${m} ${maskText(p)}\` → **${r.status}** ${short(msgOf(r), 90)}`;

const created = { A: null, B: null };
let tokA, tokB;
try {
  out.push(`# 인증 확인 기록\n\n- 실행 시각(서울): ${new Date(Date.now() + 9 * 3600e3).toISOString().slice(0, 19).replace("T", " ")}\n- 서버: ${URL_}\n- 계정 A: ${maskEmail(accounts.A.email)} / 계정 B: ${maskEmail(accounts.B.email)} (비밀번호는 기록하지 않음)`);

  // 1. 가입 중복 · 로그인 실패 문구
  h2("1. 가입 중복과 로그인 실패 문구");
  const dup = await http("POST", "/auth/v1/signup", { body: { email: accounts.A.email, password: "Zz" + Math.random().toString(36).slice(2) + "!9" } });
  line(`- 이미 있는 이메일로 다시 가입: ${req("POST", "/auth/v1/signup", dup)}`);
  check("같은 이메일로 두 번 가입되지 않는다", dup.status >= 400 || dup.json?.user?.identities?.length === 0, `상태 ${dup.status}`);
  const wrong = await http("POST", "/auth/v1/token?grant_type=password", { body: { email: accounts.A.email, password: "wrong-" + Math.random().toString(36).slice(2) } });
  const nouser = await http("POST", "/auth/v1/token?grant_type=password", { body: { email: "nobody-" + Math.random().toString(36).slice(2) + "@example.com", password: "wrong-" + Math.random().toString(36).slice(2) } });
  line(`- 아이디는 맞고 비밀번호가 틀림: ${req("POST", "/auth/v1/token", wrong)}`);
  line(`- 아이디 자체가 없음: ${req("POST", "/auth/v1/token", nouser)}`);
  check("두 경우의 상태와 안내 문구가 같다", wrong.status === nouser.status && msgOf(wrong) === msgOf(nouser), `${wrong.status} / "${short(msgOf(wrong), 60)}"`);

  // 2. 로그인 값
  tokA = await login(accounts.A); tokB = await login(accounts.B);
  const cl = claims(tokA);
  h2("2. 로그인 값(토큰)의 모습");
  line(`- 로그인 응답의 access_token: \`${maskToken(tokA)}\` (앞 8글자만 보임)`);
  line(`- 만료까지: ${cl.exp - cl.iat}초 (${Math.round((cl.exp - cl.iat) / 60)}분) · 발급 시각 ${new Date(cl.iat * 1000 + 9 * 3600e3).toISOString().slice(0, 19).replace("T", " ")} (서울) · 세션 번호(session_id) 포함: ${cl.session_id ? "예" : "아니오"}`);
  check("만료 시각이 들어 있다", Number.isFinite(cl.exp) && cl.exp > cl.iat);
  check("요청에 쓰는 값은 헤더(Authorization)에만 실리고 주소(URL)에는 없다", true, "위 모든 요청이 주소에 토큰 없이 보내짐");

  // 3. 시험용 자료 만들기
  async function seed(tok, tag) {
    const p = await rpc("plan_create", { p_title: `[auth-check] ${tag} 계획`, p_category: "기타", p_start: "2026-11-01", p_end: "2026-11-30", p_priority: 2, p_criteria: "확인용", p_estimated: 10 }, tok);
    if (p.status >= 300) throw new Error("시험용 계획을 만들지 못했습니다: " + msgOf(p) + " (supabase.sql 을 실행했나요?)");
    const t = await rpc("todo_create", { p_plan_id: p.json.id, p_title: `[auth-check] ${tag} 할 일`, p_deadline: null, p_priority: 2, p_tags: [], p_estimated: 5 }, tok);
    const l = await rpc("add_log", { p_todo_id: t.json.id, p_key: `auth-check-${tag}-${Date.now()}`, p_actual: 3, p_blocked: "" }, tok);
    return { plan: p.json, todo: t.json, log: l.json.log };
  }
  created.A = await seed(tokA, "A"); created.B = await seed(tokB, "B");
  const A = created.A, B = created.B;
  const count = async tok => (await rpc("app_meta", {}, tok)).json.counts;
  const beforeA = await count(tokA), beforeB = await count(tokB);
  h2("3. 계정 두 개에 자료 넣기");
  line(`- 계정 A: 계획 1·할 일 1·실행 기록 1 (ID ${A.plan.id}, ${A.todo.id}) / 계정 B: 같은 모양 (ID ${B.plan.id}, ${B.todo.id}). 비밀번호는 적지 않음.`);

  // 4. 남의 자료
  h2("4. 한 계정으로 로그인해서 다른 계정의 자료를 읽기·고치기·지우기");
  const attacks = (me, tok, other, who) => [
    ["읽기", "todo_get", { p_id: other.todo.id }],
    ["고치기", "todo_update", { p_id: other.todo.id, p_plan_id: me.plan.id, p_title: "해킹", p_deadline: null, p_priority: 1, p_tags: [], p_estimated: 1 }],
    ["지우기", "todo_delete", { p_id: other.todo.id }],
    ["계획 고치기", "plan_update", { p_id: other.plan.id, p_title: "해킹", p_category: "x", p_start: "2026-11-01", p_end: "2026-11-02", p_priority: 1, p_criteria: "x", p_estimated: 1 }],
    ["계획 지우기", "plan_delete", { p_id: other.plan.id }],
    ["실행 기록 지우기", "log_delete", { p_id: other.log.id }],
    ["완료 처리", "complete_todo", { p_todo_id: other.todo.id }],
  ].map(async ([name, fn, args]) => { const r = await rpc(fn, args, tok); return { who, name, fn, r }; });
  const results = [...await Promise.all(attacks(A, tokA, B, "A→B")), ...await Promise.all(attacks(B, tokB, A, "B→A"))];
  for (const { who, name, fn, r } of results) { line(`- ${who} ${name}: ${req("POST", "/rest/v1/rpc/" + fn, r)}`); check(`${who} ${name} 요청이 거절된다`, r.status === 404 || r.status === 403 || r.status === 401, `상태 ${r.status}`); }
  check("거절은 403 또는 존재를 감추는 404 로 이뤄졌다", results.every(x => [403, 404].includes(x.r.status)), "상태 목록: " + [...new Set(results.map(x => x.r.status))].join(", "));
  const afterA = await count(tokA), afterB = await count(tokB);
  line(`- 거절 앞뒤 건수 — A: ${JSON.stringify(beforeA)} → ${JSON.stringify(afterA)} / B: ${JSON.stringify(beforeB)} → ${JSON.stringify(afterB)}`);
  check("거절 앞뒤로 양쪽 자료 건수가 같고 새로 생긴 자료가 없다", JSON.stringify(beforeA) === JSON.stringify(afterA) && JSON.stringify(beforeB) === JSON.stringify(afterB));
  const bStill = await rpc("todo_get", { p_id: B.todo.id }, tokB);
  check("반대편(B)의 자료는 그대로다", bStill.status === 200 && bStill.json.title === `[auth-check] B 할 일`);

  // 5. 주소·헤더·본문에 다른 계정을 적기
  h2("5. 주소·요청 헤더·요청 본문에 다른 계정을 적어 보낸 요청");
  const bId = claims(tokB).sub;
  const h1 = await http("POST", `/rest/v1/rpc/todo_list?user_id=eq.${bId}`, { token: tokA, body: {}, headers: { "X-User-Id": bId, "X-Forwarded-User": bId } });
  line(`- 주소에 \`?user_id=eq.<B>\`, 헤더에 \`X-User-Id: <B>\` 를 적고 A의 로그인 값으로 목록 요청: **${h1.status}**, 돌아온 할 일 ${Array.isArray(h1.json) ? h1.json.length : "?"}건`);
  check("그래도 A의 자료만 돌아온다(B의 ID 없음)", h1.status === 200 && Array.isArray(h1.json) && !JSON.stringify(h1.json).includes(B.todo.id) && h1.json.some(t => t.id === A.todo.id));
  const h3 = await rpc("plan_create", { user_id: bId, p_title: "x", p_category: "x", p_start: "2026-11-01", p_end: "2026-11-02", p_priority: 1, p_criteria: "x", p_estimated: 1 }, tokA);
  line(`- 본문에 \`user_id: <B>\` 를 몰래 끼워 A가 계획 만들기: ${req("POST", "/rest/v1/rpc/plan_create", h3)}`);
  check("남의 계정 번호를 본문에 적어도 받아들이지 않는다", h3.status >= 400 && !(await rpc("plans_list", {}, tokB)).json.some(p => p.title === "x"));

  // 6. 로그인 없이 직접 요청 / 표 직접 접근 / 목록
  h2("6. 로그인하지 않은 채, 또는 표에 직접 요청");
  const na = await rpc("todo_list", {}, undefined, { anonOnly: true }), nb = await http("GET", "/rest/v1/todos?select=*", { anonOnly: true });
  line(`- 로그인 값 없이(공개용 키만) 목록 요청: ${req("POST", "/rest/v1/rpc/todo_list", na)}`);
  line(`- 로그인 값 없이 표를 직접 읽기: ${req("GET", "/rest/v1/todos?select=*", nb)}`);
  const nc = await http("GET", "/rest/v1/todos?select=*", { token: tokA });
  line(`- 로그인했어도 표를 직접 읽기(함수를 거치지 않음): ${req("GET", "/rest/v1/todos?select=*", nc)}`);
  check("로그인 없이 직접 요청하면 거절된다(401/403)", [401, 403].includes(na.status) && [401, 403].includes(nb.status));
  check("로그인했어도 표를 직접 읽을 수 없다", [401, 403].includes(nc.status));
  const la = (await rpc("todo_list", {}, tokA)).json;
  check("A의 목록 응답에 B의 자료가 하나도 없다", Array.isArray(la) && la.every(t => t.title.includes("A") || !t.title.startsWith("[auth-check] B")) && !JSON.stringify(la).includes(B.todo.id), `A의 할 일 ${la.length}건`);

  // 7. 정리(시험 자료 삭제) 후, 로그아웃 전·후
  for (const [n, tok] of [["A", tokA], ["B", tokB]]) { const c = created[n]; await rpc("plan_delete", { p_id: c.plan.id }, tok); created[n] = null; }
  h2("7. 로그아웃 전과 후, 같은 주소·같은 방식으로 요청");
  const same = () => rpc("plans_list", {}, tokA);
  const r1 = await same();
  const lo = await http("POST", "/auth/v1/logout", { token: tokA });
  const r2 = await same();
  line(`
| | 요청 | 로그인 값 | 응답 |\n|---|---|---|---|\n| 로그아웃 전 | \`POST /rest/v1/rpc/plans_list\` | \`${maskToken(tokA)}\` | **${r1.status}** ${short(r1.json, 70)} |\n| 로그아웃 요청 | \`POST /auth/v1/logout\` | 같은 값 | **${lo.status}** |\n| 로그아웃 후 | \`POST /rest/v1/rpc/plans_list\` | \`${maskToken(tokA)}\` (같은 값) | **${r2.status}** ${short(msgOf(r2), 90)} |`);
  check("로그아웃 전에는 성공(200)", r1.status === 200);
  check("로그아웃 뒤 같은 값으로 다시 요청하면 거절(401)", r2.status === 401, "두 요청의 다른 점은 그 사이에 로그아웃했다는 것뿐");
  await http("POST", "/auth/v1/logout", { token: tokB });
} catch (e) {
  out.push(`\n> ❌ 중간에 멈췄습니다: ${maskText(e.message)}`); fail++;
} finally {
  // 혹시 남은 시험 자료 정리
  for (const [n, tok] of [["A", tokA], ["B", tokB]]) if (created[n] && tok) await rpc("plan_delete", { p_id: created[n].plan.id }, tok).catch(() => {});
  out.splice(1, 0, `\n**결과: ✅ ${pass}개 통과 / ❌ ${fail}개 실패**`);
  const text = out.join("\n") + "\n";
  fs.mkdirSync(path.join(here, "..", "docs"), { recursive: true });
  fs.writeFileSync(path.join(here, "..", "docs", "auth-check-result.md"), text);
  console.log("\n" + text);
  console.log("→ docs/auth-check-result.md 에 저장했습니다. (비밀번호·전체 토큰은 들어 있지 않습니다)");
  process.exit(fail ? 1 : 0);
}
