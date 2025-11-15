#!/usr/bin/env bash 
set -euo pipefail
echo
curl -s "https://raw.githubusercontent.com/WillzyDollarrzz/willzy/main/inscription.txt" \
  | sed 's/\\\\033/\033/g' \
  | while IFS= read -r line; do
      echo -e "$line"
    done

sleep 2
echo

PROJECT_DIR="$(pwd)"
NODE_SCRIPT="lat.js"
ENV_FILE=".env"
PKG_JSON="package.json"

info() { printf "\n\033[1;36m%s\033[0m\n\n" "$*"; }
warn() { printf "\n\033[1;33m%s\033[0m\n\n" "$*"; }
err() { printf "\n\033[1;31m%s\033[0m\n\n" "$*"; }


if ! command -v node >/dev/null 2>&1; then
  err "node not found. Install Node.js (v16+/v18+ recommended) and re-run ./lat.sh"
  exit 1
fi

if ! command -v npm >/dev/null 2>&1; then
  err "npm not found. Install npm and re-run ./lat.sh"
  exit 1
fi

info ""


read -r -p "Paste an rpc url (recommend helius free rpc / paid): " RPC_URL
RPC_URL="${RPC_URL:-https://api.mainnet-beta.solana.com}"

read -r -p "Paste the Solana Address you want to track): " START_ADDRESS
if [ -z "$START_ADDRESS" ]; then
  err "Start address is required. Re-run ./lat.sh and paste a valid solana address."
  exit 1
fi

read -r -p "Number of last addresses to track (default 100): " HOPS
HOPS="${HOPS:-100}"

printf "\nYou entered:\n"
printf "  RPC URL: %s\n" "$RPC_URL"
printf "  Start address: %s\n" "$START_ADDRESS"
printf "  running times: %s\n\n" "$HOPS"
read -r -p "Confirm and start? (Y/n) " CONFIRM
CONFIRM="${CONFIRM:-y}"

case "${CONFIRM,,}" in
  y|yes)
    ;;
  *)
    info "Aborted by user."
    exit 0
    ;;
esac

info "Writing .env file..."

cat > "$ENV_FILE" <<EOF
RPC_URL=${RPC_URL}
DOTENV_CONFIG_QUIET=true
MIN_RPC_INTERVAL_MS=270

START_ADDRESS=${START_ADDRESS}

HOPS=${HOPS}
OUTPUT_FILE=chain_output.txt

SIGNATURES_LIMIT=500
MAX_SIGNATURES_SCAN=5000

DELAY_MS=150
MAX_RETRIES=5
EOF

info ".env written."

info "Writing package.json"

cat > "$PKG_JSON" <<'JSON'
{
  "name": "lat",
  "version": "1.0.0",
  "description": "",
  "main": "index.js",
  "scripts": {
    "test": "echo \"Error: no test specified\" && exit 1"
  },
  "keywords": [],
  "author": "",
  "license": "ISC",
  "type": "module",
  "dependencies": {
    "@solana/web3.js": "^1.98.4",
    "dotenv": "^17.2.3"
  }
}
JSON

info "package.json modified."


info "Installing dependencies (this may take a moment)..."
npm install

info "Dependencies installed."

info "Writing Node script (${NODE_SCRIPT})..."

cat > "$NODE_SCRIPT" <<'JS'
#!/usr/bin/env node

import fs from 'fs';
import path from 'path';
import { Connection, PublicKey } from '@solana/web3.js';
import dotenv from 'dotenv';

dotenv.config({ quiet: true });
dotenv.config();
 
const RPC_URL = process.env.RPC_URL || 'https://api.mainnet-beta.solana.com';
const START_ADDRESS = process.env.START_ADDRESS || '';
const HOPS = Number(process.env.HOPS || 100);
const OUTPUT_FILE = process.env.OUTPUT_FILE || 'chain_output.txt';
const SIGNATURES_LIMIT = Number(process.env.SIGNATURES_LIMIT || 500);
const MAX_SIGNATURES_SCAN = Number(process.env.MAX_SIGNATURES_SCAN || 5000);
const DELAY_MS = Number(process.env.DELAY_MS || 150);
const MAX_RETRIES = Number(process.env.MAX_RETRIES || 5);

const MIN_RPC_INTERVAL_MS = Number(process.env.MIN_RPC_INTERVAL_MS || 250);

