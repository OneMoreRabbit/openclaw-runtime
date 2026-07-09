#!/usr/bin/env node
// normalize-plugin-manifest.js — r8.1 bake-time manifest normalisation.
//
// npm-published openclaw plugins declare SOURCE-form specifiers in their
// package.json `openclaw` block (e.g. extensions: ["./index.ts"],
// channel.persistedAuthState.specifier: "./auth-presence"). The runtime's
// own installer bridges those via an alias table in its installed-plugin
// manifest; a directory-scanned BUNDLED record has no alias table, so any
// source-form specifier fails ("plugin module path escapes plugin root or
// fails alias checks") at channel start.
//
// This script rewrites every relative specifier in the `openclaw` block to
// a plain in-root path that resolves against the BUILT files, so no alias
// layer is needed. Rules, per specifier "./p":
//   1. keep as-is if it already resolves to a real file (and isn't a
//      TypeScript source) — e.g. "./dist/setup-entry.js";
//   2. else try, in order: p.js, p/index.js, dist/p.js, dist/p/index.js
//      (with any .ts/.tsx/.mts extension stripped first);
//   3. no candidate exists -> exit 1 and FAIL THE BUILD. An upstream
//      renaming its built files must break the bake, not a channel start.
//
// Usage: node normalize-plugin-manifest.js <plugin-root>

"use strict";
const fs = require("fs");
const path = require("path");

const root = process.argv[2];
if (!root) {
  console.error("usage: normalize-plugin-manifest.js <plugin-root>");
  process.exit(2);
}
const pkgPath = path.join(root, "package.json");
const pkg = JSON.parse(fs.readFileSync(pkgPath, "utf8"));
if (!pkg.openclaw || typeof pkg.openclaw !== "object") {
  console.log(`normalize-plugin-manifest: no openclaw block in ${pkgPath}; nothing to do`);
  process.exit(0);
}

const TS_EXT = /\.(ts|tsx|mts|cts)$/;

function isFile(rel) {
  try {
    return fs.statSync(path.join(root, rel)).isFile();
  } catch {
    return false;
  }
}

function resolveSpecifier(spec) {
  const p = spec.replace(/^\.\//, "");
  if (!TS_EXT.test(p) && isFile(p)) return spec;            // already built-form
  const base = p.replace(TS_EXT, "");
  const candidates = [
    `${base}.js`,
    `${base}/index.js`,
    `dist/${base}.js`,
    `dist/${base}/index.js`,
  ];
  for (const c of candidates) {
    if (isFile(c)) return `./${c}`;
  }
  return null;
}

const rewritten = [];
const unresolved = [];

function walk(node, keyPath) {
  if (Array.isArray(node)) {
    node.forEach((v, i) => {
      const r = visit(v, `${keyPath}[${i}]`);
      if (r !== undefined) node[i] = r;
    });
  } else if (node && typeof node === "object") {
    for (const k of Object.keys(node)) {
      const r = visit(node[k], `${keyPath}.${k}`);
      if (r !== undefined) node[k] = r;
    }
  }
}

function visit(value, keyPath) {
  if (typeof value === "string") {
    if (!value.startsWith("./")) return undefined;           // not a specifier
    const resolved = resolveSpecifier(value);
    if (resolved === null) {
      unresolved.push(`${keyPath}: ${value}`);
      return undefined;
    }
    if (resolved !== value) rewritten.push(`${keyPath}: ${value} -> ${resolved}`);
    return resolved;
  }
  walk(value, keyPath);
  return undefined;
}

walk(pkg.openclaw, "openclaw");

if (unresolved.length) {
  console.error("normalize-plugin-manifest: UNRESOLVED specifiers (no built file found):");
  for (const u of unresolved) console.error(`  ${u}`);
  console.error("The upstream package layout has changed — reconcile the bake step.");
  process.exit(1);
}

fs.writeFileSync(pkgPath, JSON.stringify(pkg, null, 2) + "\n", "utf8");
if (rewritten.length) {
  console.log(`normalize-plugin-manifest: ${root}`);
  for (const r of rewritten) console.log(`  ${r}`);
} else {
  console.log(`normalize-plugin-manifest: ${root} — all specifiers already built-form`);
}
