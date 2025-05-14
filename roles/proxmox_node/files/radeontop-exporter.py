#!/usr/bin/env python3

import subprocess
import re

def parse_line(line):
    metrics = {}
    # Example line:
    # 1747215707.203284: bus 08, gpu 0.00%, ee 0.00%, ..., vram 0.83% 16.70mb, gtt 0.06% 12.11mb, mclk 80.17% 1.069ghz, sclk 21.05% 0.400ghz
    m_gpu = re.search(r'gpu ([0-9.]+)%', line)
    m_vram_used = re.search(r'vram [0-9.]+% ([0-9.]+)mb', line)
    m_gtt_used = re.search(r'gtt [0-9.]+% ([0-9.]+)mb', line)
    m_mclk = re.search(r'mclk [0-9.]+% ([0-9.]+)ghz', line)
    m_sclk = re.search(r'sclk [0-9.]+% ([0-9.]+)ghz', line)

    if m_gpu:
        metrics["radeontop_gpu_percent"] = float(m_gpu.group(1))
    if m_vram_used:
        metrics["radeontop_vram_used_mb"] = float(m_vram_used.group(1))
    if m_gtt_used:
        metrics["radeontop_gtt_used_mb"] = float(m_gtt_used.group(1))
    if m_mclk:
        metrics["radeontop_memory_clock_ghz"] = float(m_mclk.group(1))
    if m_sclk:
        metrics["radeontop_shader_clock_ghz"] = float(m_sclk.group(1))

    return metrics

def write_metrics(metrics, path):
    with open(path, 'w') as f:
        for k, v in metrics.items():
            f.write(f"{k} {v}\n")

def main():
    try:
        result = subprocess.run(
            ["radeontop", "-d", "-", "-l", "1"],
            capture_output=True, text=True, timeout=5
        )
        metrics = parse_line(result.stdout.strip())
        write_metrics(metrics, "/var/lib/node_exporter/textfile_collector/radeontop.prom")
    except Exception as e:
        print(f"Error: {e}")

if __name__ == "__main__":
    main()
