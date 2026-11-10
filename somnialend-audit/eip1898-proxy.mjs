#!/usr/bin/env node
// EIP-1898 rewriting proxy for Somnia.
//
// Somnia's RPC rejects block parameters sent as objects, e.g.
//   {"blockHash":"0x…","requireCanonical":false}  or  {"blockNumber":"0x…"}
// with -32602 "invalid parameters". Forge >= 1.8 sends that form on every state read while
// bootstrapping a fork, which is why a newer Forge dies with
//   failed to get account for 0x0000…0000: -32602 invalid parameters
//
// This proxy sits in front of the real endpoint and rewrites the object form into a plain hex
// block number, so any Forge version can fork Somnia.
//
//   node eip1898-proxy.mjs --upstream https://api.infra.mainnet.somnia.network --port 8546
//   forge test --fork-url http://127.0.0.1:8546 --fork-block-number <N>
//
// Defaults are read from SOMNIA_RPC_URL and SOMNIA_PROXY_PORT.

import http from "node:http";
import {URL} from "node:url";

const args = process.argv.slice(2);
function arg(name, fallback) {
  const i = args.indexOf(`--${name}`);
  return i >= 0 && args[i + 1] ? args[i + 1] : fallback;
}

const upstream = arg("upstream", process.env.SOMNIA_RPC_URL || "https://api.infra.mainnet.somnia.network");
const port = Number(arg("port", process.env.SOMNIA_PROXY_PORT || "8546"));
const host = arg("host", "127.0.0.1");

const hexBlock = new Map(); // blockHash -> hex block number, filled on demand
let pinnedBlock = null; // last plain block number the client asked for
let rewrites = 0;

function isBlockObject(v) {
  return v && typeof v === "object" && !Array.isArray(v) &&
    ("blockHash" in v || "blockNumber" in v);
}

async function rpcCall(method, params) {
  const res = await fetch(upstream, {
    method: "POST",
    headers: {"content-type": "application/json"},
    body: JSON.stringify({jsonrpc: "2.0", id: 1, method, params}),
  });
  return res.json();
}

// Resolve a block object into a hex block number the RPC will accept.
async function toHexBlock(obj) {
  if (obj.blockNumber) return obj.blockNumber;
  const hash = obj.blockHash;
  if (!hash) return null;
  if (hexBlock.has(hash)) return hexBlock.get(hash);
  const r = await rpcCall("eth_getBlockByHash", [hash, false]);
  if (r && r.result && r.result.number) {
    hexBlock.set(hash, r.result.number);
    return r.result.number;
  }
  return null;
}

// Walk the params array and replace every EIP-1898 object with a block number.
async function rewriteParams(method, params) {
  if (!Array.isArray(params)) return params;
  const out = [...params];
  for (let i = 0; i < out.length; i++) {
    const p = out[i];
    if (isBlockObject(p)) {
      let hex = await toHexBlock(p);
      // A fork pins one block; fall back to it rather than failing the whole call.
      if (!hex) hex = pinnedBlock;
      if (hex) {
        out[i] = hex;
        rewrites++;
      }
      continue;
    }
    // Remember the pinned block from the normal form so blockHash lookups have a fallback.
    if (method === "eth_getBlockByNumber" && i === 0 && typeof p === "string" && /^0x[0-9a-f]+$/i.test(p)) {
      pinnedBlock = p;
    }
  }
  return out;
}

const server = http.createServer((req, res) => {
  if (req.method === "GET") {
    res.writeHead(200, {"content-type": "application/json"});
    res.end(JSON.stringify({status: "ok", upstream, rewrites, pinnedBlock}));
    return;
  }

  let body = "";
  req.on("data", (c) => (body += c));
  req.on("end", async () => {
    let payload;
    try {
      payload = JSON.parse(body);
    } catch {
      res.writeHead(400, {"content-type": "application/json"});
      res.end(JSON.stringify({jsonrpc: "2.0", id: null, error: {code: -32700, message: "parse error"}}));
      return;
    }

    const handle = async (call) => {
      const params = await rewriteParams(call.method, call.params);
      const r = await fetch(upstream, {
        method: "POST",
        headers: {"content-type": "application/json"},
        body: JSON.stringify({...call, params}),
      });
      return r.json();
    };

    try {
      const result = Array.isArray(payload) ? await Promise.all(payload.map(handle)) : await handle(payload);
      res.writeHead(200, {"content-type": "application/json"});
      res.end(JSON.stringify(result));
    } catch (e) {
      res.writeHead(502, {"content-type": "application/json"});
      res.end(JSON.stringify({jsonrpc: "2.0", id: payload?.id ?? null, error: {code: -32000, message: String(e)}}));
    }
  });
});

server.listen(port, host, () => {
  console.error(`eip1898-proxy listening on http://${host}:${port} -> ${upstream}`);
  console.error(`point forge at it:  --fork-url http://${host}:${port} --fork-block-number <N>`);
});
