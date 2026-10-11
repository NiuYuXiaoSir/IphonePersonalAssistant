// 一次很土的自检：把注释和字符串去掉之后数括号。
//
// 没有 Mac、本地没有 swiftc，编译只能靠 CI；而 CI 一轮要等一分钟以上。
// 这个脚本用来在推之前先接住「多了一个右花括号」这一类结构性错误
// （这个仓库真被它坑过一次）。它**不能**替代编译：类型错误、API 用法它都看不出来。
//
// 用法：node tools/check-swift-braces.mjs ios/IPhoneAssistant/*.swift
import { readFileSync } from "node:fs";

const BACKSLASH = String.fromCharCode(92);

function strip(src) {
  let out = "";
  let i = 0;
  let inLine = false;
  let inBlock = false;
  let inString = false;
  let inMulti = false;
  // 插值 \( ) 里是代码，这里不单独处理：本项目的字符串里没有嵌多行表达式
  while (i < src.length) {
    const c = src[i];
    const n = src[i + 1];
    if (inLine) {
      if (c === "\n") { inLine = false; out += c; }
      i += 1;
      continue;
    }
    if (inBlock) {
      if (c === "*" && n === "/") { inBlock = false; i += 2; continue; }
      i += 1;
      continue;
    }
    if (inMulti) {
      if (src.slice(i, i + 3) === '"""') { inMulti = false; i += 3; continue; }
      i += 1;
      continue;
    }
    if (inString) {
      if (c === BACKSLASH) { i += 2; continue; }
      if (c === '"') { inString = false; }
      i += 1;
      continue;
    }
    if (c === "/" && n === "/") { inLine = true; i += 2; continue; }
    if (c === "/" && n === "*") { inBlock = true; i += 2; continue; }
    if (src.slice(i, i + 3) === '"""') { inMulti = true; i += 3; continue; }
    if (c === '"') { inString = true; i += 1; continue; }
    out += c;
    i += 1;
  }
  return out;
}

let bad = 0;
for (const file of process.argv.slice(2)) {
  const code = strip(readFileSync(file, "utf8"));
  const count = (ch) => [...code].filter((c) => c === ch).length;
  const braces = count("{") - count("}");
  const parens = count("(") - count(")");
  const brackets = count("[") - count("]");
  const ok = braces === 0 && parens === 0 && brackets === 0;
  if (!ok) bad += 1;
  console.log(`${ok ? "✓" : "✗"} ${file}  {} ${braces}  () ${parens}  [] ${brackets}`);
}
process.exit(bad === 0 ? 0 : 1);
