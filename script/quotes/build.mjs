#!/usr/bin/env node
// Builds script/quotes/base.json, the launch pairs on Base that RegisterQuotes.s.sol registers (ETH is
// registered by the deploy script, so it is not in the file).
//
//   node script/quotes/build.mjs            # write base.json
//   node script/quotes/build.mjs --dry      # print the report only
//
// Sources, all public and keyless:
// - Crypto pairs: the CRYPTO list below, decimals read on Base, USD price from Coinbase spot.
// - Stocks: the Coinbase Tokenized Stocks API (https://api.coinbase.com/v1/tokenized-stocks). A stock becomes
//   a pair only if people can actually pay with it:
//     it has supply (total_supply > 0), no paused features, a USD price, and at least MIN_SUPPLY_USD of
//     supply in circulation.
//   Price: the Chainlink NAV from the API while it is fresh (NAV_MAX_AGE_H), else the token's DEX price from
//   GeckoTerminal. Both are the price of one token, multiplier included.
//
// Start tick: every pair starts a launch at the same fully diluted value, START_FDV_USD for 1e9 tokens:
//   quote per token = START_FDV_USD / 1e9 / quoteUsd
//   tick = log_1.0001(quote per token × 10^(quoteDecimals − 18)), rounded to TICK_SPACING
// (tick in the token0 frame, as the factory and the API read it: 1.0001^tick × 10^(18 − d) = quote per token).

import { writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

export const START_FDV_USD = 4000;
export const LAUNCH_SUPPLY = 1e9;
export const TICK_SPACING = 200;
export const MIN_SUPPLY_USD = 10_000;
export const NAV_MAX_AGE_H = 96; // covers a weekend: the feed holds the last close until markets open

const RPC = process.env.BASE_RPC || 'https://mainnet.base.org';
const STOCKS_API = 'https://api.coinbase.com/v1/tokenized-stocks';
const GECKO = 'https://api.geckoterminal.com/api/v2/simple/networks/base/token_price';
const OUT = fileURLToPath(new URL('./base.json', import.meta.url));

// Crypto pairs besides ETH, with the Coinbase spot ticker that prices them (USDC is pinned at $1).
export const CRYPTO = [
  { symbol: 'USDC', address: '0x833589fcd6edb6e08f4c7c32d4f71b54bda02913', usd: 'USD' },
  { symbol: 'cbBTC', address: '0xcbb7c0000ab88b473b1f5afd9ef808440eed33bf', usd: 'BTC' },
  { symbol: 'cbDOGE', address: '0xcbd06e5a2b0c65597161de254aa074e489deb510', usd: 'DOGE' },
  { symbol: 'cbXRP', address: '0xcb585250f852c6c6bf90434ab21a00f02833a4af', usd: 'XRP' },
  { symbol: 'cbLTC', address: '0xcb17c9db87b595717c857a08468793f5bab6445f', usd: 'LTC' },
  { symbol: 'cbADA', address: '0xcbada732173e39521cdbe8bf59a6dc85a9fc7b8c', usd: 'ADA' },
  { symbol: 'cbZEC', address: '0xb2000000000000000000008501b13360000cb2ec', usd: 'ZEC' },
  { symbol: 'cbHYPE', address: '0xb200000000000000000000451d033a5000cb479e', usd: 'HYPE' },
];

/** The start tick for a pair priced at `quoteUsd` with `quoteDecimals`. */
export function startTick(quoteUsd, quoteDecimals, fdvUsd = START_FDV_USD) {
  if (!(quoteUsd > 0)) throw new Error('quote price must be positive');
  const quotePerToken = fdvUsd / LAUNCH_SUPPLY / quoteUsd;
  const raw = Math.log(quotePerToken * 10 ** (quoteDecimals - 18)) / Math.log(1.0001);
  return Math.round(raw / TICK_SPACING) * TICK_SPACING || 0;
}

/** The USD price to use for a stock record, with its source, or null. `gecko`: Map(address → usd). */
export function stockPrice(t, gecko, now = Date.now()) {
  const navAge = t.nav_price_updated_at ? (now - Date.parse(t.nav_price_updated_at)) / 3_600_000 : Infinity;
  if (t.nav_price > 0 && navAge <= NAV_MAX_AGE_H) return { usd: t.nav_price, source: 'chainlink-nav' };
  const dex = gecko.get(t.contract_address.toLowerCase());
  if (dex > 0) return { usd: dex, source: 'dex' };
  return null;
}

/** Why a stock is left out ('' = it is a pair). */
export function stockSkipReason(t, price) {
  if (!(t.total_supply > 0)) return 'no supply';
  if (t.paused_features?.length) return 'paused';
  if (!price) return 'no price';
  if (t.total_supply * price.usd < MIN_SUPPLY_USD) return 'supply under $10k';
  return '';
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function json(url, init, tries = 5) {
  for (let i = 0; ; i++) {
    const res = await fetch(url, { ...init, signal: AbortSignal.timeout(20_000) });
    // public APIs rate-limit: wait and retry
    if (res.status === 429 && i < tries - 1) {
      await sleep(15_000 * (i + 1));
      continue;
    }
    if (!res.ok) throw new Error(`${url.split('?')[0].slice(0, 80)}: HTTP ${res.status}`);
    return res.json();
  }
}

async function allStocks() {
  const tokens = [];
  let page = '';
  do {
    const body = await json(`${STOCKS_API}?page_size=500${page ? `&page_token=${encodeURIComponent(page)}` : ''}`);
    tokens.push(...(body.tokens || []));
    page = body.next_page_token || '';
  } while (page);
  return tokens;
}

async function geckoPrices(addresses) {
  const out = new Map();
  for (let i = 0; i < addresses.length; i += 30) {
    const chunk = addresses.slice(i, i + 30);
    const body = await json(`${GECKO}/${chunk.join(',')}`);
    for (const [a, v] of Object.entries(body?.data?.attributes?.token_prices || {})) if (Number(v) > 0) out.set(a.toLowerCase(), Number(v));
  }
  return out;
}

async function decimalsOf(address) {
  const body = await json(RPC, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'eth_call', params: [{ to: address, data: '0x313ce567' }, 'latest'] }),
  });
  if (!body.result || body.result === '0x') throw new Error(`decimals() failed for ${address}`);
  return Number(BigInt(body.result));
}

