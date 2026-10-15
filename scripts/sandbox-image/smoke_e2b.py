"""Create one E2B sandbox from a template, run smoke.sh in it, destroy it.

Called by smoke-e2b.sh, which pins the SDK and supplies the environment:
E2B_API_KEY, E2B_DOMAIN, E2B_TEMPLATE, E2B_USER, and the path of smoke.sh as
the only argument.

The Python SDK, not the e2b CLI: the CLI refuses any key not shaped `e2b_<hex>`
before it sends a request, and loam's E2B-compatible API, which production
runs on, issues `loam_` keys.
"""

import os
import sys
import time

from e2b import Sandbox

template = os.environ["E2B_TEMPLATE"]
user = os.environ["E2B_USER"]
domain = os.environ["E2B_DOMAIN"]
script = open(sys.argv[1], encoding="utf-8").read()

print(f"==> creating a smoke sandbox from {template} on {domain}", flush=True)
# No `fountain: "1"` metadata, deliberately: that is the label the reaper and
# the ops gauges count as a Managoat sandbox, and a CI sandbox is neither
# leaked nor theirs to reason about. The short timeout is the backstop for a
# smoke that dies before it destroys its sandbox.
sandbox = Sandbox.create(
    template=template,
    timeout=600,
    metadata={"fountain_image_smoke": "1"},
    api_key=os.environ["E2B_API_KEY"],
    domain=domain,
)

try:
    print(f"==> smoking {sandbox.sandbox_id} as {user}", flush=True)
    # The asserted user is E2B's own contract: envd selects the in-guest user
    # from Basic auth, so E2B_USER and the template's user have to agree or
    # every provisioning write lands in the wrong home.
    sandbox.files.write("/tmp/fountain-smoke.sh", script, user=user)

    # envd accepts the connection before it is ready to run anything, and PR
    # #693 is the record of what that race costs. Retry a failed run, which
    # costs a few seconds on a real break.
    output = ""
    for attempt in range(1, 7):
        try:
            result = sandbox.commands.run(
                "bash /tmp/fountain-smoke.sh",
                user=user,
                envs={"SMOKE_EXPECT_USER": user},
                timeout=600,
            )
            output = result.stdout + result.stderr
            break
        except Exception as error:  # CommandExitException carries the output
            output = (getattr(error, "stdout", "") or "") + (getattr(error, "stderr", "") or "")
            if "FOUNTAIN_IMAGE_SMOKE_" in output or attempt == 6:
                output = output or repr(error)
                break
            print(f"    exec attempt {attempt} failed ({error!r}), retrying in 5s", flush=True)
            time.sleep(5)

    print(output, flush=True)
finally:
    print(f"==> destroying smoke sandbox {sandbox.sandbox_id}", flush=True)
    try:
        sandbox.kill()
    except Exception as error:
        print(f"    destroy failed: {error!r}", flush=True)

if "FOUNTAIN_IMAGE_SMOKE_OK" not in output:
    print(f"==> smoke FAILED for template {template}", file=sys.stderr)
    sys.exit(1)

print(f"==> template {template} smoked clean")
