/**
 * Refuse to publish from anywhere but this repository's release workflow.
 *
 * npm's "Require trusted publishing" setting is the real lock — it is enforced
 * by the registry, and nothing here can be a substitute for it. This is the
 * guardrail in front of it: it turns an absent-minded `npm publish` into a
 * message explaining the actual release process, instead of a rejection from
 * npm that a person might read as something to work around.
 *
 * Being a lifecycle script, `--ignore-scripts` walks straight past it. That is
 * fine. It is here to catch habit, not to stop a determined person, and the
 * registry stops them anyway.
 */
const inCi = process.env.MANAGOAT_CI_PUBLISH === "1" && process.env.GITHUB_ACTIONS === "true";

if (!inCi) {
  console.error(`
  Refusing to publish from here. CI is the only publisher.

  Releases happen by merging a version bump — there is no tag to push and no
  command to run:

    1. cd sdk/typescript && npm version patch     (or minor / major)
    2. update USER_AGENT in src/http.ts and add a CHANGELOG.md entry
       (the release gate on your PR tells you if you miss either)
    3. open the PR as normal

  Merging it publishes that version, with provenance tying the tarball to the
  workflow and commit that built it. A release published from a laptop has no
  such attestation, which is the whole reason this refuses.
`);
  process.exit(1);
}
