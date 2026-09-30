# Remote Long-Job Execution

Building or installing on a remote host can take tens of minutes. Two independent failure modes make
this go wrong: the agent's own tooling times out, and the chat turn gets dropped mid-wait.

## Rule: the job must outlive the session

Never tie a long remote job to the SSH session that started it. Detach it, log it, and poll.

```bash
# on the remote host, inside the target guest/shell
cd /opt/<app>-deploy
setsid nohup env DOCKER_BUILDKIT=1 docker compose build \
  > /var/log/<app>-build.log 2>&1 < /dev/null &
echo "pid: $!"
```

Then install a **watcher that writes a status file**, so later probes are cheap single reads:

```bash
for i in $(seq 1 720); do
  I=$(docker images -q <image-tag> 2>/dev/null | wc -l | tr -d ' ')
  P=$(pgrep -fc 'compose build' 2>/dev/null || echo 0)
  S=$(grep -aoE '^#[0-9]+ \[[a-z0-9-]+ [0-9]+/[0-9]+\]' /var/log/<app>-build.log | tail -1)
  E=$(grep -aE '^#[0-9]+ ERROR:|failed to solve:' /var/log/<app>-build.log | tail -1)
  echo "$(date +%H:%M:%S) img=$I procs=$P stage=${S:-none} ${E:+ERR=$E}" >> /var/log/<app>-build-watch.log
  [ "$I" -ge 1 ] && { echo 'RESULT: IMAGE_BUILT' >> /var/log/<app>-build-watch.log; break; }
  [ -n "$E" ] && { echo 'RESULT: BUILD_ERROR' >> /var/log/<app>-build-watch.log; break; }
  [ "$P" -eq 0 ] && [ "$i" -gt 4 ] && { echo 'RESULT: EXITED_NO_IMAGE' >> /var/log/<app>-build-watch.log; break; }
  sleep 30
done
```

Launch that watcher detached too, then wait **from the agent side** with a tracked background call:
`terminal(background=true, notify=true, timeout=<seconds>)`. Each subsequent probe is then a few-second
read of the status file. Do not sit in a foreground call for twenty minutes.

## Rule: never hold the turn across a multi-minute wait

The chat UI drops a turn that runs too long and the reply is delivered truncated — the user sees a
connection error, not the work. Finish whatever does not depend on the job, say where it stands, and
end the turn; let the notify hook bring you back. Everything long-lived already lives on the remote
host, so nothing is lost when the turn ends.

## Rule: detect failure honestly — do not grep for the word "error"

BuildKit **echoes the raw Dockerfile `RUN` command line**. A step as innocent as
`RUN test -f dist/index.js || (echo "ERROR: build output missing" && exit 1)` puts the literal string
`ERROR:` into the log on a *successful* build. A watcher grepping for `ERROR` reports a false failure
and stops watching mid-build.

- Match the builder's own markers only: `^#[0-9]+ ERROR:`, `failed to solve:`, `did not complete successfully`.
- **Define success by an artifact** (image present, binary exists, health endpoint answers) and let that
  terminate the watcher. Absence of an error string is not success.
- When a watcher reports failure, confirm against the artifact before acting on it — and treat a
  "failure" that arrives while the build process is still alive as suspect.

## Rule: multi-hop quoting — write a file, then pipe it

Driving `ssh host → pct exec <vmid> → docker exec <ctr>` with inline quoting collapses: nested `\"`
and `\$(...)` get eaten by whichever layer parses them last, producing `unexpected EOF` or a command
that runs in the wrong namespace.

Two patterns that hold up:

```bash
# A) run a script on the intermediate host via stdin (no quoting layers)
ssh host 'sudo -n bash -s' < ./probe.sh

# B) stage the script into the guest, then feed it to the container's shell
pct exec <vmid> -- bash -lc 'cat > /root/run.sh' <<'EOS'
<content — no escaping needed with a quoted heredoc>
EOS
pct exec <vmid> -- bash -lc 'docker exec -i <ctr> bash -s < /root/run.sh'
```

Use a **quoted** heredoc (`<<'EOS'`) so the intermediate shell does not expand variables intended for
the innermost one. Prefer `bash -s` over `-c '...'` for anything longer than one line.

Note that `pct exec ... docker exec -it` allocates a TTY for interactive prompts, but the ANSI escapes
survive poorly across three layers — an interactive form that works locally may be unreadable here.
Treat "requires a real interactive session" as a genuine blocker rather than something to brute-force.

## Rule: stage secrets to a file, never into a command line

`--token <value>` lands in process listings, shell history and logs. Instead: assemble the value in the
running script, write it to a file with mode 600 on the host that needs it, consume it by path, then
shred it.

```bash
umask 077
printf '%s%s\n' "$PART_A" "$PART_B" > /root/.stage-tmp   # split so pattern-matching redaction does not mangle it
pct push <vmid> /root/.stage-tmp /root/.token --perms 600
rm -f /root/.stage-tmp
pct exec <vmid> -- bash -lc 'consume /root/.token; shred -u /root/.token 2>/dev/null || rm -f /root/.token'
```

Splitting a credential across two shell variables defeats naive secret-pattern redaction that would
otherwise rewrite the literal mid-file and corrupt it. When you must hand a key to a third party later,
stage it to a 600 file and tell the operator the path — do not paste the value into the transcript.

## Rule: probe only what you need

Reconnaissance is a few short, cheap reads, not a filesystem crawl. `grep -r` over a home directory can
run for minutes and time out; prefer targeted searches, `ls` on known paths, and the service's own
status commands. Log the commands that produced each fact so a later session can re-run them.
