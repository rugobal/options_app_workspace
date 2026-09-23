import { readFileSync } from "node:fs";
const recs = readFileSync(process.argv[2], "utf8").split("\n").filter(Boolean)
  .map(l => { try { return JSON.parse(l); } catch { return null; } }).filter(Boolean);
let last = "";
for (const r of recs) {
  if (r.type !== "message" || r.message?.role !== "assistant") continue;
  const parts = Array.isArray(r.message.content) ? r.message.content : [];
  for (const p of parts) if (p.type === "text" && p.text?.includes("ASSESS-DOSSIER")) last = p.text;
}
// print everything except the Exhibits code bodies
const out = last.replace(/```[\s\S]*?```/g, "```[CODE EXHIBIT]```");
console.log("DOSSIER CHARS:", last.length, "| lines:", last.split("\n").length);
console.log(out);
