#!/usr/bin/env python3
"""
Mock TrueNAS SCALE REST API server for testing sleep_hours role
Implements TrueNAS API v2.0 endpoints for NFS/SMB share control
"""

import json
import os
import sys
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs

# Server configuration
PORT = int(os.getenv('TRUENAS_MOCK_PORT', 8888))
FAILURE_MODE = os.getenv('TRUENAS_MOCK_FAIL_MODE', None)  # None, 'timeout', '404', '500'
FAILURE_RATE = float(os.getenv('TRUENAS_MOCK_FAIL_RATE', 0.0))  # 0.0-1.0

# In-memory state storage
class TrueNASState:
    def __init__(self):
        self.nfs_shares = [
            {'id': 1, 'path': '/mnt/tank/downloads', 'enabled': True, 'comment': 'Test downloads'},
            {'id': 2, 'path': '/mnt/tank/media', 'enabled': True, 'comment': 'Test media'},
            {'id': 3, 'path': '/mnt/tank/paperless', 'enabled': True, 'comment': 'Test paperless'},
            {'id': 4, 'path': '/mnt/tank/youtube-kids', 'enabled': True, 'comment': 'Test youtube'},
        ]
        self.smb_shares = [
            {'id': 10, 'path': '/mnt/tank/paperless', 'enabled': True, 'name': 'paperless'},
        ]
        self.request_count = 0

    def get_nfs_share(self, share_id):
        for share in self.nfs_shares:
            if share['id'] == share_id:
                return share
        return None

    def get_smb_share(self, share_id):
        for share in self.smb_shares:
            if share['id'] == share_id:
                return share
        return None

    def update_nfs_share(self, share_id, data):
        share = self.get_nfs_share(share_id)
        if share:
            share.update(data)
            return share
        return None

    def update_smb_share(self, share_id, data):
        share = self.get_smb_share(share_id)
        if share:
            share.update(data)
            return share
        return None

# Global state
state = TrueNASState()

class TrueNASMockHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        # Log to stderr with timestamp
        sys.stderr.write(f"[TrueNAS Mock] {self.address_string()} - {format % args}\n")

    def should_fail(self):
        """Check if this request should fail based on failure mode"""
        if FAILURE_MODE:
            state.request_count += 1
            if FAILURE_RATE > 0:
                import random
                return random.random() < FAILURE_RATE
            return True
        return False

    def send_json_response(self, code, data):
        """Send JSON response"""
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(json.dumps(data).encode())

    def send_error_response(self, code, message):
        """Send error response"""
        self.send_json_response(code, {'error': message})

    def do_GET(self):
        """Handle GET requests"""
        parsed = urlparse(self.path)
        path = parsed.path

        # Check for simulated failures
        if self.should_fail():
            if FAILURE_MODE == 'timeout':
                import time
                time.sleep(30)  # Simulate timeout
                return
            elif FAILURE_MODE == '404':
                self.send_error_response(404, 'Share not found')
                return
            elif FAILURE_MODE == '500':
                self.send_error_response(500, 'Internal server error')
                return

        # Health check endpoint
        if path == '/api/v2.0/system/info':
            self.send_json_response(200, {
                'version': 'TrueNAS-SCALE-24.10.2.3-MOCK',
                'hostname': 'truenas-mock',
                'uptime_seconds': 12345
            })
            return

        # List all NFS shares
        if path == '/api/v2.0/sharing/nfs':
            self.send_json_response(200, state.nfs_shares)
            return

        # List all SMB shares
        if path == '/api/v2.0/sharing/smb':
            self.send_json_response(200, state.smb_shares)
            return

        # Get specific NFS share
        if path.startswith('/api/v2.0/sharing/nfs/id/'):
            share_id = int(path.split('/')[-1])
            share = state.get_nfs_share(share_id)
            if share:
                self.send_json_response(200, share)
            else:
                self.send_error_response(404, f'NFS share {share_id} not found')
            return

        # Get specific SMB share
        if path.startswith('/api/v2.0/sharing/smb/id/'):
            share_id = int(path.split('/')[-1])
            share = state.get_smb_share(share_id)
            if share:
                self.send_json_response(200, share)
            else:
                self.send_error_response(404, f'SMB share {share_id} not found')
            return

        # Unknown endpoint
        self.send_error_response(404, f'Unknown endpoint: {path}')

    def do_PUT(self):
        """Handle PUT requests"""
        parsed = urlparse(self.path)
        path = parsed.path

        # Read request body
        content_length = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(content_length).decode()

        try:
            data = json.loads(body) if body else {}
        except json.JSONDecodeError:
            self.send_error_response(400, 'Invalid JSON')
            return

        # Check for simulated failures
        if self.should_fail():
            if FAILURE_MODE == 'timeout':
                import time
                time.sleep(30)
                return
            elif FAILURE_MODE == '500':
                self.send_error_response(500, 'Internal server error')
                return

        # Update NFS share
        if path.startswith('/api/v2.0/sharing/nfs/id/'):
            share_id = int(path.split('/')[-1])
            share = state.update_nfs_share(share_id, data)
            if share:
                self.log_message(f"NFS share {share_id} updated: enabled={share['enabled']}")
                self.send_json_response(200, share)
            else:
                self.send_error_response(404, f'NFS share {share_id} not found')
            return

        # Update SMB share
        if path.startswith('/api/v2.0/sharing/smb/id/'):
            share_id = int(path.split('/')[-1])
            share = state.update_smb_share(share_id, data)
            if share:
                self.log_message(f"SMB share {share_id} updated: enabled={share['enabled']}")
                self.send_json_response(200, share)
            else:
                self.send_error_response(404, f'SMB share {share_id} not found')
            return

        # Unknown endpoint
        self.send_error_response(404, f'Unknown endpoint: {path}')

    def do_PATCH(self):
        """Handle PATCH requests (should return 405 - Method Not Allowed)"""
        self.send_response(405)
        self.send_header('Allow', 'GET, PUT, DELETE')
        self.end_headers()

def run_server():
    server = HTTPServer(('0.0.0.0', PORT), TrueNASMockHandler)
    print(f'TrueNAS Mock API running on http://localhost:{PORT}')
    print(f'Failure mode: {FAILURE_MODE or "none"}')
    print(f'Failure rate: {FAILURE_RATE}')
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print('\nShutting down...')
        server.shutdown()

if __name__ == '__main__':
    run_server()
