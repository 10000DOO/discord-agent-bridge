// Public API barrel for the InteractionCreate router. Import paths stay stable:
// app.ts / client.ts / tests continue to import from './discord/interactionRouter.js'.
// Implementation lives under ./interaction/*.

export type {
  AckPayload,
  SlashInteraction,
  ComponentInteraction,
  ModalSubmitInteraction,
  RouterInteraction,
  InteractionRouterDeps,
} from './interaction/types.js';

export { InteractionRouter } from './interaction/router.js';