const STATE_FILE = path.join(process.cwd(), 'follow_state.json');

const connection = new Connection(RPC_URL, 'confirmed');

function sleep(ms) {
  return new Promise((res) => setTimeout(res, ms));
}


let _lastRpcTs = 0;
async function rateLimitRpc() {
  const now = Date.now();
  const elapsed = now - _lastRpcTs;
  if (elapsed < MIN_RPC_INTERVAL_MS) {
    await sleep(MIN_RPC_INTERVAL_MS - elapsed + Math.floor(Math.random() * 10));
  }
  _lastRpcTs = Date.now();
}

async function withRetries(fn, opts = {}) {
  const maxRetries = opts.maxRetries ?? MAX_RETRIES;
  let attempt = 0;
  let wait = 300;
  while (true) {
    try {
     
      await rateLimitRpc();
      return await fn();
    } catch (err) {
      attempt++;
      const isLast = attempt > maxRetries;
      if (isLast) throw err;
      const jitter = Math.floor(Math.random() * 200);
      await sleep(wait + jitter);
      wait *= 1.8;
    }
  }
}


function appendLineSyncAtomic(filePath, line) {
  const fd = fs.openSync(filePath, 'a');
  try {

    fs.writeSync(fd, line + '\n\n');
    fs.fsyncSync(fd);
  } finally {
    fs.closeSync(fd);
  }
}

function saveState(state) {
  try {
    fs.writeFileSync(STATE_FILE, JSON.stringify(state, null, 2));
  } catch (e) {
    console.error('Failed saving state:', e.message);
  }
}

function loadState() {
  try {
    if (fs.existsSync(STATE_FILE)) {
      const raw = fs.readFileSync(STATE_FILE, 'utf8');
      return JSON.parse(raw);
    }
  } catch (e) {
    console.warn('Could not load state file:', e.message);
  }
  return null;
}

function lamportsToSolString(lamports) {
  const sol = Number(lamports) / 1e9;
  return sol.toFixed(9);
}

function isSystemTransferFrom(instr, sourceAddr) {
  try {
    if (!instr) return false;
    if (instr.program !== 'system') return false;
    if (!instr.parsed || instr.parsed.type !== 'transfer') return false;
    const info = instr.parsed.info;
    return info && info.source === sourceAddr;
  } catch (e) {
    return false;
  }
}

async function findLastOutgoingRecipient(address, signatureLimit = SIGNATURES_LIMIT, maxScan = MAX_SIGNATURES_SCAN) {
  const pub = new PublicKey(address);
  let scanned = 0;
  let before = undefined;

  while (scanned < maxScan) {
    const sigs = await withRetries(() =>
      connection.getSignaturesForAddress(pub, { limit: signatureLimit, before })
    );

    if (!sigs || sigs.length === 0) return null;

    for (const si of sigs) {
      scanned++;

      const parsedTx = await withRetries(() =>
        connection.getParsedTransaction(si.signature, { commitment: 'confirmed', maxSupportedTransactionVersion: 0 })
      );

      if (!parsedTx || !parsedTx.transaction) continue;
      const instructions = parsedTx.transaction.message.instructions;

      for (const instr of instructions) {
        if (isSystemTransferFrom(instr, address)) {
          const info = instr.parsed.info;
          return {
            destination: info.destination,
            lamports: info.lamports,
            txSignature: si.signature,
            slot: parsedTx.slot ?? si.slot,
            blockTime: parsedTx.blockTime ?? si.blockTime ?? null,
          };
        }
      }
      if (scanned >= maxScan) break;
    }

    before = sigs[sigs.length - 1].signature;
    await sleep(50);
  }
  return null;
}

async function isProgramOwnedAddress(address) {
  try {
    const info = await withRetries(() => connection.getAccountInfo(new PublicKey(address)));
    if (!info) return false;
    const ownerPk = info.owner?.toString();
    return ownerPk && ownerPk !== '11111111111111111111111111111111';
  } catch (e) {
    return false;
  }
}

