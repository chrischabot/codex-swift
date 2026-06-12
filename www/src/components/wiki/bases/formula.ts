// formula.ts — a tiny, SAFE expression evaluator for base formula columns
// (granite/Obsidian "formula property" parity). NO JS eval/Function: a hand
// rolled tokenizer + recursive-descent parser + tree-walker over a fixed
// grammar, so a formula can never reach the host environment.
//
// Grammar (precedence low→high):
//   ternary    ?:                     a ? b : c
//   or         ||
//   and        &&
//   equality   == != = (alias of ==)
//   compare    < <= > >=
//   add        + -                    (+ also concatenates when either side is a string)
//   mul        * / %
//   unary      - !
//   primary    number | "string" | true|false | ident | {bracketed ident} | func(args) | ( expr )
//
// Identifiers resolve to ROW VALUES via the supplied `scope` (a property/column
// reader). Unknown identifiers resolve to null. Functions are a fixed allow-list.

export type FormulaValue = number | string | boolean | null;

export type Scope = (name: string) => unknown;

// ── Tokenizer ────────────────────────────────────────────────────────────────

type Tok =
  | { t: "num"; v: number }
  | { t: "str"; v: string }
  | { t: "ident"; v: string }
  | { t: "op"; v: string }
  | { t: "eof" };

const OPS = ["<=", ">=", "==", "!=", "&&", "||", "(", ")", ",", "?", ":", "<", ">", "=", "+", "-", "*", "/", "%", "!"];

function tokenize(src: string): Tok[] {
  const out: Tok[] = [];
  let i = 0;
  const n = src.length;
  while (i < n) {
    const c = src[i];
    if (c === " " || c === "\t" || c === "\n" || c === "\r") {
      i++;
      continue;
    }
    if (c === '"' || c === "'") {
      const quote = c;
      let j = i + 1;
      let buf = "";
      while (j < n && src[j] !== quote) {
        if (src[j] === "\\" && j + 1 < n) {
          buf += src[j + 1];
          j += 2;
        } else {
          buf += src[j];
          j++;
        }
      }
      out.push({ t: "str", v: buf });
      i = j + 1;
      continue;
    }
    if (c === "{") {
      // Bracketed identifier: {key with spaces}
      const j = src.indexOf("}", i + 1);
      if (j === -1) throw new Error("unterminated { in formula");
      out.push({ t: "ident", v: src.slice(i + 1, j).trim() });
      i = j + 1;
      continue;
    }
    if (/[0-9]/.test(c) || (c === "." && /[0-9]/.test(src[i + 1] ?? ""))) {
      let j = i;
      while (j < n && /[0-9.]/.test(src[j]!)) j++;
      out.push({ t: "num", v: Number(src.slice(i, j)) });
      i = j;
      continue;
    }
    if (/[A-Za-z_]/.test(c)) {
      let j = i;
      while (j < n && /[A-Za-z0-9_.]/.test(src[j]!)) j++;
      out.push({ t: "ident", v: src.slice(i, j) });
      i = j;
      continue;
    }
    const two = src.slice(i, i + 2);
    if (OPS.includes(two)) {
      out.push({ t: "op", v: two });
      i += 2;
      continue;
    }
    if (OPS.includes(c)) {
      out.push({ t: "op", v: c });
      i++;
      continue;
    }
    throw new Error(`unexpected character '${c}' in formula`);
  }
  out.push({ t: "eof" });
  return out;
}

// ── Parser → AST ───────────────────────────────────────────────────────────

type Node =
  | { k: "lit"; v: FormulaValue }
  | { k: "ref"; name: string }
  | { k: "unary"; op: string; e: Node }
  | { k: "bin"; op: string; l: Node; r: Node }
  | { k: "tern"; c: Node; a: Node; b: Node }
  | { k: "call"; name: string; args: Node[] };

