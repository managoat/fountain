// The ADRs in this directory as a chant record kind, so that
// `chant workspace records` and `chant workspace graph --intent` read them
// from their OKF frontmatter. See chant.workspace.json at the repo root.
//
// The state is OKF's `status` (draft, stable, deprecated), not `adr_status`,
// because "Superseded by NNNN" carries a number and a state is a fixed word.
// The template, 0001, is not a decision and is left out.
export const recordKind = {
  name: "adr",
  location: { dir: ".", match: "^(?!0001-)[0-9]{4}-.+\\.md$" },
  format: "markdown-front-matter",
  schema: { id: "urn:managoat:fountain:adr:1", path: "adr.schema.json" },
  idField: "adr",
  stateField: "status",
  states: ["draft", "stable", "deprecated"],
  closedStates: ["stable", "deprecated"],
};