async function main() {
  const cliStart = process.argv[2];
  const startAddr = (cliStart || START_ADDRESS).trim();
  if (!startAddr) {
    console.error('ERROR: You must provide an address in .env via START_ADDRESS');
    console.error('Re-Run: node lat.js');
    process.exit(1);
  }
  const cliHops = Number(process.argv[3] ?? HOPS);
  const hops = Number.isFinite(cliHops) ? cliHops : HOPS;

  console.log('Tracking address:', startAddr);
  console.log();
  console.log('No. of times to fetch last address:', hops);
  console.log();
  console.log('Output file:', OUTPUT_FILE);
  console.log();

  const saved = loadState();
  let currentAddress = startAddr;
  let step = 0;
  const visited = new Set();

  if (saved && saved.currentAddress && Number.isFinite(saved.step)) {
    if (saved.startAddress === startAddr) {
      console.log('Resuming from saved state at step', saved.step, 'address', saved.currentAddress);
      currentAddress = saved.currentAddress;
      step = saved.step;
      if (Array.isArray(saved.visited)) saved.visited.forEach(a => visited.add(a));
    } else {
      console.log('Last address file found but startAddress differs; ignoring to resume file.');
    }
  }

  if (!fs.existsSync(OUTPUT_FILE)) {
    const header = `Tracked History\nStart: ${startAddr}\nStarted: ${new Date().toISOString()}\n\n`;
    fs.writeFileSync(OUTPUT_FILE, header);
  }

  while (step < hops) {
    console.log(`Address ${step + 1}/${hops} — current: ${currentAddress}`);
    console.log();

    if (visited.has(currentAddress)) {
      const line = `${currentAddress} — loop detected (address already visited). Stopping.`;
      console.log(line);
      console.log();
      appendLineSyncAtomic(OUTPUT_FILE, line);
      saveState({ startAddress: startAddr, currentAddress, step, visited: Array.from(visited) });
      break;
    }

    visited.add(currentAddress);

    let found = null;
    try {
      found = await findLastOutgoingRecipient(currentAddress);
    } catch (err) {
      const errLine = `${currentAddress} — ERROR while scanning: ${String(err.message || err)}. Stopping.`;
      console.error(errLine);
      console.log();
      appendLineSyncAtomic(OUTPUT_FILE, errLine);
      saveState({ startAddress: startAddr, currentAddress, step, visited: Array.from(visited) });
      break;
    }

    if (!found) {
      const line = `${currentAddress} transferred (0.000000000) sol to -> none last  # no outgoing SOL transfer found (scanned limit reached)`;
      console.log(line);
      console.log();
      appendLineSyncAtomic(OUTPUT_FILE, line);
      saveState({ startAddress: startAddr, currentAddress, step, visited: Array.from(visited) });
      break;
    }

    const solAmount = lamportsToSolString(found.lamports);
    const destination = found.destination;
    const outLine = `${currentAddress} transferred (${solAmount}) sol to -> ${destination} last`;

    const meta = `  \n# tx:${found.txSignature} slot:${found.slot}${found.blockTime ? ' time:' + new Date(found.blockTime * 1000).toISOString() : ''}`;
    console.log(outLine + meta);
    console.log();
    appendLineSyncAtomic(OUTPUT_FILE, outLine);

    step++;
    saveState({ startAddress: startAddr, currentAddress: destination, step, visited: Array.from(visited) });

    try {
      const programOwned = await isProgramOwnedAddress(destination);
      if (programOwned) {
        const progLine = `${destination} — detected program-owned account. Stopping script.`;
        console.log(progLine);
        console.log();
        appendLineSyncAtomic(OUTPUT_FILE, progLine);
        break;
      }
    } catch (e) {
    }

    currentAddress = destination;

    await sleep(DELAY_MS);
  }

  const footer = `Finished at ${new Date().toISOString()}`;
  console.log(footer);
  appendLineSyncAtomic(OUTPUT_FILE, footer);
  saveState({ startAddress: startAddr, currentAddress, step, visited: Array.from(visited), finishedAt: new Date().toISOString() });
  console.log('Scan Completed. Results written to', OUTPUT_FILE);
  console.log();
  console.log ('To continue with different address, replace the address in "Start_Address" in .env file');
  console.log ('To re-run: node lat.js');
}

main().catch((err) => {
  console.error('Fatal error:', err);
  process.exit(1);
});
JS


chmod +x "$NODE_SCRIPT" >/dev/null 2>&1 || true

info "Starting LA Tracker now..."
node "$NODE_SCRIPT"
