#!/usr/bin/env python3
"""
API Traffic Logger Proxy

Simple HTTP proxy that forwards requests to Anthropic API and logs
request/response data to JSON files for development reports.

Logs are saved to /data/api-logs/{project}/ with one file per day.
"""

import os
import json
import time
import asyncio
from datetime import datetime
from pathlib import Path
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse
import threading

try:
    import httpx
except ImportError:
    print("Installing httpx...")
    import subprocess
    subprocess.check_call(["pip", "install", "httpx"])
    import httpx

# Configuration
ANTHROPIC_API_URL = "https://api.anthropic.com"
LOG_DIR = Path(os.environ.get("LOG_DIR", "/data/api-logs"))
PROJECT_NAME = os.environ.get("PROJECT_NAME", "default")
PORT = int(os.environ.get("PORT", 8000))

# Ensure log directory exists
PROJECT_LOG_DIR = LOG_DIR / PROJECT_NAME
PROJECT_LOG_DIR.mkdir(parents=True, exist_ok=True)


def get_log_file():
    """Get the log file path for today."""
    today = datetime.now().strftime("%Y-%m-%d")
    return PROJECT_LOG_DIR / f"api-log-{today}.jsonl"


def log_request(data: dict):
    """Append a log entry to today's log file."""
    log_file = get_log_file()
    with open(log_file, "a") as f:
        f.write(json.dumps(data) + "\n")


class ProxyHandler(BaseHTTPRequestHandler):
    """HTTP request handler that proxies to Anthropic API and logs traffic."""

    protocol_version = "HTTP/1.1"

    def log_message(self, format, *args):
        """Suppress default logging."""
        pass

    def do_GET(self):
        """Handle GET requests (health check)."""
        if self.path == "/health":
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"status": "ok", "project": PROJECT_NAME}).encode())
        else:
            self.proxy_request("GET")

    def do_POST(self):
        """Handle POST requests (API calls)."""
        self.proxy_request("POST")

    def do_OPTIONS(self):
        """Handle CORS preflight."""
        self.send_response(200)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "*")
        self.end_headers()

    def proxy_request(self, method: str):
        """Proxy a request to Anthropic API and log it."""
        start_time = time.time()

        # Read request body
        content_length = int(self.headers.get("Content-Length", 0))
        request_body = self.rfile.read(content_length) if content_length > 0 else b""

        # Parse request for logging
        request_data = None
        prompt_preview = ""
        model = ""
        if request_body:
            try:
                request_data = json.loads(request_body)
                model = request_data.get("model", "")
                messages = request_data.get("messages", [])
                if messages:
                    last_msg = messages[-1]
                    content = last_msg.get("content", "")
                    if isinstance(content, str):
                        prompt_preview = content[:500]
                    elif isinstance(content, list):
                        # Handle content blocks
                        text_parts = [c.get("text", "") for c in content if c.get("type") == "text"]
                        prompt_preview = " ".join(text_parts)[:500]
            except json.JSONDecodeError:
                pass

        # Build target URL
        target_url = f"{ANTHROPIC_API_URL}{self.path}"

        # Copy headers (excluding host)
        headers = {}
        for key, value in self.headers.items():
            if key.lower() not in ("host", "content-length"):
                headers[key] = value

        # Make the proxied request
        try:
            with httpx.Client(timeout=300.0) as client:
                response = client.request(
                    method=method,
                    url=target_url,
                    headers=headers,
                    content=request_body,
                )

            duration_ms = int((time.time() - start_time) * 1000)

            # Parse response for logging
            response_preview = ""
            input_tokens = 0
            output_tokens = 0
            try:
                response_data = response.json()
                # Extract usage info
                usage = response_data.get("usage", {})
                input_tokens = usage.get("input_tokens", 0)
                output_tokens = usage.get("output_tokens", 0)
                # Extract response preview
                content = response_data.get("content", [])
                if content and isinstance(content, list):
                    text_parts = [c.get("text", "") for c in content if c.get("type") == "text"]
                    response_preview = " ".join(text_parts)[:500]
            except:
                response_preview = response.text[:500] if response.text else ""

            # Log the request/response
            log_entry = {
                "timestamp": datetime.now().isoformat(),
                "project": PROJECT_NAME,
                "model": model,
                "prompt_preview": prompt_preview,
                "response_preview": response_preview,
                "input_tokens": input_tokens,
                "output_tokens": output_tokens,
                "duration_ms": duration_ms,
                "status_code": response.status_code,
                "path": self.path,
            }
            log_request(log_entry)

            print(f"[{datetime.now().strftime('%H:%M:%S')}] {method} {self.path} -> {response.status_code} ({duration_ms}ms, {input_tokens}+{output_tokens} tokens)")

            # Send response back to client
            self.send_response(response.status_code)
            for key, value in response.headers.items():
                if key.lower() not in ("transfer-encoding", "content-encoding", "content-length"):
                    self.send_header(key, value)
            self.send_header("Content-Length", len(response.content))
            self.end_headers()
            self.wfile.write(response.content)

        except Exception as e:
            print(f"[ERROR] Proxy error: {e}")
            self.send_response(502)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            error_response = json.dumps({"error": str(e)})
            self.wfile.write(error_response.encode())


def main():
    print(f"API Logger Proxy starting...")
    print(f"  Project: {PROJECT_NAME}")
    print(f"  Log directory: {PROJECT_LOG_DIR}")
    print(f"  Proxying to: {ANTHROPIC_API_URL}")
    print(f"  Listening on: http://0.0.0.0:{PORT}")
    print()

    server = HTTPServer(("0.0.0.0", PORT), ProxyHandler)

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down...")
        server.shutdown()


if __name__ == "__main__":
    main()