function parse(toks: Tok[]): Node {
  let p = 0;
  const peek = () => toks[p]!;
  const next = () => toks[p++]!;
  const eat = (v: string) => {
    const t = peek();
    if (t.t === "op" && t.v === v) {
      p++;
      return;
    }
    throw new Error(`expected '${v}' in formula`);
  };
  const isOp = (v: string) => {
    const t = peek();
    return t.t === "op" && t.v === v;
  };

  function parseExpr(): Node {
    return parseTernary();
  }
  function parseTernary(): Node {
    const c = parseOr();
    if (isOp("?")) {
      next();
      const a = parseExpr();
      eat(":");
      const b = parseExpr();
      return { k: "tern", c, a, b };
    }
    return c;
  }
  function parseBinLevel(ops: string[], down: () => Node): Node {
    let l = down();
    while (peek().t === "op" && ops.includes((peek() as { v: string }).v)) {
      const op = (next() as { v: string }).v;
      l = { k: "bin", op, l, r: down() };
    }
    return l;
  }
  const parseOr = () => parseBinLevel(["||"], parseAnd);
  const parseAnd = () => parseBinLevel(["&&"], parseEq);
  const parseEq = () => parseBinLevel(["==", "!=", "="], parseCmp);
  const parseCmp = () => parseBinLevel(["<", "<=", ">", ">="], parseAdd);
  const parseAdd = () => parseBinLevel(["+", "-"], parseMul);
  const parseMul = () => parseBinLevel(["*", "/", "%"], parseUnary);
  function parseUnary(): Node {
    if (isOp("-") || isOp("!")) {
      const op = (next() as { v: string }).v;
      return { k: "unary", op, e: parseUnary() };
    }
    return parsePrimary();
  }
  function parsePrimary(): Node {
    const t = peek();
    if (t.t === "num") {
      next();
      return { k: "lit", v: t.v };
    }
    if (t.t === "str") {
      next();
      return { k: "lit", v: t.v };
    }
    if (t.t === "ident") {
      next();
      if (t.v === "true") return { k: "lit", v: true };
      if (t.v === "false") return { k: "lit", v: false };
      if (t.v === "null") return { k: "lit", v: null };
      if (isOp("(")) {
        next();
        const args: Node[] = [];
        if (!isOp(")")) {
          args.push(parseExpr());
          while (isOp(",")) {
            next();
            args.push(parseExpr());
          }
        }
        eat(")");
        return { k: "call", name: t.v.toLowerCase(), args };
      }
      return { k: "ref", name: t.v };
    }
    if (isOp("(")) {
      next();
      const e = parseExpr();
      eat(")");
      return e;
    }
    throw new Error("unexpected token in formula");
  }

  const node = parseExpr();
  if (peek().t !== "eof") throw new Error("trailing tokens in formula");
  return node;
}

// ── Evaluator ────────────────────────────────────────────────────────────────

function toNum(v: FormulaValue): number {
  if (typeof v === "number") return v;
  if (typeof v === "boolean") return v ? 1 : 0;
  if (v === null) return NaN;
  const n = Number(v);
  return n;
}
function toStr(v: FormulaValue): string {
  if (v === null) return "";
  return String(v);
}
function truthy(v: FormulaValue): boolean {
  if (typeof v === "boolean") return v;
  if (typeof v === "number") return v !== 0 && !Number.isNaN(v);
  if (v === null) return false;
  return String(v).length > 0;
}

const FUNCS: Record<string, (args: FormulaValue[]) => FormulaValue> = {
  if: (a) => (truthy(a[0] ?? null) ? (a[1] ?? null) : (a[2] ?? null)),
  coalesce: (a) => a.find((x) => x !== null && x !== "" && !(typeof x === "number" && Number.isNaN(x))) ?? null,
  abs: (a) => Math.abs(toNum(a[0] ?? null)),
  round: (a) => {
    const f = 10 ** (a[1] !== undefined ? toNum(a[1]) : 0);
    return Math.round(toNum(a[0] ?? null) * f) / f;
  },
  floor: (a) => Math.floor(toNum(a[0] ?? null)),
  ceil: (a) => Math.ceil(toNum(a[0] ?? null)),
  min: (a) => Math.min(...a.map(toNum)),
  max: (a) => Math.max(...a.map(toNum)),
  number: (a) => toNum(a[0] ?? null),
  len: (a) => toStr(a[0] ?? null).length,
  lower: (a) => toStr(a[0] ?? null).toLowerCase(),
  upper: (a) => toStr(a[0] ?? null).toUpperCase(),
  trim: (a) => toStr(a[0] ?? null).trim(),
  concat: (a) => a.map(toStr).join(""),
  contains: (a) => toStr(a[0] ?? null).toLowerCase().includes(toStr(a[1] ?? null).toLowerCase()),
};

