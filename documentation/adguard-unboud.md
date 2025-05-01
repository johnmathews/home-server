# AdGuard + Unbound

The router uses AdGuard as its DNS resolver.

AdGuard uses Unbound to resolve DNS recursively. 

To check-in or check up on the services, ssh into the LXC and then:

1. `systemctl status unbound`
2. Test DNS resolution:

    `dig @127.0.0.1 -p 5335 www.example.com`.

     You should see:

     ;; ANSWER SECTION: www.example.com. 3600 IN A 93.184.216.34

3. Test DNSSEC validation:

    `dig @127.0.0.1 -p 5335 dnssec-failed.org`

     You should see `status: SERVFAIL` if its working correctly. If it returns an
     IP then DNSSEC is not being enforced.

4. Get some stats: `unbound-control stats_noreset`
   - look for `total.num.queries`, `total.num.cachehits`, `total.num.cachemiss`
   - if `time.up` is low (its in seconds) then cache hits will be low.

## Unbound

### 📘 What Unbound Does

1. Recursive DNS Resolution

Unbound doesn’t forward queries to other DNS servers (like Google or Cloudflare) by default. Instead, it:
	•	Starts from the root DNS servers
	•	Walks down the hierarchy (root → TLD → authoritative servers)
	•	Gets the final answer directly

This gives you:
	•	More privacy
	•	Less dependence on third parties
	•	More control over DNS behavior

⸻

2. DNSSEC Validation

If DNSSEC is enabled (as it now is in your setup), Unbound:
	•	Verifies that DNS responses are digitally signed
	•	Rejects tampered or spoofed data

⸻

3. Caching

Unbound stores DNS responses locally:
	•	If a domain has already been resolved, it answers immediately from cache
	•	Greatly reduces latency and upstream traffic
	•	You can tune cache TTLs and size

⸻

4. Hardened DNS Behavior

It supports:
	•	Query minimization (leaks less data to upstream servers)
	•	Blocking malicious response patterns (e.g., DNS rebinding)
	•	DNS-over-TLS (if desired)
	•	Prefetching for faster results
