// Interactive first-run config (token, roles, defaults) via @inquirer/prompts (§4).
// The wizard itself is implemented in Phase 1 chunk 8b; until then runSetup() is a
// no-op that tells the operator it is not ready yet (rather than throwing, so
// `--setup` exits cleanly). Do NOT implement the wizard here.
export async function runSetup(): Promise<void> {
  console.log('Setup wizard is coming soon. For now, create the config file manually.');
}