/** Coerce an arbitrary scope value into a FormulaValue (arrays → comma string).
 *  Functions and plain objects coerce to null — a hardening backstop so a scope
 *  that leaks a prototype member (e.g. `constructor`) can't surface a host
 *  function into the formula sandbox. */
function coerce(v: unknown): FormulaValue {
  if (v === null || v === undefined) return null;
  if (typeof v === "number" || typeof v === "boolean" || typeof v === "string") return v;
  if (Array.isArray(v)) return v.map((x) => String(x)).join(", ");
  return null;
}

function evalNode(node: Node, scope: Scope): FormulaValue {
  switch (node.k) {
    case "lit":
      return node.v;
    case "ref":
      return coerce(scope(node.name));
    case "unary": {
      const e = evalNode(node.e, scope);
      return node.op === "!" ? !truthy(e) : -toNum(e);
    }
    case "tern":
      return truthy(evalNode(node.c, scope)) ? evalNode(node.a, scope) : evalNode(node.b, scope);
    case "call": {
      const fn = FUNCS[node.name];
      if (!fn) throw new Error(`unknown function '${node.name}'`);
      return fn(node.args.map((a) => evalNode(a, scope)));
    }
    case "bin": {
      const { op } = node;
      if (op === "&&") return truthy(evalNode(node.l, scope)) ? evalNode(node.r, scope) : evalNode(node.l, scope);
      if (op === "||") return truthy(evalNode(node.l, scope)) ? evalNode(node.l, scope) : evalNode(node.r, scope);
      const l = evalNode(node.l, scope);
      const r = evalNode(node.r, scope);
      switch (op) {
        case "+":
          // String concat when either side is a (non-numeric) string.
          if (typeof l === "string" || typeof r === "string") {
            const ln = toNum(l);
            const rn = toNum(r);
            if (!Number.isNaN(ln) && !Number.isNaN(rn) && typeof l !== "string" && typeof r !== "string") {
              return ln + rn;
            }
            return toStr(l) + toStr(r);
          }
          return toNum(l) + toNum(r);
        case "-":
          return toNum(l) - toNum(r);
        case "*":
          return toNum(l) * toNum(r);
        case "/":
          return toNum(l) / toNum(r);
        case "%":
          return toNum(l) % toNum(r);
        case "<":
          return toNum(l) < toNum(r);
        case "<=":
          return toNum(l) <= toNum(r);
        case ">":
          return toNum(l) > toNum(r);
        case ">=":
          return toNum(l) >= toNum(r);
        case "==":
        case "=":
          return looseEq(l, r);
        case "!=":
          return !looseEq(l, r);
        default:
          throw new Error(`unknown operator '${op}'`);
      }
    }
  }
}

function looseEq(l: FormulaValue, r: FormulaValue): boolean {
  if (typeof l === "number" || typeof r === "number") {
    const ln = toNum(l);
    const rn = toNum(r);
    if (!Number.isNaN(ln) && !Number.isNaN(rn)) return ln === rn;
  }
  return toStr(l).toLowerCase() === toStr(r).toLowerCase();
}

export interface FormulaResult {
  value: FormulaValue;
  error: string | null;
}

/** Compile + evaluate a formula against a row scope. Never throws — a parse or
 *  eval error is returned in `error` and the value is null. NaN normalizes to
 *  null so the cell renders blank rather than "NaN". */
export function evalFormula(expr: string, scope: Scope): FormulaResult {
  if (!expr.trim()) return { value: null, error: null };
  try {
    const value = evalNode(parse(tokenize(expr)), scope);
    if (typeof value === "number" && Number.isNaN(value)) return { value: null, error: null };
    return { value, error: null };
  } catch (e) {
    return { value: null, error: e instanceof Error ? e.message : "formula error" };
  }
}
