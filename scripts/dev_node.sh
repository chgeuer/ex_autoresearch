#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
APP_NAME="${DEV_NODE_NAME:-$(basename "$PROJECT_DIR")}"
COOKIE="${DEV_NODE_COOKIE:-devcookie}"
HOSTNAME="$(hostname -s)"
FQDN="${APP_NAME}@${HOSTNAME}"
PIDFILE=".dev_node.pid"

case "${1:-help}" in
  start)
    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
      echo "Node already running (pid $(cat "$PIDFILE"))"
      exit 0
    fi
    echo "Starting node ${FQDN} ..."
    elixir --sname "$APP_NAME" --cookie "$COOKIE" -S mix run --no-halt > .dev_node.log 2>&1 &
    echo $! > "$PIDFILE"
    for i in $(seq 1 30); do
      if elixir --sname "probe_$$" --cookie "$COOKIE" --hidden -e "
        if Node.connect(:\"${FQDN}\"), do: System.halt(0), else: System.halt(1)
      " 2>/dev/null; then
        echo "Node ${FQDN} is up (pid $(cat "$PIDFILE"))"
        exit 0
      fi
      sleep 1
    done
    echo "ERROR: Node did not become reachable within 30s. Check .dev_node.log"
    exit 1
    ;;

  stop)
    if [ -f "$PIDFILE" ]; then
      kill "$(cat "$PIDFILE")" 2>/dev/null && echo "Node stopped" || echo "Node was not running"
      rm -f "$PIDFILE"
    else
      echo "No pidfile found"
    fi
    ;;

  status)
    if epmd -names 2>/dev/null | grep -q "name ${APP_NAME} "; then
      echo "Node ${FQDN} is running"
      exit 0
    else
      echo "Node ${FQDN} is not running"
      exit 1
    fi
    ;;

  await)
    TIMEOUT="${2:-30}"
    echo "Waiting for node ${FQDN} ..."
    for i in $(seq 1 "$TIMEOUT"); do
      if elixir --sname "probe_$$" --cookie "$COOKIE" --hidden -e "
        if Node.connect(:\"${FQDN}\"), do: System.halt(0), else: System.halt(1)
      " 2>/dev/null; then
        echo "Node ${FQDN} is reachable"
        exit 0
      fi
      sleep 1
    done
    echo "ERROR: Node ${FQDN} did not become reachable within ${TIMEOUT}s"
    exit 1
    ;;

  rpc)
    shift
    EXPR="$*"
    elixir --sname "rpc_$$" --cookie "$COOKIE" --hidden --no-halt -e "
      target = :\"${FQDN}\"
      true = Node.connect(target)
      {result, _binding} = :rpc.call(target, Code, :eval_string, [\"\"\"
        ${EXPR}
      \"\"\"])
      IO.inspect(result, pretty: true, limit: 200, printable_limit: 4096)
      System.halt(0)
    "
    ;;

  eval_file)
    shift
    FILE="$1"
    elixir --sname "rpc_$$" --cookie "$COOKIE" --hidden --no-halt -e "
      target = :\"${FQDN}\"
      true = Node.connect(target)
      code = File.read!(\"${FILE}\")
      {result, _binding} = :rpc.call(target, Code, :eval_string, [code])
      IO.inspect(result, pretty: true, limit: 200, printable_limit: 4096)
      System.halt(0)
    "
    ;;

  help|*)
    echo "Usage: scripts/dev_node.sh {start|stop|status|await [timeout]|rpc <expr>|eval_file <path>}"
    echo ""
    echo "Commands:"
    echo "  start          - Start a standalone BEAM node"
    echo "  stop           - Kill the node process"
    echo "  status         - Check if node is registered with epmd (exit 0/1)"
    echo "  await [secs]   - Wait for node to be connectable via distributed Erlang (default: 30s)"
    echo "  rpc <expr>     - Execute an Elixir expression on the remote node"
    echo "  eval_file <f>  - Evaluate a file on the remote node"
    echo ""
    echo "Environment variables:"
    echo "  DEV_NODE_NAME  - sname for the node (default: project directory name)"
    echo "  DEV_NODE_COOKIE - cluster cookie (default: devcookie)"
    ;;
esac
