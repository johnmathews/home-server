# AdGuard

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
