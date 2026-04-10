#!/usr/bin/env bash
# ==============================================================================
# fund.sh — Send ETH from the dev account to any address
# ==============================================================================
# Usage:
#   ./fund.sh <address> [amount_in_eth] [--rpc-url <url>]
#
# Examples:
#   ./fund.sh 0xYourAddress                          # 100 ETH to address (local)
#   ./fund.sh 0xYourAddress 500                      # 500 ETH to address (local)
#   ./fund.sh 0xYourAddress 100 --rpc-url https://rpc.example.com  # remote VPS
#
# The dev account is unlocked by default in --dev mode, so no private key needed.
# ==============================================================================

set -euo pipefail

RPC_URL="http://localhost:8545"
ADDRESS=""
AMOUNT_ETH="100"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --rpc-url)
            RPC_URL="$2"
            shift 2
            ;;
        0x*)
            ADDRESS="$1"
            shift
            ;;
        *)
            AMOUNT_ETH="$1"
            shift
            ;;
    esac
done

if [[ -z "$ADDRESS" ]]; then
    echo "Usage: ./fund.sh <address> [amount_in_eth] [--rpc-url <url>]"
    echo ""
    echo "Examples:"
    echo "  ./fund.sh 0xYourAddress"
    echo "  ./fund.sh 0xYourAddress 500"
    echo "  ./fund.sh 0xYourAddress 100 --rpc-url https://rpc.example.com"
    exit 1
fi

# Get the dev account (first account on the node)
DEV_ACCOUNT=$(curl -sf "$RPC_URL" -X POST -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","method":"eth_accounts","params":[],"id":1}' \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['result'][0])" 2>/dev/null)

if [[ -z "$DEV_ACCOUNT" ]]; then
    echo "Error: could not reach Geth RPC at $RPC_URL"
    exit 1
fi

# Convert ETH to wei (hex)
VALUE_HEX=$(python3 -c "print(hex(int($AMOUNT_ETH * 10**18)))")

# Send transaction
RESULT=$(curl -sf "$RPC_URL" -X POST -H "Content-Type: application/json" \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"eth_sendTransaction\",\"params\":[{\"from\":\"$DEV_ACCOUNT\",\"to\":\"$ADDRESS\",\"value\":\"$VALUE_HEX\"}],\"id\":1}")

TX_HASH=$(echo "$RESULT" | python3 -c "import sys,json; r=json.load(sys.stdin); print(r.get('result',''))" 2>/dev/null)
ERROR=$(echo "$RESULT" | python3 -c "import sys,json; r=json.load(sys.stdin); e=r.get('error',{}); print(e.get('message',''))" 2>/dev/null)

if [[ -n "$TX_HASH" && "$TX_HASH" != "None" ]]; then
    echo "Sent $AMOUNT_ETH ETH to $ADDRESS"
    echo "  From: $DEV_ACCOUNT"
    echo "  TX:   $TX_HASH"
else
    echo "Error: $ERROR"
    exit 1
fi
