/**
 * Doorbell push-to-talk enhancement for Home Assistant.
 *
 * Deployed as a Lovelace resource (type: module) encoded as a data: URL —
 * see documentation/doorbell.md § "The injected script" for build/deploy steps.
 * This file is the readable reference source; the deployed copy is this code
 * minified into the data: URL. Keep them in sync.
 *
 * What it does, per webrtc-camera card:
 *  - viewer part (media includes "video"):
 *      · auto-unmute after playback starts; if the browser blocks it
 *        (autoplay policy), re-mute and resume, then unmute on first tap
 *        anywhere on the page (a user gesture unlocks audio).
 *  - push-to-talk part (media includes "microphone"):
 *      · the card acquires a mic at mount to negotiate the WebRTC sendonly
 *        transceiver; we immediately detach AND stop that track, so the
 *        browser's recording indicator is off while idle.
 *      · a "🎤 Hold to talk" button is injected into the card. While held:
 *        fresh getUserMedia (inside the gesture — required by iOS), attach
 *        via sender.replaceTrack, mute all incoming audio (half-duplex, no
 *        echo). On release: detach, stop the track, restore audio.
 *      · if the card has no audio sender (iOS: mount-time getUserMedia is
 *        rejected outside a gesture), the first hold acquires permission
 *        and reconnects the card — the user sees "hold again to talk" once.
 *      · a grey diagnostics bar shows pc/sender/holding state and outbound
 *        audio byte count (from RTCPeerConnection.getStats).
 *
 * Server-side counterpart (go2rtc config inside HA): the camera's MAIN
 * stream has #backchannel=0 so talkback routes through the dedicated
 * on-demand sub-stream session (#backchannel=1) — dialed fresh per use,
 * hung up after. Piggybacking talkback on the permanent main session let a
 * wedged camera talkback survive browser refreshes.
 */
