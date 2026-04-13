#!/bin/sh
# Configure CORS for the IPFS HTTP API so remote clients (e.g. protocol-cli
# running from a developer machine) can upload via /api/v0/add.
#
# The API is protected at the Traefik layer with basic auth — CORS alone
# does not authenticate, it only tells Kubo which Origins are allowed to
# hit the API. We use "*" because the actual auth boundary is Traefik.
set -eu

ipfs config --json API.HTTPHeaders.Access-Control-Allow-Origin '["*"]'
ipfs config --json API.HTTPHeaders.Access-Control-Allow-Methods '["GET","POST","PUT","OPTIONS","DELETE"]'
ipfs config --json API.HTTPHeaders.Access-Control-Allow-Headers '["Authorization","Content-Type","X-Requested-With"]'
