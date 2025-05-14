#!/usr/bin/env python3

import subprocess
import time
import re

def parse_radeontop(output):
    metrics = {}
    for line in output.splitlines():
        if "Graphics pipe" in line:
            m = re.search(r"Graphics pipe\s+([0-9.]+)%", line)
            if m:
                metrics["radeontop_graphics_pipe_pct"] = float(m.group(1))
        if "VRAM" in line:
            m = re.search(r"([0-9]+)M / ([0-9]+)M VRAM", line)
            if m:
                used = int(m.group(1))
                total = int(m.group(2))
                metrics["radeontop_vram_used_mb"] = used
                metrics["radeontop_vram_total_mb"] = total
        if "Shader Clock" in line:
            m = re.search(r"([0-9.]+)G / ([0-9.]+)G Shader Clock", line)
            if m:
                used = float(m.group(1))
                total = float(m.group(2))
                metrics["radeontop_shader_clock_ghz"] = used
                metrics["radeontop_shader_clock_max_ghz"] = total
    return metrics

def write_metrics(metrics, path):
    with open(path, 'w') as f:
        for k, v in metrics.items():
            f.write(f"{k} {v}\n")

def main():
    cmd = ["radeontop", "-d", "-", "-l", "1"]
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=5)
    metrics = parse_radeontop(result.stdout)
    write_metrics(metrics, "/var/lib/node_exporter/textfile_collector/radeontop.prom")

if __name__ == "__main__":
    main()