async function spotUsd(ticker) {
  if (ticker === 'USD') return 1;
  const usd = Number((await json(`https://api.coinbase.com/v2/prices/${ticker}-USD/spot`))?.data?.amount);
  if (!(usd > 0)) throw new Error(`no Coinbase price for ${ticker}`);
  return usd;
}

async function main() {
  const dry = process.argv.includes('--dry');
  const pairs = [];

  for (const c of CRYPTO) {
    const [decimals, usd] = await Promise.all([decimalsOf(c.address), spotUsd(c.usd)]);
    pairs.push({ symbol: c.symbol, address: c.address, decimals, usd, source: c.usd === 'USD' ? 'pinned' : 'coinbase-spot', kind: 'crypto' });
  }

  const stocks = await allStocks();
  const gecko = await geckoPrices(stocks.filter((t) => t.total_supply > 0).map((t) => t.contract_address.toLowerCase()));
  const skipped = {};
  for (const t of stocks) {
    const price = stockPrice(t, gecko);
    const reason = stockSkipReason(t, price);
    if (reason) {
      (skipped[reason] ||= []).push(t.symbol);
      continue;
    }
    pairs.push({ symbol: t.symbol, address: t.contract_address.toLowerCase(), decimals: Number(t.decimals), usd: price.usd, source: price.source, kind: 'stock' });
  }

  // the factory takes pairs sorted by address
  pairs.sort((a, b) => (BigInt(a.address) < BigInt(b.address) ? -1 : 1));
  for (const p of pairs) p.tick = startTick(p.usd, p.decimals);

  const stockCount = pairs.filter((p) => p.kind === 'stock').length;
  console.log(`pairs: ${pairs.length} (${pairs.length - stockCount} crypto, ${stockCount} stocks) of ${stocks.length} stocks in the API`);
  for (const [reason, list] of Object.entries(skipped)) console.log(`skipped, ${reason}: ${list.length}${list.length <= 12 ? ` (${list.join(', ')})` : ''}`);
  console.log(`stock prices: ${pairs.filter((p) => p.source === 'chainlink-nav').length} Chainlink NAV, ${pairs.filter((p) => p.source === 'dex').length} DEX`);
  if (dry) return;

  const file = {
    note: `Launch pairs on Base except ETH, sorted by address. Built by script/quotes/build.mjs on ${new Date().toISOString().slice(0, 10)}: start ticks for a $${START_FDV_USD.toLocaleString('en-US')} FDV (token0 frame)`,
    quoteTokens: pairs.map((p) => p.address),
    startTicks: pairs.map((p) => p.tick),
    symbols: pairs.map((p) => p.symbol),
    prices: pairs.map((p) => ({ symbol: p.symbol, usd: p.usd, source: p.source, decimals: p.decimals })),
  };
  writeFileSync(OUT, `${JSON.stringify(file, null, 1)}\n`);
  console.log(`wrote ${OUT}`);
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  main().catch((e) => {
    console.error(e.message);
    process.exit(1);
  });
}
