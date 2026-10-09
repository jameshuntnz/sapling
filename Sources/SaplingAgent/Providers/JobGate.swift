import Foundation

/// A job-started hook that refuses, inside the guest, any job whose code did
/// not come from the watched repository.
///
/// `ForkPolicy` decides which jobs Sapling *starts a runner for*, but a JIT
/// runner takes whichever queued job in the repository matches its labels. A
/// refused fork job stays queued with labels its author chose, so without this
/// the next runner minted for a legitimate job could run it. The runner calls
/// the hook before any step, so a failing hook means none of the job runs.
enum JobGate {
    /// Shell that writes the hook and points the runner at it.
    ///
    /// Must run after `cd` into the runner directory: the hook reads the event
    /// payload with the Node.js the runner ships in `externals`, the one JSON
    /// parser every runner install is guaranteed to have.
    ///
    /// - Parameter repo: The watched repository, `owner/repo`.
    /// - Returns: Shell to splice into the runner's start script.
    static func installScript(repo: String) -> String {
        """
        sapling_gate="$(mktemp -d)/job-started.sh"
        cat > "$sapling_gate" <<'SAPLING_GATE'
        #!/bin/bash
        node=""
        for candidate in "$SAPLING_RUNNER_DIR"/externals/node*/bin/node; do
          [ -x "$candidate" ] && node="$candidate"
        done
        if [ -z "$node" ]; then
          echo "sapling: no Node.js in the runner to check where this job came from; refusing it" >&2
          exit 1
        fi
        exec "$node" -e "$SAPLING_GATE_JS"
        SAPLING_GATE
        chmod 0555 "$sapling_gate"
        export SAPLING_RUNNER_DIR="$PWD"
        export SAPLING_WATCHED_REPO=\(shellQuote(repo))
        export SAPLING_GATE_JS=\(shellQuote(script))
        export ACTIONS_RUNNER_HOOK_JOB_STARTED="$sapling_gate"
        """
    }

    /// The check itself, in Node.js.
    ///
    /// Exits non-zero, failing the job, unless every repository the payload
    /// names as the code's origin is the watched one.
    static let script = """
        const fs = require("fs");
        const watched = (process.env.SAPLING_WATCHED_REPO || "").toLowerCase();
        const event = process.env.GITHUB_EVENT_NAME || "";
        function refuse(why) {
          console.error("sapling: refusing this job: " + why);
          process.exit(1);
        }
        if ((process.env.GITHUB_REPOSITORY || "").toLowerCase() !== watched) {
          refuse("it belongs to " + process.env.GITHUB_REPOSITORY + ", not " + watched);
        }
        let payload;
        try {
          payload = JSON.parse(fs.readFileSync(process.env.GITHUB_EVENT_PATH, "utf8"));
        } catch (error) {
          refuse("its event payload could not be read");
        }
        const origins = [];
        if (payload.pull_request) {
          const head = payload.pull_request.head;
          origins.push(head && head.repo && head.repo.full_name);
        }
        if (payload.workflow_run) {
          const head = payload.workflow_run.head_repository;
          origins.push(head && head.full_name);
        }
        for (const origin of origins) {
          if (!origin || origin.toLowerCase() !== watched) {
            refuse(event + " from " + (origin || "an unknown repository") + ", not " + watched);
          }
        }
        if (event === "issue_comment" && payload.issue && payload.issue.pull_request) {
          refuse("a comment on a pull request can come from anyone and act on fork code");
        }
        """
}
