# VENDORED from nextbsd/nextbsd tests/loader.exp.inc.
#
# Copied rather than reimplemented on purpose. The pacing, the sync-on-OK and
# the boot re-send below are not stylistic -- each one is a specific flaky-run
# fix, and the original file names the runs that produced them. Writing a fresh
# loader handshake here would have rediscovered all three the hard way.
#
# Keep in step with the original if that one changes.

# loader.exp.inc — the FreeBSD loader serial handshake, shared by the generated
# img/ISO expect scripts. `source tests/loader.exp.inc` immediately after the
# qemu spawn, then: loader_prompt <secs> ; loader_set ... ; loader_boot "boot -v".
#
# Lifted from nextbsd-userland's tests/boot-test.sh, which hardened it over
# several flaky runs. The emulated UART (16550 on q35, pl011 on virt) drops the
# odd character in BOTH directions, so:
#   - input is paced at ~25 cps (send -s) rather than dumped at once;
#   - each command syncs on the loader's next "OK " prompt, never on the echo of
#     what we typed (run 26070245676 showed `boot_multicons` echoed back as
#     `boo_multicons` on a command the loader had in fact accepted);
#   - the final `boot` is re-sent if the loader rejects it, because a garbled
#     boot never self-recovers — it just sits at the prompt (run 28754808354).

# ~25 cps: brisk-typist cadence, slow enough for the UART to keep up.
set send_slow {1 .04}

# loader_prompt <secs> — catch the autoboot countdown and stop at the OK prompt.
# Under -display none the loader's default `efi` console routes to serial on both
# arches, so the banner and the prompt come to us over -serial stdio.
proc loader_prompt {secs} {
    global timeout
    set saved $timeout
    set timeout $secs
    expect {
        timeout { puts "\nFAIL: didn't see the loader autoboot prompt within ${secs}s"; exit 1 }
        -re "Hit \\\[Enter\\\]"      { send " " }
        "Booting"                    { send " " }
        -re "FreeBSD/\[a-z0-9\]+ EFI" { send " " }
        "Loading /boot/loader"       { send " " }
    }
    set timeout 30
    expect {
        timeout { puts "\nFAIL: didn't reach the loader OK prompt within 30s"; exit 1 }
        "OK " { puts "\n==> at loader prompt" }
    }
    set timeout $saved
}

# loader_set <cmd> — set one loader variable, robustly.
#   1. settle at the prompt (the loader is still printing when it first appears)
#   2. drain, so we can't latch the PREVIOUS command's OK
#   3. send paced
#   4. sync on the fresh OK
proc loader_set {cmd} {
    global timeout
    set saved $timeout
    set timeout 20
    sleep 0.3
    expect *
    send -s -- "$cmd\r"
    expect {
        timeout { puts "\nFAIL: no OK prompt after '$cmd' within 20s"; exit 1 }
        "OK "
    }
    set timeout $saved
}

# loader_boot <cmd> — issue the final boot command, retrying a garbled send.
# Success = the loader leaves the prompt to load the kernel: no "unknown
# command" and no fresh "OK " inside the settle window.
proc loader_boot {cmd} {
    global timeout
    set saved $timeout
    set timeout 10
    for {set try 1} {$try <= 5} {incr try} {
        sleep 0.3
        expect *
        send -s -- "$cmd\r"
        expect {
            "unknown command" {
                puts "\n==> loader garbled '$cmd' (try $try/5); resending"
                continue
            }
            -re "Booting|/boot/kernel/kernel|Loading kernel|---<<" {
                set timeout $saved
                return
            }
            "OK " {
                puts "\n==> loader still at prompt after '$cmd' (try $try/5); resending"
                continue
            }
            timeout {
                # No reject and no fresh prompt => the kernel is loading.
                set timeout $saved
                return
            }
        }
    }
    puts "\nFAIL: loader never accepted '$cmd' after 5 tries (UART input drop)"
    exit 1
}
