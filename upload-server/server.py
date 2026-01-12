#!/usr/bin/env python3
"""
Simple file upload server for Claude sandbox.
Allows drag & drop or paste of images/files via web interface.
Files are saved to /share directory (mounted from host).
"""

import os
import sys
import hashlib
from datetime import datetime
from pathlib import Path
from http.server import HTTPServer, BaseHTTPRequestHandler
import json
import cgi
import base64
import re

UPLOAD_DIR = Path(os.environ.get("UPLOAD_DIR", "/home/claude/share"))
PORT = int(os.environ.get("UPLOAD_PORT", 8888))

HTML_PAGE = """<!DOCTYPE html>
<html>
<head>
    <title>Claude Sandbox - File Upload</title>
    <style>
        * { box-sizing: border-box; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            max-width: 800px;
            margin: 0 auto;
            padding: 20px;
            background: #1a1a2e;
            color: #eee;
            min-height: 100vh;
        }
        h1 { color: #00d4ff; margin-bottom: 10px; }
        .subtitle { color: #888; margin-bottom: 30px; }
        .drop-zone {
            border: 3px dashed #444;
            border-radius: 12px;
            padding: 60px 20px;
            text-align: center;
            cursor: pointer;
            transition: all 0.3s;
            background: #16213e;
        }
        .drop-zone:hover, .drop-zone.drag-over {
            border-color: #00d4ff;
            background: #1a2744;
        }
        .drop-zone.drag-over { transform: scale(1.02); }
        .upload-icon { font-size: 48px; margin-bottom: 15px; }
        .upload-text { font-size: 18px; color: #aaa; }
        .upload-hint { font-size: 14px; color: #666; margin-top: 10px; }
        input[type="file"] { display: none; }
        .file-list {
            margin-top: 30px;
            border-radius: 8px;
            overflow: hidden;
        }
        .file-item {
            display: flex;
            align-items: center;
            padding: 12px 15px;
            background: #16213e;
            border-bottom: 1px solid #2a2a4a;
        }
        .file-item:last-child { border-bottom: none; }
        .file-item.success { border-left: 4px solid #00ff88; }
        .file-item.error { border-left: 4px solid #ff4757; }
        .file-item.uploading { border-left: 4px solid #ffa502; }
        .file-name { flex: 1; font-family: monospace; word-break: break-all; }
        .file-path { color: #00d4ff; font-size: 12px; margin-top: 4px; }
        .file-status { font-size: 12px; padding: 4px 8px; border-radius: 4px; }
        .status-success { background: #00ff8822; color: #00ff88; }
        .status-error { background: #ff475722; color: #ff4757; }
        .status-uploading { background: #ffa50222; color: #ffa502; }
        .paste-area {
            margin-top: 20px;
            padding: 15px;
            background: #16213e;
            border-radius: 8px;
            border: 1px solid #333;
        }
        .paste-area:focus {
            outline: none;
            border-color: #00d4ff;
        }
        .recent-files { margin-top: 30px; }
        .recent-files h3 { color: #888; font-size: 14px; margin-bottom: 10px; }
        code {
            background: #0d1b2a;
            padding: 2px 6px;
            border-radius: 4px;
            font-size: 13px;
        }
    </style>
</head>
<body>
    <h1>Claude Sandbox File Upload</h1>
    <p class="subtitle">Drop files here or paste images from clipboard</p>

    <div class="drop-zone" id="dropZone">
        <div class="upload-icon">📁</div>
        <div class="upload-text">Drop files here or click to browse</div>
        <div class="upload-hint">Supports images, text files, and more</div>
        <input type="file" id="fileInput" multiple>
    </div>

    <div class="paste-area" contenteditable="true" id="pasteArea">
        Click here and paste (Ctrl+V / Cmd+V) to upload from clipboard...
    </div>

    <div class="file-list" id="fileList"></div>

    <div class="recent-files" id="recentFiles">
        <h3>Recent uploads (in container at <code>/share</code>)</h3>
        <div id="recentList">Loading...</div>
    </div>

    <script>
        const dropZone = document.getElementById('dropZone');
        const fileInput = document.getElementById('fileInput');
        const fileList = document.getElementById('fileList');
        const pasteArea = document.getElementById('pasteArea');

        // Drag and drop handlers
        ['dragenter', 'dragover'].forEach(e => {
            dropZone.addEventListener(e, (ev) => {
                ev.preventDefault();
                dropZone.classList.add('drag-over');
            });
        });

        ['dragleave', 'drop'].forEach(e => {
            dropZone.addEventListener(e, (ev) => {
                ev.preventDefault();
                dropZone.classList.remove('drag-over');
            });
        });

        dropZone.addEventListener('drop', (e) => {
            const files = e.dataTransfer.files;
            handleFiles(files);
        });

        dropZone.addEventListener('click', () => fileInput.click());
        fileInput.addEventListener('change', () => handleFiles(fileInput.files));

        // Paste handler
        pasteArea.addEventListener('paste', (e) => {
            e.preventDefault();
            const items = e.clipboardData.items;

            for (let item of items) {
                if (item.type.startsWith('image/')) {
                    const blob = item.getAsFile();
                    const ext = item.type.split('/')[1] || 'png';
                    const filename = `clipboard_${Date.now()}.${ext}`;
                    const file = new File([blob], filename, { type: item.type });
                    handleFiles([file]);
                }
            }

            pasteArea.textContent = 'Click here and paste (Ctrl+V / Cmd+V) to upload from clipboard...';
        });

        function handleFiles(files) {
            for (let file of files) {
                uploadFile(file);
            }
        }

        function uploadFile(file) {
            const item = document.createElement('div');
            item.className = 'file-item uploading';
            item.innerHTML = `
                <div class="file-name">${file.name}<div class="file-path">Uploading...</div></div>
                <span class="file-status status-uploading">Uploading</span>
            `;
            fileList.prepend(item);

            const formData = new FormData();
            formData.append('file', file);

            fetch('/upload', {
                method: 'POST',
                body: formData
            })
            .then(r => r.json())
            .then(data => {
                if (data.success) {
                    item.className = 'file-item success';
                    item.innerHTML = `
                        <div class="file-name">${file.name}<div class="file-path">${data.path}</div></div>
                        <span class="file-status status-success">Uploaded</span>
                    `;
                    loadRecentFiles();
                } else {
                    throw new Error(data.error);
                }
            })
            .catch(err => {
                item.className = 'file-item error';
                item.innerHTML = `
                    <div class="file-name">${file.name}<div class="file-path">${err.message}</div></div>
                    <span class="file-status status-error">Failed</span>
                `;
            });
        }

        function loadRecentFiles() {
            fetch('/files')
                .then(r => r.json())
                .then(files => {
                    const list = document.getElementById('recentList');
                    if (files.length === 0) {
                        list.innerHTML = '<div style="color:#666">No files yet</div>';
                        return;
                    }
                    list.innerHTML = files.slice(0, 10).map(f =>
                        `<div class="file-item"><div class="file-name"><code>${f.path}</code><div class="file-path">${f.size} - ${f.time}</div></div></div>`
                    ).join('');
                });
        }

        loadRecentFiles();
    </script>
</body>
</html>
"""

class UploadHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        print(f"[{datetime.now().strftime('%H:%M:%S')}] {args[0]}")

    def send_json(self, data, status=200):
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(json.dumps(data).encode())

    def do_GET(self):
        if self.path == '/':
            self.send_response(200)
            self.send_header('Content-Type', 'text/html')
            self.end_headers()
            self.wfile.write(HTML_PAGE.encode())
        elif self.path == '/files':
            files = []
            if UPLOAD_DIR.exists():
                for f in sorted(UPLOAD_DIR.iterdir(), key=lambda x: x.stat().st_mtime, reverse=True):
                    if f.is_file():
                        stat = f.stat()
                        size = stat.st_size
                        size_str = f"{size} B" if size < 1024 else f"{size/1024:.1f} KB" if size < 1024*1024 else f"{size/1024/1024:.1f} MB"
                        files.append({
                            'name': f.name,
                            'path': str(f),
                            'size': size_str,
                            'time': datetime.fromtimestamp(stat.st_mtime).strftime('%Y-%m-%d %H:%M:%S')
                        })
            self.send_json(files)
        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        if self.path == '/upload':
            try:
                content_type = self.headers.get('Content-Type', '')

                if 'multipart/form-data' in content_type:
                    form = cgi.FieldStorage(
                        fp=self.rfile,
                        headers=self.headers,
                        environ={'REQUEST_METHOD': 'POST', 'CONTENT_TYPE': content_type}
                    )

                    if 'file' not in form:
                        self.send_json({'success': False, 'error': 'No file provided'}, 400)
                        return

                    file_item = form['file']
                    filename = file_item.filename
                    data = file_item.file.read()

                    # Sanitize filename
                    filename = re.sub(r'[^\w\-_\.]', '_', filename)

                    # Add timestamp to avoid overwrites
                    base, ext = os.path.splitext(filename)
                    timestamp = datetime.now().strftime('%Y%m%d_%H%M%S')
                    filename = f"{base}_{timestamp}{ext}"

                    # Ensure upload directory exists
                    UPLOAD_DIR.mkdir(parents=True, exist_ok=True)

                    # Save file
                    filepath = UPLOAD_DIR / filename
                    filepath.write_bytes(data)

                    print(f"Saved: {filepath} ({len(data)} bytes)")
                    self.send_json({'success': True, 'path': str(filepath), 'size': len(data)})
                else:
                    self.send_json({'success': False, 'error': 'Invalid content type'}, 400)

            except Exception as e:
                print(f"Upload error: {e}")
                self.send_json({'success': False, 'error': str(e)}, 500)
        else:
            self.send_response(404)
            self.end_headers()

def main():
    UPLOAD_DIR.mkdir(parents=True, exist_ok=True)

    server = HTTPServer(('0.0.0.0', PORT), UploadHandler)
    print(f"Upload server running at http://localhost:{PORT}")
    print(f"Files will be saved to: {UPLOAD_DIR}")
    print("Press Ctrl+C to stop")

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down...")
        server.shutdown()

if __name__ == '__main__':
    main()