customElements.whenDefined('webrtc-camera').then(() => {
    const C = customElements.get('webrtc-camera');
    const origOninit = C.prototype.oninit;
    // all viewer <video> elements, for half-duplex muting during transmission
    const A = window.__dbA = window.__dbA || new Set();

    const enhance = el => {
        if (el.__dbe) return; // idempotent — retrofit walker may revisit
        el.__dbe = 1;
        const v = el.video;
        if (!v) return;
        const media = (el.config && el.config.media) || '';

        // ---------- viewer behaviors ----------
        if (media.includes('video')) {
            A.add(v);
            const tap = () => { if (v.muted) v.muted = false; };
            document.addEventListener('pointerdown', tap, {once: true, capture: true});
            // after every (re)start of playback, attempt unmute; revert if the
            // browser objects (it pauses the video when unmuted play is not allowed)
            v.addEventListener('playing', () => {
                if (!v.muted || window.__dbTx) return;
                v.muted = false;
                setTimeout(() => {
                    if (v.paused) { v.muted = true; v.play().catch(() => {}); }
                }, 300);
            });
            if (!v.paused && v.muted) {
                v.muted = false;
                setTimeout(() => {
                    if (v.paused) { v.muted = true; v.play().catch(() => {}); }
                }, 300);
            }
        }

        // ---------- push-to-talk ----------
        if (!media.includes('microphone')) return;

        let tx = false;                 // currently transmitting (button held)
        const M = {s: null, t: null};   // s: RTCRtpSender, t: active mic track
        let sent = 0;                   // outbound audio bytes (getStats)
        const root = el.shadowRoot || el;

        const msg = t => {              // red error/status banner
            let d = el.__dbm;
            if (!d) {
                d = el.__dbm = document.createElement('div');
                d.style.cssText = 'color:#fff;background:#b71c1c;font:14px sans-serif;'
                    + 'padding:6px;border-radius:4px;position:relative;z-index:9';
                root.appendChild(d);
            }
            d.textContent = t;
            d.style.display = t ? 'block' : 'none';
        };

        const btn = document.createElement('div');
        btn.textContent = '🎤 Hold to talk';
        btn.style.cssText = 'display:flex;align-items:center;justify-content:center;'
            + 'background:#1565c0;color:#fff;font:600 17px sans-serif;padding:14px;'
            + 'margin-top:4px;border-radius:8px;cursor:pointer;touch-action:none;'
            + 'user-select:none;-webkit-user-select:none;position:relative;z-index:9';
        root.appendChild(btn);

        const dbg = document.createElement('div');
        dbg.style.cssText = 'color:#ddd;background:#333;font:11px monospace;'
            + 'padding:3px 8px;margin-top:4px;border-radius:8px;position:relative;z-index:9';
        root.appendChild(dbg);

        // who-is-talking: mirror PTT state into input_text.doorbell_talker so
        // other household members see (and get notified) who answered
        const TALKER = 'input_text.doorbell_talker';
        const hassObj = () => {
            const ha = document.querySelector('home-assistant');
            return ha && ha.hass;
        };
        const setTalker = value => {
            const h = hassObj();
            if (h) h.callService('input_text', 'set_value',
                {entity_id: TALKER, value: value}).catch(() => {});
        };
        const talkerBanner = document.createElement('div');
        talkerBanner.style.cssText = 'display:none;align-items:center;justify-content:center;'
            + 'color:#fff;background:#e65100;font:600 15px sans-serif;padding:8px;'
            + 'margin-top:4px;border-radius:8px;position:relative;z-index:9';
        root.appendChild(talkerBanner);
        const updateTalkerBanner = () => {
            const h = hassObj();
            const st = h && h.states && h.states[TALKER];
            const name = st ? st.state : '';
            // hide while WE are the one talking (button already shows it)
            if (name && name !== 'unknown' && !tx) {
                talkerBanner.textContent = '🎙 ' + name + ' is talking to the visitor';
                talkerBanner.style.display = 'flex';
            } else {
                talkerBanner.style.display = 'none';
            }
        };
        window.addEventListener('pagehide', () => { if (tx) setTalker(''); });

        // half-duplex: mute/unmute every registered viewer video
        const rx = m => {
            window.__dbTx = m;
            A.forEach(x => { if (x.isConnected) x.muted = m; });
        };

        const stats = async () => {
            if (!el.pc) return;
            try {
                const st = await el.pc.getStats();
                st.forEach(s => {
                    if (s.type === 'outbound-rtp' && s.kind === 'audio') sent = s.bytesSent || 0;
                });
            } catch (e) {}
        };

        // adopt the sender the card negotiated; when idle, detach + stop its
        // mount-time track so the mic indicator turns off
        const cap = () => {
            if (!el.pc) return;
            el.pc.getSenders().forEach(s => {
                if (s !== M.s && s.track && s.track.kind === 'audio') {
                    M.s = s;
                    if (tx) {
                        M.t = s.track;
                    } else {
                        const t = s.track;
                        s.replaceTrack(null).then(() => t.stop()).catch(() => t.stop());
                    }
                }
            });
        };

        const iv = setInterval(() => {
            if (!el.isConnected) {           // card unmounted: clean up
                clearInterval(iv);
                if (tx) rx(false);
                if (M.t) { M.t.stop(); M.t = null; }
                return;
            }
            cap();
            stats();
            updateTalkerBanner();
            dbg.textContent = 'PTT v11 | pc:' + (el.pc ? 'yes' : 'NO')
                + ' | sender:' + (M.s ? 'yes' : 'NO')
                + ' | holding:' + tx
                + ' | sent:' + (sent / 1024).toFixed(1) + 'kB';
        }, 400);

        const stopTalk = () => {
            if (!tx) return;
            tx = false;
            btn.textContent = '🎤 Hold to talk';
            btn.style.background = '#1565c0';
            if (M.t) { M.t.stop(); M.t = null; }        // release the mic
            if (M.s) M.s.replaceTrack(null).catch(() => {});
            rx(false);
            setTalker('');
        };

        btn.addEventListener('contextmenu', e => e.preventDefault());
        btn.addEventListener('pointerdown', e => {
            e.preventDefault();
            e.stopPropagation();
            if (tx) return;
            tx = true;
            btn.textContent = '🔴 TRANSMITTING — release to stop';
            btn.style.background = '#b71c1c';
            rx(true);
            msg('');
            const h = hassObj();
            setTalker((h && h.user && h.user.name) || 'someone');
            // http (non-localhost) pages have no navigator.mediaDevices at all —
            // e.g. the companion app connecting via an internal http:// URL
            if (!navigator.mediaDevices || !window.isSecureContext) {
                msg('Microphone blocked: insecure connection (http). '
                    + 'Open HA via its https address — in the companion app, set the '
                    + 'internal URL to https or disable it.');
                stopTalk();
                return;
            }
            // getUserMedia INSIDE the gesture — required by iOS WebKit
            navigator.mediaDevices.getUserMedia({audio: true}).then(st => {
                if (!tx) { st.getTracks().forEach(t => t.stop()); return; }
                const t = st.getAudioTracks()[0];
                if (M.s) {
                    M.t = t;
                    M.s.replaceTrack(t).catch(e => { msg('replaceTrack: ' + e.name); stopTalk(); });
                } else {
                    // no sender (iOS: mount-time gUM was rejected) — now that
                    // permission is granted, reconnect so the card renegotiates
                    // with an audio transceiver
                    t.stop();
                    msg('Reconnecting — hold again to talk');
                    el.ondisconnect();
                    el.onconnect();
                    setTimeout(() => { msg(M.s ? '' : 'Mic not attached — reload page'); }, 2500);
                    stopTalk();
                }
            }).catch(err => {
                msg('Microphone error: ' + err.name + ' — ' + err.message);
                stopTalk();
            });
        });
        // release anywhere — finger may drift off the button
        ['pointerup', 'pointercancel'].forEach(t => document.addEventListener(t, stopTalk));
    };

    // patch future instances…
    C.prototype.oninit = function () {
        origOninit.call(this);
        enhance(this);
    };
    // …and retrofit instances rendered before this module loaded (load-order
    // race: HA renders cards while resources are still loading)
    const walk = r => {
        r.querySelectorAll('*').forEach(n => {
            if (n.tagName === 'WEBRTC-CAMERA') enhance(n);
            if (n.shadowRoot) walk(n.shadowRoot);
        });
    };
    [0, 800, 2500, 8000].forEach(t => setTimeout(() => walk(document), t));
});
