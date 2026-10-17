#!/usr/bin/env bash
# Startup cost, measured and guarded.
#
# Slow is a silent failure: no error, nothing to grep for, just "things feel a
# bit sluggish" — which is how the .zshrc completion-cache bug survived months.
#
# AN HONEST NOTE ON WHAT THAT BUG ACTUALLY COST. This suite was written on the
# premise that it made every shell 3x slower. Measured properly, it did not.
# A/B on this machine, 15 runs each after a warm-up:
#
#   compinit -C (cached, current)   72ms
#   always full compinit            80ms
#
# So the fix is worth ~8ms per shell. The 210ms figure that justified this suite
# came from a profiling run where ZDOTDIR was redirected, which changed fpath and
# forced a dump rebuild — an artifact of the measurement, not the bug. The
# original fix was still right (a cache that is never revalidated goes stale and
# the security check never runs), but it was never a performance story and this
# file should not pretend otherwise.
#
# The thresholds below therefore guard against something else: a change that
# makes startup several times more expensive — an eagerly loaded plugin, nvm
# loading at startup rather than on first use, a network call in the prompt.
# That class is real, and nothing here would currently notice it.
#
# WHY THE WARM PATH. compinit rebuilds its dump once a day by design, and that
# rebuild is genuinely expensive. Timing a cold shell would fire once every
# morning and be right for the wrong reason, so every measurement warms up first
# and then times the steady state.
#
# The numbers are printed whether or not they pass, so a slow creep is visible
# long before it trips anything.

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Declared slow: repeats an expensive command many times, and runs the fast
# suite itself. `tests/run.sh --fast` skips these, and so does the pre-push
# hook; CI runs the complete set.
# shellcheck disable=SC2034  # read by run.sh with grep, not by this shell
SUITE_SLOW=1

RUNS=15

# Median of RUNS timings, in milliseconds, after a discarded warm-up.
# Median rather than mean: one scheduler hiccup should not move the number, and
# on a shared CI runner there will be hiccups.
measure() { # $@ = command to time
  RUNS="$RUNS" python3 - "$@" <<'MEASURE_EOF'
import os, subprocess, sys, time, statistics
cmd = sys.argv[1:]
subprocess.run(cmd, capture_output=True)  # warm-up, discarded
xs = []
for _ in range(int(os.environ["RUNS"])):
    t0 = time.time()
    subprocess.run(cmd, capture_output=True)
    xs.append((time.time() - t0) * 1000)
print("%d %d %d" % (statistics.median(xs), min(xs), max(xs)))
MEASURE_EOF
}

report() { # $1 = label, $2 = median, $3 = min, $4 = max, $5 = threshold
  printf '    %-22s median %4sms   (min %s, max %s, threshold %s)\n' "$1" "$2" "$3" "$4" "$5"
}

echo "== zsh interactive startup =="
# Threshold reasoning, not taste: 250ms is several times the median printed
# below, loose enough that a loaded CI runner will not flake and tight enough
# that anything making startup several times dearer trips it. No median or
# floor is written here: this comment used to quote both and say there was
# little room to improve, and the next change to .zshrc started shells below
# that floor. The line printed on every run is the one to read.
ZSH_THRESHOLD_MS=250
if command -v zsh >/dev/null 2>&1; then
  read -r med lo hi <<<"$(measure zsh -i -c exit)"
  report "zsh -i -c exit" "$med" "$lo" "$hi" "$ZSH_THRESHOLD_MS"
  if [ "${med:-9999}" -lt "$ZSH_THRESHOLD_MS" ]; then
    ok "zsh starts in ${med}ms, under the ${ZSH_THRESHOLD_MS}ms ceiling"
  else
    no "zsh starts in ${med}ms, over the ${ZSH_THRESHOLD_MS}ms ceiling"
    # A threshold that fires without saying WHERE the time went only tells you
    # something got slower. zprof names the culprit.
    echo "    where the time goes:"
    P="$TEST_TMP/zprof"
    mkdir -p "$P"
    {
      echo 'zmodload zsh/zprof'
      cat "$REPO_ROOT/zsh/.zshrc"
      echo 'zprof | head -6'
    } >"$P/.zshrc"
    ZDOTDIR="$P" zsh -i -c exit 2>/dev/null | sed -n '3,7p' | sed 's/^/      /'
  fi
