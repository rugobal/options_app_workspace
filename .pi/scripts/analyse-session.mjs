// Per-session cost / tool / read aggregation for evaluating the assess -> route
// pipeline. Usage: node .pi/scripts/analyse-session.mjs <session.jsonl>
// Run from the workspace root so read paths print relative to it.
//
// "SPEND BEFORE USER TURN" attributes cost to each later user message: the first
// user message is the task, so every later one is an intervention. Classify each
// from USER MSGS (instruction vs correction); the spend before the first
// correction is the misdirection budget to compare runs by.
import { readFileSync } from "node:fs";
const f = process.argv[2];
if (!f) {
  console.error("usage: node analyse-session.mjs <session.jsonl>");
  process.exit(2);
}
const recs = readFileSync(f, "utf8").split("\n").filter(Boolean)
  .map(l => { try { return JSON.parse(l); } catch { return null; } }).filter(Boolean);

const roles = new Map();
let cost = 0, inp = 0, out = 0, cacheRead = 0, cacheWrite = 0;
const byModel = new Map(), toolCounts = new Map(), readCounts = new Map();
const readOrder = [], userMsgs = [], assistantTexts = [], userTurns = [];
let calls = 0, tools = 0;

for (const r of recs) {
  if (r.type !== "message") continue;
  const m = r.message; const role = m.role;
  roles.set(role, (roles.get(role) ?? 0) + 1);
  const parts = Array.isArray(m.content) ? m.content : [];
  if (role === "assistant") {
    const u = m.usage;
    if (u) {
      calls++;
      cost += u.cost?.total ?? 0; inp += u.input ?? 0; out += u.output ?? 0;
      cacheRead += u.cacheRead ?? 0; cacheWrite += u.cacheWrite ?? 0;
      const k = `${m.provider}/${m.model}`;
      const b = byModel.get(k) ?? { cost: 0, inp: 0, out: 0, cr: 0, cw: 0, n: 0 };
      b.cost += u.cost?.total ?? 0; b.inp += u.input ?? 0; b.out += u.output ?? 0;
      b.cr += u.cacheRead ?? 0; b.cw += u.cacheWrite ?? 0; b.n++;
      byModel.set(k, b);
    }
    for (const p of parts) {
      if (p.type === "text" && p.text) assistantTexts.push(p.text);
      if (typeof p.type === "string" && /tool/i.test(p.type) && (p.name || p.toolName)) {
        const name = p.name ?? p.toolName;
        tools++;
        toolCounts.set(name, (toolCounts.get(name) ?? 0) + 1);
        const a = p.arguments ?? p.input ?? {};
        if (name === "read" && a.path) {
          const short = a.path.replace(`${process.cwd()}/`, "");
          readCounts.set(short, (readCounts.get(short) ?? 0) + 1);
          readOrder.push(short);
        }
      }
    }
  }
  if (role === "user") {
    const t = parts.filter(p => p.type === "text").map(p => p.text).join("\n");
    if (t) {
      userMsgs.push(t);
      userTurns.push({ cost, calls, tools });
    }
  }
}

console.log("FILE:", f.split("/").pop().slice(0, 40));
console.log("ROLES:", JSON.stringify([...roles.entries()]));
console.log(`COST $${cost.toFixed(3)} | input=${inp} output=${out} cacheRead=${cacheRead} cacheWrite=${cacheWrite}`);
for (const [k, v] of byModel) console.log(`   ${k}  $${v.cost.toFixed(3)}  in=${v.inp} out=${v.out} cacheRead=${v.cr} cacheWrite=${v.cw} calls=${v.n}`);
console.log("TOOLS:", JSON.stringify([...toolCounts.entries()].sort((a, b) => b[1] - a[1])));
console.log(`READS: ${readOrder.length} total, ${readCounts.size} distinct`);
console.log("TOP RE-READS:", JSON.stringify([...readCounts.entries()].filter(e => e[1] > 1).sort((a, b) => b[1] - a[1]).slice(0, 10)));
console.log("FIRST 18 READS:", JSON.stringify(readOrder.slice(0, 18)));
console.log("USER MSGS:", userMsgs.length);
userMsgs.forEach((t, i) => console.log(`  [u${i}] len=${t.length} :: ${t.slice(0, 220).replace(/\n/g, " ")}`));
console.log("SPEND BEFORE USER TURN (u1+ are interventions):");
userTurns.forEach((s, i) => console.log(`  [u${i}] $${s.cost.toFixed(3)} (${(cost ? (100 * s.cost) / cost : 0).toFixed(1)}%)  calls=${s.calls} tools=${s.tools}`));
console.log("LAST ASSISTANT TEXT len:", (assistantTexts.at(-1) ?? "").length);
console.log("LAST ASSISTANT TEXT head:", (assistantTexts.at(-1) ?? "").slice(0, 400).replace(/\n/g, " "));
