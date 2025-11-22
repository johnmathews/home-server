#!/usr/bin/env python3
"""
Mock Uptime Kuma API server for testing sleep_hours role
Simulates monitor pause/resume operations
"""

import json
import os
import sys
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse

# Server configuration
PORT = int(os.getenv('KUMA_MOCK_PORT', 3001))

# In-memory state
class KumaState:
    def __init__(self):
        self.monitors = {
            1: {'id': 1, 'name': 'test-nginx-1', 'active': True, 'paused': False},
            2: {'id': 2, 'name': 'test-nginx-2', 'active': True, 'paused': False},
            36: {'id': 36, 'name': 'paperless-webserver', 'active': True, 'paused': False},
            43: {'id': 43, 'name': 'tubearchivist', 'active': True, 'paused': False},
        }
        self.authenticated = False
        self.token = 'mock-token-12345'

    def pause_monitor(self, monitor_id):
        if monitor_id in self.monitors:
            self.monitors[monitor_id]['paused'] = True
            return True
        return False

    def resume_monitor(self, monitor_id):
        if monitor_id in self.monitors:
            self.monitors[monitor_id]['paused'] = False
            return True
        return False

# Global state
state = KumaState()

class KumaMockHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        sys.stderr.write(f"[Kuma Mock] {self.address_string()} - {format % args}\n")

    def send_json_response(self, code, data):
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(json.dumps(data).encode())

    def check_auth(self):
        """Check if request is authenticated"""
        auth_header = self.headers.get('Authorization', '')
        if auth_header == f'Bearer {state.token}':
            return True
        return False

    def do_POST(self):
        """Handle POST requests"""
        parsed = urlparse(self.path)
        path = parsed.path

        # Read request body
        content_length = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(content_length).decode()

        try:
            data = json.loads(body) if body else {}
        except json.JSONDecodeError:
            self.send_json_response(400, {'error': 'Invalid JSON'})
            return

        # Login endpoint (no auth required)
        if path == '/api/login':
            username = data.get('username')
            password = data.get('password')
            if username == 'test' and password == 'test':
                state.authenticated = True
                self.send_json_response(200, {
                    'token': state.token,
                    'username': username
                })
            else:
                self.send_json_response(401, {'error': 'Invalid credentials'})
            return

        # All other endpoints require auth
        if not self.check_auth():
            self.send_json_response(401, {'error': 'Unauthorized'})
            return

        # Pause monitor
        if path.startswith('/api/monitor/') and path.endswith('/pause'):
            monitor_id = int(path.split('/')[3])
            if state.pause_monitor(monitor_id):
                self.log_message(f"Monitor {monitor_id} paused")
                self.send_json_response(200, {'ok': True, 'msg': 'Monitor paused'})
            else:
                self.send_json_response(404, {'error': 'Monitor not found'})
            return

        # Resume monitor
        if path.startswith('/api/monitor/') and path.endswith('/resume'):
            monitor_id = int(path.split('/')[3])
            if state.resume_monitor(monitor_id):
                self.log_message(f"Monitor {monitor_id} resumed")
                self.send_json_response(200, {'ok': True, 'msg': 'Monitor resumed'})
            else:
                self.send_json_response(404, {'error': 'Monitor not found'})
            return

        self.send_json_response(404, {'error': f'Unknown endpoint: {path}'})

    def do_GET(self):
        """Handle GET requests"""
        parsed = urlparse(self.path)
        path = parsed.path

        # Check auth
        if not self.check_auth():
            self.send_json_response(401, {'error': 'Unauthorized'})
            return

        # Get all monitors
        if path == '/api/monitors':
            self.send_json_response(200, list(state.monitors.values()))
            return

        self.send_json_response(404, {'error': f'Unknown endpoint: {path}'})

def run_server():
    server = HTTPServer(('0.0.0.0', PORT), KumaMockHandler)
    print(f'Uptime Kuma Mock API running on http://localhost:{PORT}')
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print('\nShutting down...')
        server.shutdown()

if __name__ == '__main__':
    run_server()