else
  printf '  \033[33mSKIP\033[0m  zsh is not installed\n'
fi

echo
echo "== neovim startup =="
# Steady-state median here is ~40ms with a stdev near 1ms — the tightest number
# in the repo. 250ms is ~6x that: generous for a slower machine, and still well
# under what a newly eager plugin or a synchronous plugin install would cost.
NVIM_THRESHOLD_MS=250
if command -v nvim >/dev/null 2>&1; then
  read -r med lo hi <<<"$(measure nvim --headless +qa)"
  report "nvim --headless +qa" "$med" "$lo" "$hi" "$NVIM_THRESHOLD_MS"
  if [ "${med:-9999}" -lt "$NVIM_THRESHOLD_MS" ]; then
    ok "nvim starts in ${med}ms, under the ${NVIM_THRESHOLD_MS}ms ceiling"
  else
    no "nvim starts in ${med}ms, over the ${NVIM_THRESHOLD_MS}ms ceiling"
    echo "    plugins loaded at startup:"
    nvim --headless -c 'lua local s = require("lazy").stats(); print(string.format("      %d of %d eager", s.loaded, s.count))' -c qa 2>&1 | tail -1
  fi
else
  printf '  \033[33mSKIP\033[0m  nvim is not installed\n'
fi

echo
echo "== which plugins load eagerly, by name =="
# Time is the WRONG signal for this and the mutation proved it: making telescope
# eager cost 7ms, invisible against a 250ms ceiling, and a ceiling tight enough
# to see it would flake on any loaded machine. The eager SET is deterministic,
# so assert that instead. Adding an eager plugin is then loud and named, which
# is what was actually wanted.
#
# rose-pine must be eager — a colorscheme that loads late means an unstyled
# flash. lazy.nvim is the loader itself. Nothing else needs to be.
#
# Until 99 had its keys declared as lazy `keys`, this set was six, and the four
# extra are the reason the failure branch below exists. 99 had no lazy trigger,
# so it loaded at start, and nvim-cmp came with it even though cmp DOES declare
# one (event = "InsertEnter"): 99's config calls require("cmp") while it loads,
# and lazy honours a require by loading that plugin there and then, with
# cmp-buffer and cmp-path as its dependencies. lazy records the reason, which
# is how that was settled rather than guessed:
#
#   require("lazy.core.config").plugins["nvim-cmp"]._.loaded
#     -> { plugin = "99", require = "cmp" }
#
# So the failure branch prints those reasons. "The eager set changed" on its own
# sends you looking through every plugin spec for a trigger that may not be the
# thing that changed at all.
EXPECTED_EAGER="lazy.nvim rose-pine"
if command -v nvim >/dev/null 2>&1; then
  actual="$(nvim --headless \
    -c 'lua local p = require("lazy.core.config").plugins; local n = {}; for k, v in pairs(p) do if v._.loaded then n[#n + 1] = k end end; table.sort(n); print("EAGER:" .. table.concat(n, " "))' \
    -c qa 2>&1 | grep -ao 'EAGER:.*' | head -1 | cut -d: -f2-)"
  printf '    %s\n' "${actual:-(none reported)}"
  if [ "$actual" = "$EXPECTED_EAGER" ]; then
    ok "the set of eagerly loaded plugins is exactly what is expected"
  else
    no "the set of eagerly loaded plugins has changed"
    echo "    why each of them is loaded:"
    nvim --headless \
      -c 'lua local p = require("lazy.core.config").plugins; local o = {}; for k, v in pairs(p) do if v._.loaded then o[#o + 1] = k .. " " .. vim.inspect(v._.loaded):gsub("%s+", " ") end end; table.sort(o); for _, l in ipairs(o) do print("WHY " .. l) end' \
      -c qa 2>&1 | grep -a '^WHY ' | sed 's/^WHY /      /'
  fi
fi

