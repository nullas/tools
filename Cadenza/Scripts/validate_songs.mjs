#!/usr/bin/env node
// Validates the song notation in Resources/songs.json and courses.json.
// Mirrors NotationParser.swift: tokens are separated by whitespace, "|" marks a bar
// (checked here, ignored by the app), "r" is a rest, "+" joins chord notes, and
// ":<beats>" sets a duration that carries over to following tokens.
//
// Usage: node Scripts/validate_songs.mjs
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const root = join(dirname(fileURLToPath(import.meta.url)), "..", "Cadenza", "Resources");
const LETTERS = "CDEFGAB";
const SEMIS = [0, 2, 4, 5, 7, 9, 11];

function parsePitch(tok) {
  const m = /^([A-Ga-g])([#b]*)(-?\d+)$/.exec(tok);
  if (!m) return null;
  const li = LETTERS.indexOf(m[1].toUpperCase());
  let acc = 0;
  for (const c of m[2]) acc += c === "#" ? 1 : -1;
  const midi = (Number(m[3]) + 1) * 12 + SEMIS[li] + acc;
  return midi >= 0 && midi <= 127 ? midi : null;
}

function parseHand(text) {
  const bars = [0];
  let t = 0, last = 1, notes = 0;
  for (const raw of (text ?? "").split(/\s+/).filter(Boolean)) {
    if (raw === "|") { bars.push(0); continue; }
    const [head, dur] = raw.split(":");
    if (dur !== undefined) {
      const d = Number(dur);
      if (!(d > 0)) throw new Error(`bad duration in "${raw}"`);
      last = d;
    }
    if (head !== "r") {
      for (const p of head.split("+")) {
        if (parsePitch(p) === null) throw new Error(`bad pitch "${p}" in "${raw}"`);
        notes++;
      }
    }
    t += last;
    bars[bars.length - 1] += last;
  }
  return { length: t, bars: text?.trim() ? bars : [], notes };
}

function check(item, label) {
  const errors = [];
  const bpb = item.beatsPerBar ?? 4;
  const pickup = item.pickup ?? 0;
  const hands = {};
  for (const h of ["right", "left"]) {
    if (!item[h]) continue;
    try {
      const r = parseHand(item[h]);
      hands[h] = r;
      r.bars.forEach((len, i) => {
        const isFirst = i === 0, isLast = i === r.bars.length - 1;
        let expected = bpb;
        if (pickup > 0 && isFirst) expected = pickup;
        else if (pickup > 0 && isLast) expected = bpb - pickup;
        const ok = Math.abs(len - expected) < 1e-9 || (isLast && Math.abs(len - bpb) < 1e-9);
        if (!ok) errors.push(`${h} bar ${i + 1}: ${len} beats, expected ${expected}`);
      });
    } catch (e) {
      errors.push(`${h}: ${e.message}`);
    }
  }
  if (hands.right && hands.left && Math.abs(hands.right.length - hands.left.length) > 1e-9)
    errors.push(`hand lengths differ: right ${hands.right.length}, left ${hands.left.length}`);
  if (!hands.right && !hands.left) errors.push("no notes");
  const count = (hands.right?.notes ?? 0) + (hands.left?.notes ?? 0);
  const bars = Math.max(hands.right?.bars.length ?? 0, hands.left?.bars.length ?? 0);
  console.log(`${errors.length ? "✗" : "✓"} ${label.padEnd(44)} ${String(bars).padStart(3)} bars ${String(count).padStart(4)} notes`);
  errors.forEach((e) => console.log(`    ${e}`));
  return errors.length;
}

let failures = 0;
const songs = JSON.parse(readFileSync(join(root, "songs.json"), "utf8"));
const ids = new Set();
for (const s of songs) {
  if (ids.has(s.id)) { console.log(`✗ duplicate id ${s.id}`); failures++; }
  ids.add(s.id);
  failures += check(s, s.title);
}
const courses = JSON.parse(readFileSync(join(root, "courses.json"), "utf8"));
for (const c of courses) for (const l of c.lessons) failures += check(l, `${c.title} › ${l.title}`);

console.log(failures ? `\n${failures} problem(s) found` : "\nAll notation is valid.");
process.exit(failures ? 1 : 0);
