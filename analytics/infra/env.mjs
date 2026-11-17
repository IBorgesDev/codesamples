import { randomBytes } from "node:crypto";
import { chmodSync, existsSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const OWNER_ONLY = 0o600;

const infra = dirname(fileURLToPath(import.meta.url));
const target = join(infra, ".env");
const template = readFileSync(join(infra, ".env.example"), "utf8");
const current = existsSync(target) ? readFileSync(target, "utf8") : "";

const known = new Map();
for (const line of current.split(/\r?\n/)) {
  const match = line.match(/^([A-Z0-9_]+)=(.*)$/);
  if (match) {
    known.set(match[1], match[2]);
  }
}

const lines = [];
let added = 0;
for (const line of template.split(/\r?\n/)) {
  const match = line.match(/^([A-Z0-9_]+)=(.*)$/);
  if (!match) {
    if (line.trim() !== "") {
      lines.push(line);
    }

    continue;
  }

  const [, name, fallback] = match;
  if (known.has(name) && known.get(name) !== "") {
    lines.push(`${name}=${known.get(name)}`);
    continue;
  }

  lines.push(`${name}=${fallback !== "" ? fallback : randomBytes(24).toString("hex")}`);
  added += 1;
}

for (const [name, value] of known) {
  if (!lines.some((line) => line.startsWith(`${name}=`))) {
    lines.push(`${name}=${value}`);
  }
}

writeFileSync(target, `${lines.join("\n")}\n`, { mode: OWNER_ONLY });
chmodSync(target, OWNER_ONLY);
console.log(added > 0 ? `infra/.env: generated ${added} value(s)` : "infra/.env: up to date");