echo
echo "== a new tmux server does not wait for its plugins =="
# tmux.conf runs tpm with -b. In the foreground the first session is not created
# until every plugin's .tmux script has run, and that, not tmux, is most of what
# a new WezTerm window waits for. checks/repo.sh asserts the -b; this measures
# what it is for, with the real tmux.conf and the real installed plugins.
#
# Timed: `new-session -d` on a fresh private server, which is the session a new
# window attaches to. Not timed: the plugins finishing in the background. Each
# start waits for that before the server is killed, both so the next start does
# not race a dying tpm and to prove the plugins loaded at all -- a start that
# loaded no plugins is fast for the wrong reason, so it fails rather than counts.
#
# A scratch HOME, so tpm reads the plugin list from this repo's tmux.conf and
# continuum saves and restores nowhere real; continuum's own halt file there
# stops it attempting a restore at all. The plugins are the installed ones, read
# through a symlink, and their absence is a skip: tmux.conf would otherwise
# clone tpm from the network.
#
# The ceiling sits between the two cases rather than near either: when this was
# written, medians of 15 here were 18ms with -b and 565ms without it. The median
# is printed whether it passes or not, so a creep is visible before it trips.
TMUX_THRESHOLD_MS=250

# Median, min and max of RUNS starts in ms, after a discarded warm-up, and how
# many of the RUNS had the plugins loaded. Every tmux it runs gets the scratch
# HOME and none of the caller's TMUX or XDG variables. A warm-up that loads no
# plugins ends it there: waiting out every run would only say the same thing.
tmux_start() { # $1 = private socket, $2 = tmux.conf, $3 = scratch HOME
  RUNS="$RUNS" python3 - "$@" <<'TMUX_START_EOF'
import os, subprocess, sys, time, statistics
sock, conf, home = sys.argv[1:4]
env = {k: v for k, v in os.environ.items()
       if not k.startswith(("TMUX", "XDG_")) and k != "ZDOTDIR"}
env["HOME"] = home

def tmux(*args):
    return subprocess.run(["tmux", "-L", sock] + list(args), env=env,
                          capture_output=True, text=True)

def tpm_running(pid):
    ps = subprocess.run(["ps", "-Ao", "ppid=,command="],
                        capture_output=True, text=True).stdout
    return any(l.split(None, 1)[0] == pid and "plugins/tpm/tpm" in l
               for l in ps.splitlines() if l.strip())

def loaded():
    keys = tmux("list-keys", "-T", "prefix").stdout
    return "tmux-resurrect/scripts/restore.sh" in keys

def start():
    t0 = time.time()
    tmux("-f", conf, "new-session", "-d")
    ms = (time.time() - t0) * 1000
    pid = tmux("display-message", "-p", "#{pid}").stdout.strip()
    deadline = time.time() + 10
    while time.time() < deadline and (tpm_running(pid) or not loaded()):
        time.sleep(0.05)
    ok = loaded()
    tmux("kill-server")
    while pid.isdigit() and time.time() < deadline + 5:
        try:
            os.kill(int(pid), 0)
        except ProcessLookupError:
            break
        time.sleep(0.02)
    return ms, ok

if not start()[1]:  # warm-up, discarded
    print("0 0 0 0")
    sys.exit()
xs, n = [], 0
for _ in range(int(os.environ["RUNS"])):
    ms, ok = start()
    xs.append(ms)
    n += ok
print("%d %d %d %d" % (statistics.median(xs), min(xs), max(xs), n))
TMUX_START_EOF
}

PLUGINS="$HOME/.config/tmux/plugins"
TMUX_HOME="$TEST_TMP/tmux-home"
mkdir -p "$TMUX_HOME/.config/tmux"
ln -s "$PLUGINS" "$TMUX_HOME/.config/tmux/plugins"
ln -s "$REPO_ROOT/tmux/.config/tmux/tmux.conf" "$TMUX_HOME/.config/tmux/tmux.conf"
: >"$TMUX_HOME/tmux_no_auto_restore"
# The plugins are looked for THROUGH the link, so a link that did not work is a
# skip as well, and never a tmux.conf left to clone tpm into the scratch HOME.
if ! command -v tmux >/dev/null 2>&1; then
  printf '  \033[33mSKIP\033[0m  tmux is not installed\n'
elif [ ! -x "$TMUX_HOME/.config/tmux/plugins/tpm/tpm" ] ||
  [ ! -d "$TMUX_HOME/.config/tmux/plugins/tmux-resurrect" ]; then
  printf '  \033[33mSKIP\033[0m  tpm or tmux-resurrect is not installed in %s\n' "$PLUGINS"
else
  # shellcheck disable=SC2034  # read by tmux_test_teardown in lib.sh
  TMUX_SOCK="$(tmux_test_socket performance)"
  require_private_socket
  trap cleanup_tmux_suite EXIT
  read -r med lo hi loaded <<<"$(tmux_start "$TMUX_SOCK" "$TMUX_HOME/.config/tmux/tmux.conf" "$TMUX_HOME")"
  report "tmux new-session -d" "$med" "$lo" "$hi" "$TMUX_THRESHOLD_MS"
  if [ "${loaded:-0}" -ne "$RUNS" ]; then
    no "the plugins loaded in ${loaded:-0} of $RUNS starts, so the timing is of a server without them"
  elif [ "${med:-9999}" -lt "$TMUX_THRESHOLD_MS" ]; then
    ok "a tmux session exists ${med}ms after the server starts, under the ${TMUX_THRESHOLD_MS}ms ceiling"
  else
    no "a tmux session takes ${med}ms to exist, over the ${TMUX_THRESHOLD_MS}ms ceiling"
  fi
fi

echo
echo "== the completion dump is not rebuilt on every shell =="
# Narrower than it first looked. Reintroducing the original bug did NOT trip
# this, because plain `compinit` only redumps when the dump is actually stale —
# so this catches a rebuild-every-time regression and nothing subtler. The
# BRANCH logic (which of compinit / compinit -C runs, and when) is asserted
# directly in test-zshrc.sh, which is the right place for it; duplicating it
# weakly here would just look like more coverage than there is.
if command -v zsh >/dev/null 2>&1; then
  P="$TEST_TMP/zprof2"
  mkdir -p "$P"
  {
    echo 'zmodload zsh/zprof'
    cat "$REPO_ROOT/zsh/.zshrc"
    echo 'zprof | head -8'
  } >"$P/.zshrc"
  ZDOTDIR="$P" zsh -i -c exit >/dev/null 2>&1 # warm: let it settle the dump
  prof="$(ZDOTDIR="$P" zsh -i -c exit 2>/dev/null)"
  refute "a warm shell does not rebuild the completion dump" contains "$prof" "compdump"
fi

echo
echo "== the pre-push hook stays fast enough to leave switched on =="
# The reason this is measured rather than asserted by comment: the header of
# .githooks/pre-push claimed ~19s for long enough that it became untrue by a
# factor of twelve. The full suite had grown to just over four minutes, which is
# a hook people pass --no-verify to, and a hook that is routinely bypassed is
# worse than none because it still looks like coverage.
#
# So the hook runs --fast, and this keeps that honest. Safe to invoke from here
# and nowhere else: this suite is SUITE_SLOW, so --fast excludes it and the
# nested run cannot re-enter itself.
#
# A minute is the ceiling rather than anything near the measured run, because
# the point is to catch the hook becoming something you avoid, not to fail on a
# busy machine. The measured figure is printed on the line below whether it
# passes or not, which is the only place such a number stays true — writing it
# into this comment is how .githooks/pre-push came to argue from a number that
# was wrong by an order of magnitude.
HOOK_CEILING_S=60
start="$(date +%s)"
"$REPO_ROOT/tests/run.sh" --fast >/dev/null 2>&1
elapsed=$(($(date +%s) - start))
printf '    %-22s %ss   (ceiling %ss)\n' "run.sh --fast" "$elapsed" "$HOOK_CEILING_S"
if [ "$elapsed" -lt "$HOOK_CEILING_S" ]; then
  ok "the pre-push suite runs in ${elapsed}s, fast enough to leave enabled"
else
  no "the pre-push suite takes ${elapsed}s — long enough that it will get bypassed"
  echo "    slowest suites in the fast set:"
  "$REPO_ROOT/tests/run.sh" --fast 2>&1 | grep -B1 '([0-9][0-9]*s)' | tail -6 | sed 's/^/      /'
fi

finish
